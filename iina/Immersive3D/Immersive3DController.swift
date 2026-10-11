//
//  Immersive3DController.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Video menu, strength presets, and "Play on glasses" for TCL NXTWEAR S.
//  The glasses enumerate as a normal external display (typically 1920×1080).

import Cocoa

final class Immersive3DController: NSObject, NSWindowDelegate {
  static let shared = Immersive3DController()

  struct Snapshot {
    var enabled = false
    var maxShift: Float = 0.033
    var convergence: Float = 0.5
    var invertDepth = false
    var verticalFlip = false
    var passThroughSBS = false
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

  static let glassesReminder = "Long-press the right-side button on your glasses to switch to 3D mode."

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
  private let prefObserver = Preference.Observer()

  private var savedWindow: SavedWindow?
  private var pendingDisplayID: CGDirectDisplayID?
  private var panel: NSPanel?
  private var panelTimer: Timer?
  private var playButton: NSButton?
  private var panelSlider: NSSlider?
  private var panelStatus: NSTextField?
  private var glassesScreen: NSScreen?
  private(set) var glassesActive = false

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

    let block = [
      enabled,
      strengthItem,
      modelMenuItem,
      sourceItem,
      NSMenuItem.separator(),
      glasses,
      NSMenuItem.separator()
    ]
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
    rebuildGlassesItem()
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
  }

  // MARK: - Glasses

  @objc func playOnGlasses(_ sender: Any?) {
    if glassesActive {
      exitGlasses()
      return
    }
    let screens = Self.externalScreens()
    if screens.isEmpty {
      showMessage(
        title: "No glasses display found",
        body: "Connect the TCL NXTWEAR S with USB-C. It should appear as an external 1920×1080 display. Then choose Video → Play on Glasses."
      )
      return
    }
    if screens.count == 1 {
      beginGlasses(on: screens[0])
    } else if let preferred = screens.first(where: { Self.looksLikeNXTWEAR($0) }) {
      beginGlasses(on: preferred)
    } else {
      beginGlasses(on: screens[0])
    }
  }

  @objc func playOnScreen(_ sender: NSMenuItem) {
    let id = (sender.representedObject as? NSNumber)?.uint32Value ?? 0
    guard let screen = NSScreen.screens.first(where: { $0.displayId == id }) else {
      showMessage(title: "That display is gone", body: "The selected screen is no longer connected.")
      return
    }
    beginGlasses(on: screen)
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
  }

  func mainWindowWillClose() {
    if glassesActive {
      exitGlasses()
    }
  }

  private func beginGlasses(on screen: NSScreen) {
    let player = PlayerCore.active
    guard !player.isInMiniPlayer else {
      showMessage(title: "Exit music mode first", body: "Play on Glasses uses the main video window.")
      return
    }
    guard player.mainWindow.window != nil else { return }
    if player.mainWindow.fsState.isFullscreen {
      pendingDisplayID = screen.displayId
      player.mainWindow.toggleWindowFullScreen()
      return
    }
    enterGlasses(on: screen)
  }

  private func enterGlasses(on screen: NSScreen) {
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
        aspectRatio: window.aspectRatio,
        disableUI: player.disableUI,
        immersiveWasEnabled: Preference.bool(for: .immersive3DEnabled)
      )
    }
    player.disableUI = true
    window.styleMask = [.borderless, .fullSizeContentView]
    window.hasShadow = false
    window.isMovable = false
    window.titlebarAppearsTransparent = true
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.aspectRatio = screen.frame.size
    window.setFrame(screen.frame, display: true, animate: false)
    window.makeKeyAndOrderFront(nil)
    player.mainWindow.hideUI(force: true)
    glassesScreen = screen
    glassesActive = true

    let snap = currentSnapshot()
    if !snap.passThroughSBS {
      setEnabled(true)
    } else {
      publishAndRedraw()
      playerOSD("Side-by-side source — passing the frame through")
    }
    showPanel(for: screen)
    player.sendOSD(.custom(Self.glassesReminder), autoHide: true, forcedTimeout: 8)
    requestRedraw()
    log3D("Play on glasses: \(screen.localizedName) \(Int(screen.frame.width))x\(Int(screen.frame.height))", level: .warning)
  }

  func exitGlasses(closePanel: Bool = true) {
    guard let saved = savedWindow else {
      hidePanel(close: closePanel)
      glassesActive = false
      return
    }
    let player = PlayerCore.active
    if let window = player.mainWindow.window {
      window.styleMask = saved.styleMask
      window.level = saved.level
      window.collectionBehavior = saved.collectionBehavior
      window.isMovable = saved.isMovable
      window.hasShadow = saved.hasShadow
      window.titlebarAppearsTransparent = saved.titlebarAppearsTransparent
      window.aspectRatio = saved.aspectRatio
      window.setFrame(saved.frame, display: true, animate: false)
    }
    player.disableUI = saved.disableUI
    savedWindow = nil
    glassesActive = false
    glassesScreen = nil
    pendingDisplayID = nil
    hidePanel(close: closePanel)
    Preference.set(saved.immersiveWasEnabled, for: .immersive3DEnabled)
    publishAndRedraw()
    if !saved.disableUI {
      player.mainWindow.showUI()
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
    let sameScreen = host == glasses
    panelStatus?.stringValue = sameScreen
      ? "Only one display is connected, so these controls sit on the glasses screen."
      : "Showing on \(glasses.localizedName) (\(Int(glasses.frame.width))×\(Int(glasses.frame.height))). Controls stay on this Mac."
    refreshTransport()
    panel.orderFrontRegardless()
    panelTimer?.invalidate()
    panelTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.refreshTransport()
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 268),
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
    title.frame = NSRect(x: 20, y: 224, width: 420, height: 22)
    let reminder = NSTextField(wrappingLabelWithString: Self.glassesReminder)
    reminder.font = .systemFont(ofSize: 13, weight: .medium)
    reminder.frame = NSRect(x: 18, y: 168, width: 424, height: 52)
    let status = NSTextField(wrappingLabelWithString: "")
    status.font = .systemFont(ofSize: 12)
    status.textColor = .secondaryLabelColor
    status.frame = NSRect(x: 18, y: 128, width: 424, height: 36)
    panelStatus = status
    let strengthName = NSTextField(labelWithString: "Depth strength")
    strengthName.frame = NSRect(x: 20, y: 96, width: 120, height: 18)
    let slider = NSSlider(value: Preference.double(for: .immersive3DStrength), minValue: 0, maxValue: 1, target: self, action: #selector(strengthSliderChanged(_:)))
    slider.isContinuous = true
    slider.frame = NSRect(x: 140, y: 94, width: 300, height: 24)
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
    for view in [title, reminder, status, strengthName, slider, presets, play, exit] {
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
    exitGlasses()
  }

  @objc func panelPresetChanged(_ sender: NSPopUpButton) {
    let preset = StrengthPreset(rawValue: sender.indexOfSelectedItem) ?? .standard
    Preference.set(preset.rawValue, for: .immersive3DPreset)
    Preference.set(preset.strength, for: .immersive3DStrength)
    publishAndRedraw()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    exitGlasses(closePanel: false)
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

  static func looksLikeNXTWEAR(_ screen: NSScreen) -> Bool {
    let frame = screen.frame
    return Int(frame.width) == 1920 && Int(frame.height) == 1080 && !isBuiltIn(screen)
  }

  static func builtInScreen(excluding glasses: NSScreen) -> NSScreen? {
    NSScreen.screens.first { isBuiltIn($0) && $0 != glasses }
  }

  private func rebuildGlassesItem() {
    guard let glassesItem else { return }
    if glassesActive {
      glassesItem.submenu = nil
      glassesItem.title = "Exit Glasses"
      glassesItem.action = #selector(playOnGlasses(_:))
      glassesItem.target = self
      glassesItem.state = .on
      return
    }
    let screens = Self.externalScreens()
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
      passThroughSBS: pass
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

private struct SavedWindow {
  var frame: NSRect
  var styleMask: NSWindow.StyleMask
  var level: NSWindow.Level
  var collectionBehavior: NSWindow.CollectionBehavior
  var isMovable: Bool
  var hasShadow: Bool
  var titlebarAppearsTransparent: Bool
  var aspectRatio: NSSize
  var disableUI: Bool
  var immersiveWasEnabled: Bool
}
