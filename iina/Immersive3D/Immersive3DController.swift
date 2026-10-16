//
//  Immersive3DController.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Video menu, strength presets, and "Play on glasses" for TCL NXTWEAR S.
//  The glasses enumerate as "SmartGlasses": 1920×1080 in 2D, 3840×1080 after
//  the long-press into 3D. Mirroring leaves a single NSScreen.

import Cocoa
import Metal

final class Immersive3DController: NSObject, NSWindowDelegate {
  static let shared = Immersive3DController()

  struct Snapshot {
    var enabled = false
    var maxShift: Float = 0.033
    var convergence: Float = 0.5
    var invertDepth = false
    var verticalFlip = false
    var passThroughSBS = false
    /// 3840×1080 glasses: sample the fitted picture into each full-size half.
    var fullSizeEyes = false
    var shouldProcess: Bool { enabled && !passThroughSBS }
  }

  enum StrengthPreset: Int {
    case soft = 0
    case standard = 1
    case enhanced = 2
    case custom = 3

    var strength: Double {
      switch self {
      case .soft: return 0.25
      case .standard: return 0.50
      case .enhanced: return 0.85
      case .custom: return 0.50
      }
    }

    var title: String {
      switch self {
      case .soft: return "Soft"
      case .standard: return "Standard"
      case .enhanced: return "Enhanced"
      case .custom: return "Custom"
      }
    }
  }

  enum SourceMode: Int {
    case automatic = 0
    case alreadySBS = 1
    case alwaysConvert = 2
  }

  static func glassesReminder(fullSizeEyes: Bool) -> String {
    if fullSizeEyes {
      return "Each eye fills one half of the glasses (1920×1080). The window stays on this display if the size changes."
    }
    return "Long-press the right-side button on your glasses to switch to 3D mode. The picture is half side-by-side until the display widens, and the window follows that size change."
  }

  /// Above normal windows, the menu bar, and other apps on the glasses display.
  static var glassesWindowLevel: NSWindow.Level {
    NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
  }

  private let lock = NSLock()
  private var snapshot = Snapshot()
  private var mediaLooksLikeSBS = false
  private var menuInstalled = false

  private var enabledItem: NSMenuItem?
  private var strengthMenu: NSMenu?
  private var softItem: NSMenuItem?
  private var standardItem: NSMenuItem?
  private var enhancedItem: NSMenuItem?
  private var strengthSlider: NSSlider?
  private var strengthLabel: NSMenuItem?
  private var automaticItem: NSMenuItem?
  private var alreadyItem: NSMenuItem?
  private var convertItem: NSMenuItem?
  private var invertItem: NSMenuItem?
  private var flipItem: NSMenuItem?
  private var v2ModelItem: NSMenuItem?
  private var da3ModelItem: NSMenuItem?
  private var glassesItem: NSMenuItem?
  private var autoGlassesItem: NSMenuItem?
  private let prefObserver = Preference.Observer()

  private var savedWindow: SavedWindow?
  private var pendingDisplayID: CGDirectDisplayID?
  private var panel: NSPanel?
  private var panelTimer: Timer?
  private var playButton: NSButton?
  private var panelSlider: NSSlider?
  private var panelStatus: NSTextField?
  private var panelReminder: NSTextField?
  private var glassesScreen: NSScreen?
  private var glassesDisplayID: CGDirectDisplayID?
  private var glassesUUID: UUID?
  private var glassesFullSizeEyes = false
  private var isPinningGlasses = false
  private var applyingDisplayConfig = false
  private var lastMirrorConfigure = Date.distantPast
  private var shuttingDown = false
  private var didPrepareForTermination = false
  private var savedMirrorLinks: [SavedMirrorLink]?
  private var screenParameterObserver: NSObjectProtocol?
  private var panelIsClosing = false
  private(set) var glassesActive = false
  /// Player or capture, and whether that picture is the glasses output.
  private var session = GlassesSession()
  var captureOnGlasses: Bool { session.source == .capture }
  /// Browser Capture's output window is on the glasses. Screen changes repin it
  /// without moving the player window.
  private var captureWindowPinned = false
  var captureGlassesHandler: ((NSScreen, Bool) -> Void)?
  /// Stereo pass for Browser Capture. The player keeps its own compositor so
  /// this one is never touched from the OpenGL thread.
  private let captureCompositor = Immersive3DCompositor()
  /// True after quit teardown starts. Fullscreen-state changes must not talk to mpv.
  var isShuttingDown: Bool { shuttingDown }

  private static let mirrorPromptDefaultsKey = "immersive3DDidExplainMirroring"

  private override init() {
    super.init()
    lock.lock()
    rebuildSnapshotLocked()
    lock.unlock()
    prefObserver.add(.immersive3DDepthModel) { [weak self] _ in
      DepthEstimator.shared.reload()
      DispatchQueue.main.async {
        self?.syncMenu()
        self?.requestRedraw()
      }
    }
  }

  func currentSnapshot() -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshot
  }

  /// One stereo path for the player framebuffer and for Browser Capture.
  /// Pass the view-layer compositor from OpenGL. Pass nil from capture; that
  /// uses `captureCompositor`. `contentAspect` of 0 keeps the player video aspect.
  @discardableResult
  func submitFrame(
    color: MTLTexture,
    output: MTLTexture,
    contentAspect: Float,
    colorIsBottomUp: Bool,
    depthRGBA: [UInt8]?,
    modelWidth: Int,
    modelHeight: Int,
    fullSizeEyes: Bool?,
    compositor: Immersive3DCompositor?,
    whenDepthReady: @escaping () -> Void,
    whenGPUFinished: ((Bool) -> Void)? = nil
  ) -> StereoOffscreen.EncodeResult {
    let pass = compositor ?? captureCompositor
    return pass.submitFrame(
      color: color,
      output: output,
      contentAspect: contentAspect,
      colorIsBottomUp: colorIsBottomUp,
      depthRGBA: depthRGBA,
      modelWidth: modelWidth,
      modelHeight: modelHeight,
      fullSizeEyes: fullSizeEyes,
      whenDepthReady: whenDepthReady,
      whenGPUFinished: whenGPUFinished
    )
  }

  func captureEncodeQueue() -> MTLCommandQueue? {
    captureCompositor.encodeQueue
  }

  func submitCaptureDepth(_ pixels: [UInt8], width: Int, height: Int, whenReady: @escaping () -> Void) {
    captureCompositor.submitCaptureDepth(pixels, width: width, height: height, whenReady: whenReady)
  }

  /// Puts `window` on the glasses display with the same frame, level, and
  /// mirror handling as Play on Glasses. Does not move the player window.
  func placeWindowOnGlasses(_ window: NSWindow) -> (screen: NSScreen, fullSizeEyes: Bool)? {
    guard let screen = resolvedGlassesScreen() ?? Self.glassesCandidates().first else { return nil }
    if !glassesActive {
      rememberGlasses(screen)
      _ = ensureGlassesExtended()
    }
    let target = resolvedGlassesScreen() ?? screen
    pinExternalWindow(window, to: target)
    captureWindowPinned = true
    startObservingScreenParameters()
    let fullSize = Self.isFullWidthSBS(target)
    return (target, fullSize)
  }

  /// Returns a capture window to a normal preview frame. Mirroring is restored
  /// only when Play on Glasses is not using the same session.
  func returnWindowFromGlasses(_ window: NSWindow, previewFrame: NSRect) {
    captureWindowPinned = false
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.level = .normal
    window.isMovable = true
    window.hasShadow = true
    window.collectionBehavior = [.canJoinAllSpaces]
    let aspect = Self.safeAspect(NSSize(width: 16, height: 9))
    window.aspectRatio = aspect
    window.contentAspectRatio = aspect
    if Self.isUsableWindowFrame(previewFrame) {
      // display:true during quit takes a Metal drawable into the Apple Event pool.
      window.setFrame(previewFrame, display: !shuttingDown, animate: false)
    }
    if !glassesActive {
      stopObservingScreenParameters()
      restoreMirroringIfNeeded()
    }
  }

  // MARK: - Media

  func noteMediaURL(_ url: URL?) {
    let looks = Self.looksLikeSideBySide(url)
    lock.lock()
    mediaLooksLikeSBS = looks
    rebuildSnapshotLocked()
    lock.unlock()
    DepthEstimator.shared.resetAll()
    DispatchQueue.main.async {
      self.syncMenu()
      self.requestRedraw()
    }
  }

  static func looksLikeSideBySide(_ url: URL?) -> Bool {
    guard let url else { return false }
    let haystack = (url.lastPathComponent + " " + url.absoluteString).lowercased()
    let parts = haystack.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let tokens: Set<String> = ["sbs", "hsbs", "halfsbs", "fullsbs", "sidebyside"]
    if parts.contains(where: { tokens.contains($0) }) { return true }
    let phrases = ["half-sbs", "full-sbs", "side-by-side", "side_by_side"]
    return phrases.contains { haystack.contains($0) }
  }

  static func maxShift(forStrength strength: Double) -> Float {
    let clamped = Float(min(max(strength, 0), 1))
    return 0.006 + clamped * 0.054
  }

  // MARK: - Menu

  func installMenu(in videoMenu: NSMenu) {
    guard !menuInstalled else { return }
    menuInstalled = true

    let enabled = NSMenuItem(title: "Immersive 3D", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
    enabled.target = self
    enabledItem = enabled

    let strength = NSMenu(title: "Depth Strength")
    strengthMenu = strength
    softItem = presetItem(.soft, menu: strength)
    standardItem = presetItem(.standard, menu: strength)
    enhancedItem = presetItem(.enhanced, menu: strength)
    strength.addItem(.separator())
    let sliderItem = NSMenuItem()
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 28))
    let slider = NSSlider(value: Preference.double(for: .immersive3DStrength), minValue: 0, maxValue: 1, target: self, action: #selector(strengthSliderChanged(_:)))
    slider.isContinuous = true
    slider.frame = NSRect(x: 18, y: 4, width: 196, height: 20)
    container.addSubview(slider)
    sliderItem.view = container
    strength.addItem(sliderItem)
    strengthSlider = slider
    let label = NSMenuItem(title: "Strength", action: nil, keyEquivalent: "")
    label.isEnabled = false
    strengthLabel = label
    strength.addItem(label)
    strength.addItem(.separator())
    invertItem = toggleItem("Invert Depth", action: #selector(toggleInvert(_:)), menu: strength)
    flipItem = toggleItem("Flip 3D Picture Vertically", action: #selector(toggleFlip(_:)), menu: strength)
    let strengthItem = NSMenuItem(title: "Depth Strength", action: nil, keyEquivalent: "")
    strengthItem.submenu = strength

    let models = NSMenu(title: "Depth Model")
    v2ModelItem = modelItem("Depth Anything V2 Small", tag: Preference.DepthModelOption.depthAnythingV2Small.rawValue, menu: models)
    da3ModelItem = modelItem("Depth Anything 3 Small", tag: Preference.DepthModelOption.depthAnything3Small.rawValue, menu: models)
    if let override = DepthModelLocator.environmentOverride {
      models.addItem(.separator())
      let note = NSMenuItem(title: "Override: \(URL(fileURLWithPath: override).lastPathComponent)", action: nil, keyEquivalent: "")
      note.isEnabled = false
      models.addItem(note)
    }
    let modelMenuItem = NSMenuItem(title: "Depth Model", action: nil, keyEquivalent: "")
    modelMenuItem.submenu = models

    let source = NSMenu(title: "Source Is Side-by-Side")
    automaticItem = modeItem("Automatic", mode: .automatic, menu: source)
    alreadyItem = modeItem("Yes — pass the frame through", mode: .alreadySBS, menu: source)
    convertItem = modeItem("No — always convert", mode: .alwaysConvert, menu: source)
    let sourceItem = NSMenuItem(title: "Source Is Side-by-Side", action: nil, keyEquivalent: "")
    sourceItem.submenu = source

    let glasses = NSMenuItem(title: "Play on Glasses", action: #selector(playOnGlasses(_:)), keyEquivalent: "")
    glasses.target = self
    glassesItem = glasses

    let autoGlasses = NSMenuItem(title: "Automatically Set Up Glasses Display", action: #selector(toggleAutoGlassesDisplay(_:)), keyEquivalent: "")
    autoGlasses.target = self
    autoGlassesItem = autoGlasses

    var block = [
      enabled,
      strengthItem,
      modelMenuItem,
      sourceItem,
      NSMenuItem.separator(),
      glasses,
      autoGlasses,
      NSMenuItem.separator()
    ]
    if #available(macOS 12.3, *) {
      block.append(contentsOf: BrowserCaptureWindowController.shared.makeMenuItems())
      block.append(NSMenuItem.separator())
    }
    for (offset, item) in block.enumerated() {
      videoMenu.insertItem(item, at: min(2 + offset, videoMenu.numberOfItems))
    }
    syncMenu()
  }

  func syncMenu() {
    guard menuInstalled else { return }
    let snap = currentSnapshot()
    enabledItem?.state = snap.enabled ? .on : .off
    let preset = StrengthPreset(rawValue: Preference.integer(for: .immersive3DPreset)) ?? .standard
    softItem?.state = preset == .soft ? .on : .off
    standardItem?.state = preset == .standard ? .on : .off
    enhancedItem?.state = preset == .enhanced ? .on : .off
    let strength = Preference.double(for: .immersive3DStrength)
    strengthSlider?.doubleValue = strength
    panelSlider?.doubleValue = strength
    strengthLabel?.title = String(format: "Strength: %.0f%%", strength * 100)
    let mode = SourceMode(rawValue: Preference.integer(for: .immersive3DSourceMode)) ?? .automatic
    automaticItem?.state = mode == .automatic ? .on : .off
    alreadyItem?.state = mode == .alreadySBS ? .on : .off
    convertItem?.state = mode == .alwaysConvert ? .on : .off
    invertItem?.state = snap.invertDepth ? .on : .off
    flipItem?.state = snap.verticalFlip ? .on : .off
    let model = Preference.DepthModelOption(rawValue: Preference.integer(for: .immersive3DDepthModel)) ?? .depthAnythingV2Small
    v2ModelItem?.state = model == .depthAnythingV2Small ? .on : .off
    da3ModelItem?.state = model == .depthAnything3Small ? .on : .off
    autoGlassesItem?.state = Preference.bool(for: .immersive3DAutoGlassesDisplay) ? .on : .off
    rebuildGlassesItem()
    if #available(macOS 12.3, *) {
      BrowserCaptureWindowController.shared.syncMenu()
    }
  }

  @objc func toggleAutoGlassesDisplay(_ sender: Any?) {
    let enabled = !Preference.bool(for: .immersive3DAutoGlassesDisplay)
    Preference.set(enabled, for: .immersive3DAutoGlassesDisplay)
    syncMenu()
    guard glassesActive, enabled else { return }
    if ensureGlassesExtended(), let screen = resolvedGlassesScreen() {
      pinGlassesWindow(to: screen)
      updatePanel(for: screen)
      requestRedraw()
      playerOSD("Glasses set to an extended display")
    }
  }

  @objc func chooseDepthModel(_ sender: NSMenuItem) {
    Preference.set(sender.tag, for: .immersive3DDepthModel)
    playerOSD("Depth model: \(sender.title)")
  }

  @objc func toggleEnabled(_ sender: Any?) {
    setEnabled(!Preference.bool(for: .immersive3DEnabled))
  }

  @objc func choosePreset(_ sender: NSMenuItem) {
    guard let preset = StrengthPreset(rawValue: sender.tag) else { return }
    Preference.set(preset.rawValue, for: .immersive3DPreset)
    Preference.set(preset.strength, for: .immersive3DStrength)
    publishAndRedraw()
    if preset != .custom {
      playerOSD("Immersive 3D: \(preset.title)")
    }
  }

  @objc func strengthSliderChanged(_ sender: NSSlider) {
    Preference.set(sender.doubleValue, for: .immersive3DStrength)
    Preference.set(StrengthPreset.custom.rawValue, for: .immersive3DPreset)
    publishAndRedraw()
  }

  @objc func chooseSourceMode(_ sender: NSMenuItem) {
    Preference.set(sender.tag, for: .immersive3DSourceMode)
    publishAndRedraw()
  }

  @objc func toggleInvert(_ sender: Any?) {
    Preference.set(!Preference.bool(for: .immersive3DInvertDepth), for: .immersive3DInvertDepth)
    publishAndRedraw()
  }

  @objc func toggleFlip(_ sender: Any?) {
    Preference.set(!Preference.bool(for: .immersive3DVerticalFlip), for: .immersive3DVerticalFlip)
    publishAndRedraw()
  }

  func setEnabled(_ enabled: Bool) {
    noteAudioRouteUntouched(.immersive3DToggle, "immersive 3d toggled enabled=\(enabled ? 1 : 0)")
    Preference.set(enabled, for: .immersive3DEnabled)
    publishAndRedraw()
    if enabled {
      DepthEstimator.shared.ensureLoaded()
      let snap = currentSnapshot()
      if snap.passThroughSBS {
        playerOSD("Immersive 3D off — side-by-side source passes through")
      } else {
        playerOSD("Immersive 3D")
      }
    } else {
      playerOSD("Immersive 3D off")
    }
    GlassesEyeControls.shared.sync()
  }

  // MARK: - Glasses

  @objc func playOnGlasses(_ sender: Any?) {
    noteAudioRouteUntouched(.playOnGlasses, "play on glasses")
    let screens = Self.glassesCandidates()
    if screens.isEmpty && !session.isOn {
      showMessage(
        title: "No glasses display found",
        body: "Connect the TCL NXTWEAR S with USB-C. macOS should list it as SmartGlasses, usually 1920×1080 or 3840×1080. If the displays are mirrored there is only one screen; Play on Glasses still covers that screen. Then choose Video → Play on Glasses."
      )
      return
    }
    let ordered = Self.orderedGlasses(screens)
    perform(session.transition(.play(displays: ordered.map(Self.displayChoice(for:)), captureRunning: captureIsRunning)))
  }

  @objc func playOnScreen(_ sender: NSMenuItem) {
    let id = (sender.representedObject as? NSNumber)?.uint32Value ?? 0
    guard let screen = NSScreen.screens.first(where: { $0.displayId == id }) else {
      showMessage(title: "That display is gone", body: "The selected screen is no longer connected.")
      return
    }
    perform(session.transition(.playOn(Self.displayChoice(for: screen), captureRunning: captureIsRunning)))
  }

  /// Capture became the running picture. Glasses that are connected take it immediately.
  func captureDidStart() {
    let displays = Self.orderedGlasses(Self.glassesCandidates()).map(Self.displayChoice(for:))
    perform(session.transition(.captureStarted(displays: displays)))
  }

  func captureDidStop() {
    perform(session.transition(.captureStopped))
  }

  private var captureIsRunning: Bool {
    guard #available(macOS 12.3, *) else { return false }
    return BrowserCaptureManager.shared.isRunning
  }

  private static func orderedGlasses(_ screens: [NSScreen]) -> [NSScreen] {
    if screens.count <= 1 { return screens }
    if let preferred = screens.first(where: { looksLikeNXTWEAR($0) }) {
      return [preferred] + screens.filter { $0 != preferred }
    }
    return screens
  }

  private func perform(_ plan: GlassesSession.Transition) {
    var kept = session
    kept.captureRunning = plan.session.captureRunning
    if apply(plan.effects) {
      session = plan.session
    } else {
      session = kept
    }
    syncMenu()
    if #available(macOS 12.3, *) {
      BrowserCaptureWindowController.shared.syncMenu()
    }
  }

  private func apply(_ effects: [GlassesEffect]) -> Bool {
    for effect in effects {
      switch effect {
      case .noDisplay:
        showMessage(
          title: "No glasses display found",
          body: "Connect the TCL NXTWEAR S with USB-C. macOS should list it as SmartGlasses, usually 1920×1080 or 3840×1080."
        )
        return false
      case .pinPlayer(let display):
        guard let screen = screen(for: display), beginGlasses(on: screen) else { return false }
      case .unpinPlayer:
        pendingDisplayID = nil
        exitGlasses(closePanel: !panelIsClosing)
      case .pinCapture(let display):
        guard #available(macOS 12.3, *), let screen = screen(for: display) else { return false }
        guard BrowserCaptureWindowController.shared.presentCapture(on: screen) else { return false }
      case .unpinCapture:
        guard #available(macOS 12.3, *) else { return false }
        BrowserCaptureWindowController.shared.returnCaptureToPreview()
      }
    }
    return true
  }

  private func screen(for display: GlassesDisplayChoice) -> NSScreen? {
    if let screen = NSScreen.screens.first(where: { $0.displayId == display.id }) { return screen }
    return Self.glassesCandidates().first
  }

  func mainWindowDidExitFullScreen() {
    guard let id = pendingDisplayID else { return }
    pendingDisplayID = nil
    DispatchQueue.main.async { [weak self] in
      guard let screen = NSScreen.screens.first(where: { $0.displayId == id }) else { return }
      self?.enterGlasses(on: screen)
    }
  }

  func mainWindowFailedToExitFullScreen() {
    pendingDisplayID = nil
    if session.source == .player && !glassesActive {
      session.output = .off
      session.restorePlayer = false
      syncMenu()
    }
  }

  func mainWindowWillClose() {
    // Leave Play on Glasses before AppKit tears the window down, then drop any depth
    // map that exit may have requested. In-flight Core ML still finishes, but it will
    // not publish. A later file can submit again; quit uses `shutdown` instead.
    exitGlasses(restoreUI: false)
    DepthEstimator.shared.cancelPending()
  }

  @discardableResult
  private func beginGlasses(on screen: NSScreen) -> Bool {
    let player = PlayerCore.active
    guard !player.isInMiniPlayer else {
      showMessage(title: "Exit music mode first", body: "Play on Glasses uses the main video window.")
      return false
    }
    guard player.mainWindow.window != nil else { return false }
    if player.mainWindow.fsState.isFullscreen {
      pendingDisplayID = screen.displayId
      player.mainWindow.toggleWindowFullScreen()
      return true
    }
    enterGlasses(on: screen)
    return true
  }

  private func enterGlasses(on screen: NSScreen) {
    guard !shuttingDown else { return }
    let player = PlayerCore.active
    guard let window = player.mainWindow.window else { return }
    if savedWindow == nil {
      savedWindow = SavedWindow(
        frame: window.frame,
        styleMask: window.styleMask,
        level: window.level,
        collectionBehavior: window.collectionBehavior,
        isMovable: window.isMovable,
        hasShadow: window.hasShadow,
        titlebarAppearsTransparent: window.titlebarAppearsTransparent,
        titleVisibility: window.titleVisibility,
        aspectRatio: window.aspectRatio,
        contentAspectRatio: window.contentAspectRatio,
        minSize: window.minSize,
        contentMinSize: window.contentMinSize,
        resizeIncrements: window.resizeIncrements,
        isOpaque: window.isOpaque,
        backgroundColor: window.backgroundColor,
        hidesOnDeactivate: window.hidesOnDeactivate,
        disableUI: player.disableUI,
        immersiveWasEnabled: Preference.bool(for: .immersive3DEnabled)
      )
    }
    player.disableUI = true
    glassesActive = true
    rememberGlasses(screen)
    startObservingScreenParameters()
    let extended = ensureGlassesExtended()
    let target = resolvedGlassesScreen() ?? screen
    pinGlassesWindow(to: target)
    player.mainWindow.hideUI(force: true)

    let snap = currentSnapshot()
    if !snap.passThroughSBS {
      setEnabled(true)
    } else {
      publishAndRedraw()
      playerOSD("Side-by-side source — passing the frame through")
    }
    showPanel(for: target)
    let reminder = Self.glassesReminder(fullSizeEyes: Self.isFullWidthSBS(target))
    player.sendOSD(.custom(reminder), autoHide: true, forcedTimeout: 8)
    if extended {
      playerOSD("Glasses set to an extended display")
    }
    requestRedraw()
    let pixels = Self.pixelSize(of: target)
    let frame = target.frame
    log3D("Play on glasses: \(target.localizedName) origin (\(Int(frame.origin.x)), \(Int(frame.origin.y))) size \(Int(frame.width))x\(Int(frame.height)) scale \(target.backingScaleFactor) pixels \(pixels.width)x\(pixels.height) mirror \(Self.isMirrored(target))", level: .warning)
    maybeExplainMirroring(target)
  }

  /// Borderless, above other windows, frame exactly `screen.frame`, drawable at the screen's pixel size.
  private func pinGlassesWindow(to screen: NSScreen) {
    guard !shuttingDown, !isPinningGlasses else { return }
    let player = PlayerCore.active
    guard let window = player.mainWindow.window else { return }
    isPinningGlasses = true
    defer { isPinningGlasses = false }

    window.styleMask = [.borderless]
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbar = nil
    window.isOpaque = true
    window.backgroundColor = .black
    window.hasShadow = false
    window.isMovable = false
    window.isMovableByWindowBackground = false
    window.hidesOnDeactivate = false
    window.level = Self.glassesWindowLevel
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    window.minSize = NSSize(width: 1, height: 1)
    window.contentMinSize = NSSize(width: 1, height: 1)
    window.resizeIncrements = NSSize(width: 1, height: 1)
    // A zero aspect makes AppKit's fullscreen-exit setFrame produce NaN. Use the
    // screen size, which is non-zero and matches the frame we are about to apply.
    let aspect = Self.safeAspect(screen.frame.size)
    window.aspectRatio = aspect
    window.contentAspectRatio = aspect
    // `screen.frame` is in the global desktop. Extended SmartGlasses sit beside the
    // built-in display, for example (1512, -98, 3840, 1080), not at (0, 0).
    applyGlassesFrame(screen.frame, to: window)
    player.mainWindow.setGlassesVideoFill(true)
    let scale = screen.backingScaleFactor
    player.mainWindow.videoView.videoLayer.contentsScale = scale
    window.contentView?.layoutSubtreeIfNeeded()
    player.mainWindow.updateWindowParametersForMPV(withFrame: screen.frame)
    // Borderless windows are not key by default, so arrow and Return never arrive.
    (window as? MainWindow)?.forceKeyAndMain = true
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)

    rememberGlasses(screen)
    let fullSize = Self.isFullWidthSBS(screen)
    lock.lock()
    glassesFullSizeEyes = fullSize
    rebuildSnapshotLocked()
    lock.unlock()

    if !Self.framesMatch(window.frame, screen.frame) {
      log3D("Play on glasses: window frame \(Self.frameDescription(window.frame)) does not match \(screen.localizedName) \(Self.frameDescription(screen.frame))", level: .error)
    }
    GlassesEyeControls.shared.sync()
  }

  /// Same chrome as Play on Glasses, for a window that is not the player.
  private func pinExternalWindow(_ window: NSWindow, to screen: NSScreen) {
    window.styleMask = [.borderless]
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isOpaque = true
    window.backgroundColor = .black
    window.hasShadow = false
    window.isMovable = false
    window.isMovableByWindowBackground = false
    window.hidesOnDeactivate = false
    window.level = NSWindow.Level(rawValue: Self.glassesWindowLevel.rawValue + 1)
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    window.minSize = NSSize(width: 1, height: 1)
    window.contentMinSize = NSSize(width: 1, height: 1)
    let aspect = Self.safeAspect(screen.frame.size)
    window.aspectRatio = aspect
    window.contentAspectRatio = aspect
    applyGlassesFrame(screen.frame, to: window)
    window.contentView?.layer?.contentsScale = screen.backingScaleFactor
    NSApp.activate(ignoringOtherApps: true)
    window.orderFrontRegardless()
  }

  func repinExternalWindow(_ window: NSWindow, on screen: NSScreen) {
    pinExternalWindow(window, to: screen)
  }

  /// Puts the window on `target` exactly. Origin is applied last because `setContentSize`
  /// keeps the top-left corner fixed.
  private func applyGlassesFrame(_ target: NSRect, to window: NSWindow) {
    guard Self.isUsableWindowFrame(target) else {
      log3D("Skipped glasses setFrame; unusable \(Self.frameDescription(target))", level: .error)
      return
    }
    window.setFrame(target, display: true, animate: false)
    window.setFrameOrigin(target.origin)
    let sizeDrift = abs(window.frame.width - target.width) > 0.5 || abs(window.frame.height - target.height) > 0.5
    if sizeDrift || !Self.framesMatch(window.frame, target) {
      window.setContentSize(target.size)
      window.setFrameOrigin(target.origin)
    }
  }

  /// Keeps a non-zero aspect equal to the glasses screen so a later setFrame cannot divide by zero.
  func lockGlassesAspectToScreen() {
    guard glassesActive, !PlayerCore.playerCores.isEmpty, let window = PlayerCore.active.mainWindow.window else { return }
    let size = (resolvedGlassesScreen() ?? window.screen)?.frame.size ?? window.frame.size
    let aspect = Self.safeAspect(size)
    window.aspectRatio = aspect
    window.contentAspectRatio = aspect
  }

  /// Stop glasses mode, restore a real window frame, then put mirroring back. Idempotent.
  /// Called from quit before AppKit's fullscreen-exit transition, and from window close.
  func prepareForApplicationTermination() {
    guard !didPrepareForTermination else { return }
    didPrepareForTermination = true
    shuttingDown = true
    LiveCaptionController.shared.noteFileEnded()
    pendingDisplayID = nil
    captureWindowPinned = false
    stopObservingScreenParameters()
    if #available(macOS 12.3, *) {
      CaptureAudioRouteController.end()
      BrowserCaptureWindowController.shared.stopAll()
    }
    DepthEstimator.shared.shutdown()
    exitGlasses(closePanel: true)
    guard !PlayerCore.playerCores.isEmpty, let main = PlayerCore.active.mainWindow else { return }
    if let prior = main.fsState.priorWindowedFrame {
      main.replacePriorFullScreenFrame(with: prior)
    }
    if let window = main.window {
      if !Self.isUsableAspect(window.aspectRatio) {
        window.aspectRatio = Self.safeAspect(.zero)
      }
      if !Self.isUsableAspect(window.contentAspectRatio) {
        window.contentAspectRatio = Self.safeAspect(.zero)
      }
    }
  }

  private static func frameDescription(_ frame: NSRect) -> String {
    func text(_ value: CGFloat) -> String {
      value.isFinite ? String(Int(value.rounded())) : "nan"
    }
    return "(\(text(frame.origin.x)), \(text(frame.origin.y)), \(text(frame.width)), \(text(frame.height)))"
  }

  static func isUsableSize(_ size: NSSize) -> Bool {
    size.width.isFinite && size.height.isFinite && size.width >= 1 && size.height >= 1
      && size.width <= 16_000 && size.height <= 16_000
  }

  static func isUsableAspect(_ size: NSSize) -> Bool {
    isUsableSize(size)
  }

  static func safeAspect(_ size: NSSize) -> NSSize {
    isUsableAspect(size) ? size : NSSize(width: 16, height: 9)
  }

  /// Finite, non-zero, not huge, and overlapping a connected screen.
  static func isUsableWindowFrame(_ frame: NSRect) -> Bool {
    guard frame.origin.x.isFinite, frame.origin.y.isFinite, isUsableSize(frame.size) else { return false }
    return NSScreen.screens.contains { $0.frame.intersects(frame) }
  }

  static func fallbackWindowFrame() -> NSRect {
    let screen = NSScreen.screens.first { isBuiltIn($0) } ?? NSScreen.main ?? NSScreen.screens.first
    let visible = screen?.visibleFrame ?? NSRect(x: 80, y: 80, width: 960, height: 540)
    let width = min(max(visible.width * 0.7, 50), 960)
    let height = min(max(visible.height * 0.7, 50), 540)
    return NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
  }

  /// Finite, non-zero, and overlapping a connected screen. Used when leaving fullscreen
  /// or Play on Glasses while that screen is still there.
  static func windowedFrameRestoring(_ proposed: NSRect) -> NSRect? {
    if isUsableWindowFrame(proposed) {
      return proposed
    }
    guard !NSScreen.screens.isEmpty else { return nil }
    let fallback = fallbackWindowFrame()
    return isUsableWindowFrame(fallback) ? fallback : nil
  }

  /// Quit path. Prefer a rect on the built-in display so a later mirror restore cannot
  /// leave AppKit setFrame'ing the glasses rect `(1512, -98, 3840, 1080)`.
  static func terminationWindowFrame(_ proposed: NSRect) -> NSRect? {
    if isUsableWindowFrame(proposed), intersectsStableScreen(proposed) {
      return proposed
    }
    guard !NSScreen.screens.isEmpty else { return nil }
    let fallback = fallbackWindowFrame()
    return isUsableWindowFrame(fallback) ? fallback : nil
  }

  private static func intersectsStableScreen(_ frame: NSRect) -> Bool {
    if let builtIn = NSScreen.screens.first(where: { isBuiltIn($0) }) {
      return builtIn.frame.intersects(frame)
    }
    return NSScreen.screens.contains { $0.frame.intersects(frame) }
  }

  /// Called after a resize that was not started by `pinGlassesWindow`. Resolution changes use the screen observer.
  func repinGlassesWindowIfNeeded() {
    guard !shuttingDown, glassesActive, !isPinningGlasses, let screen = resolvedGlassesScreen() else { return }
    guard let window = PlayerCore.active.mainWindow.window else { return }
    let scale = screen.backingScaleFactor
    let layerScale = PlayerCore.active.mainWindow.videoView.videoLayer.contentsScale
    let scaleMatches = abs(layerScale - scale) < 0.01
    if Self.framesMatch(window.frame, screen.frame) && scaleMatches {
      return
    }
    pinGlassesWindow(to: screen)
    updatePanel(for: screen)
    requestRedraw()
  }

  private func startObservingScreenParameters() {
    guard screenParameterObserver == nil else { return }
    screenParameterObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.glassesScreenParametersChanged()
    }
  }

  private func stopObservingScreenParameters() {
    if let screenParameterObserver {
      NotificationCenter.default.removeObserver(screenParameterObserver)
      self.screenParameterObserver = nil
    }
  }

  /// Display-mode changes, including the glasses 3D button, land here. The window
  /// is repinned. The capture route is not engaged or released.
  private func noteAudioRouteUntouched(_ action: CaptureGlassesAudio.Action, _ detail: String) {
    let effects = CaptureGlassesAudio.routeEffects(for: action)
    if effects.isEmpty {
      CaptureAudioFileLog.info("\(detail); loopback keeps the saved output; system default and mpv device were not changed")
    } else {
      CaptureAudioFileLog.error("\(detail); refused \(effects.count) audio route changes")
    }
  }

  private func glassesScreenParametersChanged() {
    guard !shuttingDown, !isPinningGlasses, !applyingDisplayConfig else { return }
    noteAudioRouteUntouched(.screenParameters, "glasses display parameters changed")
    if captureWindowPinned {
      if !glassesActive {
        _ = ensureGlassesExtended()
      }
      if let screen = resolvedGlassesScreen() ?? Self.glassesCandidates().first {
        session.noteScreen(Self.displayChoice(for: screen))
        captureGlassesHandler?(screen, Self.isFullWidthSBS(screen))
      }
    }
    guard glassesActive else { return }
    // A 2D/3D mode switch can put the glasses back into a mirror set.
    if ensureGlassesExtended() {
      playerOSD("Glasses set to an extended display")
    }
    guard let screen = resolvedGlassesScreen() else {
      log3D("Play on glasses: display \(glassesDisplayID.map(String.init) ?? "?") is missing after a screen change", level: .warning)
      return
    }
    let wasFull = glassesFullSizeEyes
    pinGlassesWindow(to: screen)
    updatePanel(for: screen)
    if wasFull != Self.isFullWidthSBS(screen) {
      let text = Self.glassesReminder(fullSizeEyes: Self.isFullWidthSBS(screen))
      guard !PlayerCore.playerCores.isEmpty else { return }
      PlayerCore.active.sendOSD(.custom(text), autoHide: true, forcedTimeout: 8)
    }
    requestRedraw()
  }

  private func rememberGlasses(_ screen: NSScreen) {
    glassesScreen = screen
    guard let id = screen.displayId else { return }
    glassesDisplayID = id
    glassesUUID = Self.displayUUID(id)
  }

  private func resolvedGlassesScreen() -> NSScreen? {
    if let id = glassesDisplayID, let screen = NSScreen.screens.first(where: { $0.displayId == id }) {
      rememberGlasses(screen)
      return screen
    }
    if let glassesUUID, let screen = NSScreen.screens.first(where: { screen in
      guard let id = screen.displayId else { return false }
      return Self.displayUUID(id) == glassesUUID
    }) {
      rememberGlasses(screen)
      return screen
    }
    if let screen = glassesScreen, NSScreen.screens.contains(where: { $0 == screen }) {
      return screen
    }
    if let screen = Self.glassesCandidates().first {
      rememberGlasses(screen)
      return screen
    }
    return nil
  }

  private func maybeExplainMirroring(_ screen: NSScreen) {
    guard Self.isMirrored(screen) else { return }
    if UserDefaults.standard.bool(forKey: Self.mirrorPromptDefaultsKey) { return }
    UserDefaults.standard.set(true, forKey: Self.mirrorPromptDefaultsKey)
    let automatic = Preference.bool(for: .immersive3DAutoGlassesDisplay)
    let body = automatic
      ? "IINA tried to switch the glasses to an extended display for this login session, but they are still mirrored, so this window covers the shared screen. Turn mirroring off in System Settings → Displays. The permanent display arrangement is left unchanged."
      : "The glasses are mirroring this Mac, so there is one shared screen and this window covers it. Turn on Settings → Video → Automatically set up glasses display, or turn mirroring off in System Settings → Displays."
    DispatchQueue.main.async { [weak self] in
      let alert = NSAlert()
      alert.alertStyle = .informational
      alert.messageText = "Glasses are mirroring this Mac"
      alert.informativeText = body
      alert.window.level = NSWindow.Level(rawValue: Self.glassesWindowLevel.rawValue + 2)
      alert.runModal()
      self?.panel?.orderFrontRegardless()
    }
  }

  func exitGlasses(closePanel: Bool = true, restoreUI: Bool = true) {
    if session.source == .player {
      session.output = .off
      session.restorePlayer = false
    }
    let saved = savedWindow
    if !glassesActive && saved == nil {
      hidePanel(close: closePanel)
      if !captureWindowPinned {
        stopObservingScreenParameters()
        restoreMirroringIfNeeded()
      }
      GlassesEyeControls.shared.sync()
      return
    }
    glassesActive = false
    glassesFullSizeEyes = false
    pendingDisplayID = nil
    // Drop the screen observer before setFrame or display reconfiguration, so a
    // parameter change cannot pin the player window again mid-quit. Browser
    // Capture keeps the observer while its own window is still on the glasses.
    if !captureWindowPinned {
      stopObservingScreenParameters()
    }
    let player = PlayerCore.playerCores.isEmpty ? nil : PlayerCore.active
    if let saved, let window = player?.mainWindow.window {
      let aspect = Self.safeAspect(saved.aspectRatio)
      let contentAspect = Self.safeAspect(saved.contentAspectRatio)
      window.aspectRatio = aspect
      window.contentAspectRatio = contentAspect
      window.level = saved.level
      window.collectionBehavior = saved.collectionBehavior
      window.isMovable = saved.isMovable
      window.hasShadow = saved.hasShadow
      window.titlebarAppearsTransparent = saved.titlebarAppearsTransparent
      window.titleVisibility = saved.titleVisibility
      window.isOpaque = saved.isOpaque
      window.backgroundColor = saved.backgroundColor
      window.hidesOnDeactivate = saved.hidesOnDeactivate
      window.minSize = saved.minSize
      window.contentMinSize = saved.contentMinSize
      window.resizeIncrements = saved.resizeIncrements
      let nativeFullScreen = window.styleMask.contains(.fullScreen)
      let restored = shuttingDown ? Self.terminationWindowFrame(saved.frame) : Self.windowedFrameRestoring(saved.frame)
      if nativeFullScreen {
        // AppKit exits native fullscreen itself on quit. Give it a windowed rect that
        // still intersects a screen, instead of calling setFrame while `.fullScreen` is set.
        if let restored {
          player?.mainWindow.replacePriorFullScreenFrame(with: restored)
        }
      } else {
        var style = saved.styleMask
        style.remove(.fullScreen)
        window.styleMask = style
        if let restored {
          window.setFrame(restored, display: !shuttingDown, animate: false)
        } else {
          log3D("Skipped restoring the pre-glasses frame; no screen is available", level: .error)
        }
        player?.mainWindow.setGlassesVideoFill(false)
        player?.mainWindow.setWindowToolbar()
        player?.mainWindow.videoView.videoLayer.contentsScale = window.backingScaleFactor
      }
      let borderlessOnly = saved.styleMask.intersection([.titled, .fullScreen]).isEmpty
      (window as? MainWindow)?.forceKeyAndMain = borderlessOnly
    }
    if let saved, let player {
      player.disableUI = saved.disableUI
      Preference.set(saved.immersiveWasEnabled, for: .immersive3DEnabled)
    }
    savedWindow = nil
    if !captureWindowPinned {
      glassesScreen = nil
      glassesDisplayID = nil
      glassesUUID = nil
    }
    hidePanel(close: closePanel)
    if restoreUI, !shuttingDown, let saved, let player {
      publishAndRedraw()
      if !saved.disableUI {
        player.mainWindow.showUI()
      }
    }
    GlassesEyeControls.shared.sync()
    if !captureWindowPinned {
      restoreMirroringIfNeeded()
    }
  }

  private func showPanel(for glasses: NSScreen) {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    let host = Self.builtInScreen(excluding: glasses) ?? NSScreen.screens.first { $0 != glasses } ?? glasses
    let size = panel.frame.size
    let visible = host.visibleFrame
    let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 48)
    panel.setFrameOrigin(origin)
    panel.level = Self.panelLevel
    updatePanel(for: glasses)
    refreshTransport()
    panel.orderFrontRegardless()
    panelTimer?.invalidate()
    panelTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.refreshTransport()
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 348),
      styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.title = "Play on Glasses"
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.delegate = self

    let content = panel.contentView!
    let title = NSTextField(labelWithString: "Play on glasses")
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.frame = NSRect(x: 20, y: 306, width: 420, height: 22)
    let reminder = NSTextField(wrappingLabelWithString: Self.glassesReminder(fullSizeEyes: false))
    reminder.font = .systemFont(ofSize: 13, weight: .medium)
    reminder.frame = NSRect(x: 18, y: 226, width: 424, height: 72)
    panelReminder = reminder
    let status = NSTextField(wrappingLabelWithString: "")
    status.font = .systemFont(ofSize: 12)
    status.textColor = .secondaryLabelColor
    status.frame = NSRect(x: 18, y: 172, width: 424, height: 48)
    panelStatus = status
    let strengthName = NSTextField(labelWithString: "Depth strength")
    strengthName.frame = NSRect(x: 20, y: 132, width: 120, height: 18)
    let slider = NSSlider(value: Preference.double(for: .immersive3DStrength), minValue: 0, maxValue: 1, target: self, action: #selector(strengthSliderChanged(_:)))
    slider.isContinuous = true
    slider.frame = NSRect(x: 140, y: 130, width: 300, height: 24)
    let sync = CaptureSyncOffsetControl(placement: .overlay)
    sync.frame = NSRect(x: 20, y: 96, width: 420, height: 28)
    panelSlider = slider
    let presets = NSPopUpButton(frame: NSRect(x: 18, y: 56, width: 200, height: 26), pullsDown: false)
    presets.addItems(withTitles: ["Soft", "Standard", "Enhanced"])
    presets.target = self
    presets.action = #selector(panelPresetChanged(_:))
    let current = StrengthPreset(rawValue: Preference.integer(for: .immersive3DPreset)) ?? .standard
    presets.selectItem(at: min(current.rawValue, 2))
    let play = NSButton(title: "Pause", target: self, action: #selector(togglePlay(_:)))
    play.bezelStyle = .rounded
    play.frame = NSRect(x: 18, y: 16, width: 120, height: 30)
    playButton = play
    let exit = NSButton(title: "Exit Glasses", target: self, action: #selector(exitGlassesClicked(_:)))
    exit.bezelStyle = .rounded
    exit.frame = NSRect(x: 320, y: 16, width: 122, height: 30)
    for view in [title, reminder, status, strengthName, slider, sync, presets, play, exit] {
      content.addSubview(view)
    }
    return panel
  }

  private func hidePanel(close: Bool) {
    panelTimer?.invalidate()
    panelTimer = nil
    panel?.delegate = nil
    if close {
      panel?.orderOut(nil)
    }
    panel = nil
    playButton = nil
    panelSlider = nil
    panelStatus = nil
    panelReminder = nil
  }

  private func updatePanel(for glasses: NSScreen) {
    let host = Self.builtInScreen(excluding: glasses) ?? NSScreen.screens.first { $0 != glasses } ?? glasses
    let sameScreen = host == glasses || NSScreen.screens.count == 1
    let pixels = Self.pixelSize(of: glasses)
    panelReminder?.stringValue = Self.glassesReminder(fullSizeEyes: Self.isFullWidthSBS(glasses))
    if sameScreen {
      panelStatus?.stringValue = Self.isMirrored(glasses)
        ? "Mirroring is on, so this panel shares the glasses screen (\(pixels.width)×\(pixels.height))."
        : "Only one display is connected (\(pixels.width)×\(pixels.height)), so these controls sit on the glasses screen."
    } else {
      panelStatus?.stringValue = "Showing on \(glasses.localizedName) (\(pixels.width)×\(pixels.height)). Controls stay on this Mac."
    }
    panel?.level = Self.panelLevel
    panel?.orderFrontRegardless()
  }

  private static var panelLevel: NSWindow.Level {
    let video = glassesWindowLevel.rawValue
    let maxLevel = Int(CGWindowLevelForKey(.maximumWindow))
    let raw = video >= maxLevel ? video : video + 1
    return NSWindow.Level(rawValue: raw)
  }

  private func refreshTransport() {
    guard playButton != nil else { return }
    guard !PlayerCore.playerCores.isEmpty else { return }
    let paused = PlayerCore.active.info.state == .paused || PlayerCore.active.info.state == .idle
    playButton?.title = paused ? "Play" : "Pause"
    if let panelSlider, abs(panelSlider.doubleValue - Preference.double(for: .immersive3DStrength)) > 0.001 {
      panelSlider.doubleValue = Preference.double(for: .immersive3DStrength)
    }
  }

  @objc func togglePlay(_ sender: Any?) {
    PlayerCore.active.togglePause(nil)
    refreshTransport()
  }

  @objc func exitGlassesClicked(_ sender: Any?) {
    perform(session.transition(.exit))
  }

  @objc func panelPresetChanged(_ sender: NSPopUpButton) {
    let preset = StrengthPreset(rawValue: sender.indexOfSelectedItem) ?? .standard
    Preference.set(preset.rawValue, for: .immersive3DPreset)
    Preference.set(preset.strength, for: .immersive3DStrength)
    publishAndRedraw()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    panelIsClosing = true
    perform(session.transition(.exit))
    panelIsClosing = false
    return true
  }

  // MARK: - Displays

  static func isBuiltIn(_ screen: NSScreen) -> Bool {
    guard let id = screen.displayId else { return false }
    return CGDisplayIsBuiltin(id) != 0
  }

  static func externalScreens() -> [NSScreen] {
    NSScreen.screens.filter { !isBuiltIn($0) }
  }

  static func pixelSize(of screen: NSScreen) -> (width: Int, height: Int) {
    GlassesDrawable.pixels(
      pointsWidth: Double(screen.frame.width),
      pointsHeight: Double(screen.frame.height),
      scale: Double(screen.backingScaleFactor)
    ) ?? (width: 0, height: 0)
  }

  static func displayChoice(for screen: NSScreen) -> GlassesDisplayChoice {
    let pixels = pixelSize(of: screen)
    return GlassesDisplayChoice(
      id: screen.displayId ?? 0,
      pixelWidth: pixels.width,
      pixelHeight: pixels.height,
      fullSizeEyes: isFullWidthSBS(screen),
      name: screen.localizedName
    )
  }

  static func isMirrored(_ screen: NSScreen) -> Bool {
    guard let id = screen.displayId else { return false }
    return isMirrored(id)
  }

  static func isMirrored(_ id: CGDirectDisplayID) -> Bool {
    id != 0 && CGDisplayIsInMirrorSet(id) != 0
  }

  /// Session-scoped. A mirrored glasses display becomes an extended desktop until Play on Glasses stops.
  /// Returns true when a configuration was applied.
  @discardableResult
  private func ensureGlassesExtended() -> Bool {
    guard Preference.bool(for: .immersive3DAutoGlassesDisplay) else { return false }
    guard let id = glassesDisplayID, Self.isMirrored(id) else { return false }
    if Date().timeIntervalSince(lastMirrorConfigure) < 0.4 { return false }
    lastMirrorConfigure = Date()
    return separateGlassesFromMirrorSet(id)
  }

  /// `CGConfigureDisplayMirrorOfDisplay(config, glassesID, kCGNullDirectDisplay)` plus the same
  /// for any display that is mirroring the glasses, so a set whose primary is the glasses still splits.
  private func separateGlassesFromMirrorSet(_ glassesID: CGDirectDisplayID) -> Bool {
    let capturedNow = savedMirrorLinks == nil
    if capturedNow {
      savedMirrorLinks = Self.captureMirrorLinks()
    }
    let members = Self.mirrorSetMembers(including: glassesID)
    var changes: [(CGDirectDisplayID, CGDirectDisplayID)] = [(glassesID, kCGNullDirectDisplay)]
    for id in members where id != glassesID && CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay {
      changes.append((id, kCGNullDirectDisplay))
    }
    if applyMirrorConfiguration(changes) {
      log3D("Play on glasses: display \(glassesID) left the mirror set for this login session", level: .warning)
      return true
    }
    let secondaries = changes.filter { $0.0 != glassesID }
    if !secondaries.isEmpty, applyMirrorConfiguration(secondaries) {
      log3D("Play on glasses: displays mirroring \(glassesID) left the mirror set for this login session", level: .warning)
      return true
    }
    if capturedNow {
      savedMirrorLinks = nil
    }
    log3D("Play on glasses: could not leave the mirror set", level: .error)
    return false
  }

  private func restoreMirroringIfNeeded() {
    guard let links = savedMirrorLinks else { return }
    savedMirrorLinks = nil
    let mirroring = links.filter { $0.master != kCGNullDirectDisplay }
    guard !mirroring.isEmpty else { return }
    var changes: [(CGDirectDisplayID, CGDirectDisplayID)] = []
    for link in mirroring {
      guard let display = Self.resolve(link.display, uuid: link.displayUUID),
            let master = Self.resolve(link.master, uuid: link.masterUUID) else {
        log3D("Skipping mirror restore; a display from the original mirror set is offline", level: .warning)
        continue
      }
      changes.append((display, master))
    }
    guard applyMirrorConfiguration(changes) else {
      log3D("Restoring glasses mirroring failed", level: .error)
      return
    }
    log3D("Restored glasses mirroring", level: .warning)
  }

  private func applyMirrorConfiguration(_ changes: [(CGDirectDisplayID, CGDirectDisplayID)]) -> Bool {
    guard !changes.isEmpty else { return false }
    var config: CGDisplayConfigRef?
    let began = CGBeginDisplayConfiguration(&config)
    guard began == .success, let config else {
      log3D("CGBeginDisplayConfiguration failed (\(began.rawValue))", level: .error)
      return false
    }
    for (display, master) in changes {
      let err = CGConfigureDisplayMirrorOfDisplay(config, display, master)
      if err != .success {
        log3D("CGConfigureDisplayMirrorOfDisplay(\(display), \(master)) failed (\(err.rawValue))", level: .error)
        CGCancelDisplayConfiguration(config)
        return false
      }
    }
    applyingDisplayConfig = true
    let done = CGCompleteDisplayConfiguration(config, .forSession)
    applyingDisplayConfig = false
    if done != .success {
      log3D("CGCompleteDisplayConfiguration(.forSession) failed (\(done.rawValue))", level: .error)
      return false
    }
    return true
  }

  private static func captureMirrorLinks() -> [SavedMirrorLink] {
    onlineDisplayIDs().compactMap { id in
      let master = CGDisplayMirrorsDisplay(id)
      guard master != kCGNullDirectDisplay else { return nil }
      return SavedMirrorLink(
        display: id,
        master: master,
        displayUUID: displayUUID(id),
        masterUUID: displayUUID(master)
      )
    }
  }

  /// Primary plus every display mirroring it, always including `glassesID`.
  private static func mirrorSetMembers(including glassesID: CGDirectDisplayID) -> [CGDirectDisplayID] {
    let mirrored = CGDisplayMirrorsDisplay(glassesID)
    let primary: CGDirectDisplayID = mirrored == kCGNullDirectDisplay ? glassesID : mirrored
    var members: [CGDirectDisplayID] = []
    for id in onlineDisplayIDs() where id == primary || id == glassesID || CGDisplayMirrorsDisplay(id) == primary {
      if !members.contains(id) {
        members.append(id)
      }
    }
    if !members.contains(glassesID) {
      members.append(glassesID)
    }
    return members
  }

  private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
  }

  private static func resolve(_ id: CGDirectDisplayID, uuid: UUID?) -> CGDirectDisplayID? {
    let online = onlineDisplayIDs()
    if online.contains(id) { return id }
    guard let uuid else { return nil }
    return online.first { displayUUID($0) == uuid }
  }

  private static func displayUUID(_ id: CGDirectDisplayID) -> UUID? {
    guard id != 0, let raw = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    let bytes = CFUUIDGetUUIDBytes(raw)
    return UUID(uuid: (
      bytes.byte0, bytes.byte1, bytes.byte2, bytes.byte3,
      bytes.byte4, bytes.byte5, bytes.byte6, bytes.byte7,
      bytes.byte8, bytes.byte9, bytes.byte10, bytes.byte11,
      bytes.byte12, bytes.byte13, bytes.byte14, bytes.byte15
    ))
  }

  static func isGlassesName(_ screen: NSScreen) -> Bool {
    let name = screen.localizedName.lowercased()
    return name.contains("smartglasses") || name.contains("nxtwear")
  }

  /// 3840×1080, or any similarly double-wide mode. Each eye is one full half.
  static func isFullWidthSBS(_ screen: NSScreen) -> Bool {
    let pixels = pixelSize(of: screen)
    guard pixels.height > 0 else { return false }
    if pixels.width == 3840 && pixels.height == 1080 { return true }
    return Double(pixels.width) / Double(pixels.height) >= 3.2
  }

  /// 1920×1080. The shader packs half-width side-by-side into this frame.
  static func isHalfWidthSBS(_ screen: NSScreen) -> Bool {
    let pixels = pixelSize(of: screen)
    return pixels.width == 1920 && pixels.height == 1080
  }

  static func looksLikeNXTWEAR(_ screen: NSScreen) -> Bool {
    if isGlassesName(screen) { return true }
    if isBuiltIn(screen) { return false }
    return isFullWidthSBS(screen) || isHalfWidthSBS(screen)
  }

  /// Named SmartGlasses / NXTWEAR first (including a mirrored main screen), then a
  /// 3840×1080 or 1920×1080 external display.
  static func glassesCandidates() -> [NSScreen] {
    let screens = NSScreen.screens
    let named = screens.filter { isGlassesName($0) }
    if !named.isEmpty { return named }
    let wide = screens.filter { isFullWidthSBS($0) && !isBuiltIn($0) }
    if !wide.isEmpty { return wide }
    let standard = screens.filter { isHalfWidthSBS($0) && !isBuiltIn($0) }
    if !standard.isEmpty { return standard }
    return []
  }

  static func framesMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) < 0.5
      && abs(lhs.origin.y - rhs.origin.y) < 0.5
      && abs(lhs.size.width - rhs.size.width) < 0.5
      && abs(lhs.size.height - rhs.size.height) < 0.5
  }

  static func builtInScreen(excluding glasses: NSScreen) -> NSScreen? {
    NSScreen.screens.first { isBuiltIn($0) && $0 != glasses }
  }

  private func rebuildGlassesItem() {
    guard let glassesItem else { return }
    if glassesActive || captureOnGlasses {
      glassesItem.submenu = nil
      glassesItem.title = "Exit Glasses"
      glassesItem.action = #selector(playOnGlasses(_:))
      glassesItem.target = self
      glassesItem.state = .on
      return
    }
    let screens = Self.glassesCandidates()
    glassesItem.state = .off
    if screens.count <= 1 {
      glassesItem.submenu = nil
      glassesItem.action = #selector(playOnGlasses(_:))
      glassesItem.target = self
      if let only = screens.first {
        glassesItem.title = "Play on Glasses (\(displayTitle(only)))"
      } else {
        glassesItem.title = "Play on Glasses"
      }
      return
    }
    let menu = NSMenu(title: "Play on Glasses")
    for screen in screens {
      let item = NSMenuItem(title: displayTitle(screen), action: #selector(playOnScreen(_:)), keyEquivalent: "")
      item.target = self
      if let id = screen.displayId {
        item.representedObject = NSNumber(value: id)
      }
      menu.addItem(item)
    }
    glassesItem.submenu = menu
    glassesItem.title = "Play on Glasses"
  }

  private func displayTitle(_ screen: NSScreen) -> String {
    let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
    if Self.looksLikeNXTWEAR(screen) {
      return "\(screen.localizedName) — \(size), likely NXTWEAR S"
    }
    return "\(screen.localizedName) — \(size)"
  }

  // MARK: - State

  private func publishAndRedraw() {
    lock.lock()
    rebuildSnapshotLocked()
    lock.unlock()
    syncMenu()
    requestRedraw()
  }

  private func rebuildSnapshotLocked() {
    let mode = Preference.integer(for: .immersive3DSourceMode)
    let pass: Bool
    switch mode {
    case SourceMode.alreadySBS.rawValue: pass = true
    case SourceMode.alwaysConvert.rawValue: pass = false
    default: pass = mediaLooksLikeSBS
    }
    snapshot = Snapshot(
      enabled: Preference.bool(for: .immersive3DEnabled),
      maxShift: Self.maxShift(forStrength: Preference.double(for: .immersive3DStrength)),
      convergence: 0.5,
      invertDepth: Preference.bool(for: .immersive3DInvertDepth),
      verticalFlip: Preference.bool(for: .immersive3DVerticalFlip),
      passThroughSBS: pass,
      fullSizeEyes: glassesFullSizeEyes
    )
  }

  private func requestRedraw() {
    let work = {
      guard !PlayerCore.playerCores.isEmpty else { return }
      let player = PlayerCore.active
      guard player.mainWindow.window?.contentView != nil else { return }
      player.mainWindow.videoView.videoLayer.update(force: true)
    }
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  private func playerOSD(_ text: String) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.playerOSD(text) }
      return
    }
    guard !PlayerCore.playerCores.isEmpty else { return }
    PlayerCore.active.sendOSD(.custom(text))
  }

  private func showMessage(title: String, body: String) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = title
    alert.informativeText = body
    alert.runModal()
  }

  private func modelItem(_ title: String, tag: Int, menu: NSMenu) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(chooseDepthModel(_:)), keyEquivalent: "")
    item.target = self
    item.tag = tag
    menu.addItem(item)
    return item
  }

  private func presetItem(_ preset: StrengthPreset, menu: NSMenu) -> NSMenuItem {
    let item = NSMenuItem(title: preset.title, action: #selector(choosePreset(_:)), keyEquivalent: "")
    item.target = self
    item.tag = preset.rawValue
    menu.addItem(item)
    return item
  }

  private func modeItem(_ title: String, mode: SourceMode, menu: NSMenu) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(chooseSourceMode(_:)), keyEquivalent: "")
    item.target = self
    item.tag = mode.rawValue
    menu.addItem(item)
    return item
  }

  private func toggleItem(_ title: String, action: Selector, menu: NSMenu) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    menu.addItem(item)
    return item
  }
}

private struct SavedMirrorLink {
  var display: CGDirectDisplayID
  var master: CGDirectDisplayID
  var displayUUID: UUID?
  var masterUUID: UUID?
}

private struct SavedWindow {
  var frame: NSRect
  var styleMask: NSWindow.StyleMask
  var level: NSWindow.Level
  var collectionBehavior: NSWindow.CollectionBehavior
  var isMovable: Bool
  var hasShadow: Bool
  var titlebarAppearsTransparent: Bool
  var titleVisibility: NSWindow.TitleVisibility
  var aspectRatio: NSSize
  var contentAspectRatio: NSSize
  var minSize: NSSize
  var contentMinSize: NSSize
  var resizeIncrements: NSSize
  var isOpaque: Bool
  var backgroundColor: NSColor
  var hidesOnDeactivate: Bool
  var disableUI: Bool
  var immersiveWasEnabled: Bool
}
