//
//  BrowserCaptureWindowController.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Chooser, preview, and the glasses output for one captured window.

import Cocoa

@available(macOS 12.3, *)
final class BrowserCaptureWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
  static let shared = BrowserCaptureWindowController(window: nil)

  private let manager = BrowserCaptureManager.shared
  private let renderer = BrowserCaptureRenderer(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
  private let settings = BrowserCaptureSettings.shared
  private var outputWindow: NSWindow?
  private var previewFrame = NSRect(x: 0, y: 0, width: 960, height: 540)
  private var onGlasses = false
  private var rows: [BrowserCaptureTarget] = []
  private var selected: BrowserCaptureTarget?
  private var table: NSTableView?
  private var statusLabel: NSTextField?
  private var outputMessage: NSTextField?
  private var audioCheckbox: NSButton?
  private var routePanel: NSPanel?
  private var routePanelCheckbox: NSButton?
  private var routePanelStatus: NSTextField?
  private var hintLabel: NSTextField?
  private var cropSegments: NSSegmentedControl?
  private var topSlider: NSSlider?
  private var bottomSlider: NSSlider?
  private var leftSlider: NSSlider?
  private var rightSlider: NSSlider?
  private var topLabel: NSTextField?
  private var bottomLabel: NSTextField?
  private var leftLabel: NSTextField?
  private var rightLabel: NSTextField?
  private var suppressControls = false
  private var refreshingPixels = false
  private var chooseItem: NSMenuItem?
  private var toggleItem: NSMenuItem?
  private var glassesItem: NSMenuItem?
  private var audioItem: NSMenuItem?
  private var uninstallAudioItem: NSMenuItem?
  private var chromeItem: NSMenuItem?
  private var videoItem: NSMenuItem?
  private var syncTestItem: NSMenuItem?

  private var audioAvailable: Bool {
    if #available(macOS 13.0, *) { return true }
    return false
  }

  override init(window: NSWindow?) {
    let chooser = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    chooser.title = "Choose Capture Window"
    super.init(window: chooser)
    buildChooser()
    manager.onFrame = { [weak self] buffer, time, received, done in
      guard let self else {
        done()
        return
      }
      self.renderer.consume(buffer, at: time, received: received, done: done)
    }
    manager.onIdle = { [weak self] in
      self?.renderer.presentHeld()
    }
    manager.excludedWindowIDs = { [weak self] in
      self?.excludedWindowIDs() ?? []
    }
    manager.onStatus = { [weak self] text in
      self?.showOutputMessage(text)
      if let text { self?.setStatus(text) }
    }
    manager.onNote = { [weak self] text in
      self?.setStatus(text)
      if self?.window?.isVisible != true {
        self?.showOutputMessage(text)
      }
    }
    manager.onStopped = { [weak self] in
      DispatchQueue.main.async {
        Immersive3DController.shared.captureDidStop()
        self?.hideRoutePanel()
      }
    }
    settings.onDetected = { [weak self] insets in
      self?.showDetected(insets)
    }
    renderer.onBlack = { [weak self] black in
      self?.showOutputMessage(black ? BrowserCaptureManager.protectedMessage : nil)
    }
    CaptureAVSyncTest.shared.currentOffsetMs = { BrowserCaptureSettings.shared.syncOffsetMs }
    CaptureAVSyncTest.shared.onLine = { [weak self] text in
      self?.setStatus(text)
    }
    Immersive3DController.shared.captureGlassesHandler = { [weak self] screen, fullSize in
      self?.applyGlassesScreen(screen, fullSizeEyes: fullSize)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func makeMenuItems() -> [NSMenuItem] {
    let choose = NSMenuItem(title: "Choose Capture Window…", action: #selector(showChooser(_:)), keyEquivalent: "")
    choose.target = self
    chooseItem = choose
    let toggle = NSMenuItem(title: "Start Capture", action: #selector(toggleCapture(_:)), keyEquivalent: "")
    toggle.target = self
    toggleItem = toggle
    let glasses = NSMenuItem(title: "Send Capture to Glasses", action: #selector(toggleGlasses(_:)), keyEquivalent: "")
    glasses.target = self
    glassesItem = glasses
    let audio = NSMenuItem(title: CaptureOutputRoute.toggleTitle, action: #selector(toggleAudioMenu(_:)), keyEquivalent: "")
    audio.target = self
    audioItem = audio
    let uninstall = NSMenuItem(title: "Uninstall IINA Capture Audio…", action: #selector(uninstallCaptureAudio(_:)), keyEquivalent: "")
    uninstall.target = self
    uninstallAudioItem = uninstall
    let chrome = NSMenuItem(title: "Crop Window Chrome", action: #selector(cropChromeMenu(_:)), keyEquivalent: "")
    chrome.target = self
    chromeItem = chrome
    let video = NSMenuItem(title: "Detect Video Area", action: #selector(detectVideoMenu(_:)), keyEquivalent: "")
    video.target = self
    videoItem = video
    let syncTest = NSMenuItem(title: "A/V Sync Test", action: #selector(toggleSyncTest(_:)), keyEquivalent: "")
    syncTest.target = self
    syncTestItem = syncTest
    return [choose, toggle, glasses, audio, uninstall, syncTest, chrome, video]
  }

  func syncMenu() {
    toggleItem?.title = manager.isRunning ? "Stop Capture" : "Start Capture"
    glassesItem?.title = onGlasses ? "Stop Sending Capture to Glasses" : "Send Capture to Glasses"
    glassesItem?.isEnabled = manager.isRunning || onGlasses
    audioItem?.state = audioAvailable && settings.wantsAudio ? .on : .off
    audioItem?.isEnabled = audioAvailable
    uninstallAudioItem?.isEnabled = CaptureSystemOutput.ourDeviceInstalled()
    let mode = settings.cropMode
    chromeItem?.state = mode == .autoChrome ? .on : .off
    videoItem?.state = mode == .videoArea ? .on : .off
    syncTestItem?.title = CaptureAVSyncTest.shared.isRunning ? "Stop A/V Sync Test" : "A/V Sync Test"
  }

  @objc func toggleSyncTest(_ sender: Any?) {
    // This item is tracking the click. Retitling it now releases the view the
    // menu run loop still has in its autorelease pool, and the pool's
    // objc_release crashes at 0x20. menuWillOpen refreshes the title.
    if CaptureAVSyncTest.shared.isRunning {
      CaptureAVSyncTest.shared.stop()
    } else {
      CaptureAVSyncTest.shared.start()
    }
  }

  func stopAll() {
    Immersive3DController.shared.captureDidStop()
    onGlasses = false
    outputWindow?.orderOut(nil)
    hideRoutePanel()
    Task { await manager.stop() }
    syncMenu()
  }

  func excludedWindowIDs() -> Set<CGWindowID> {
    var ids = Set<CGWindowID>()
    if let number = outputWindow?.windowNumber, number > 0 {
      ids.insert(CGWindowID(number))
    }
    if let number = window?.windowNumber, number > 0 {
      ids.insert(CGWindowID(number))
    }
    if Immersive3DController.shared.glassesActive,
       !PlayerCore.playerCores.isEmpty,
       let number = PlayerCore.active.mainWindow.window?.windowNumber,
       number > 0 {
      ids.insert(CGWindowID(number))
    }
    return ids
  }

  @objc func showChooser(_ sender: Any?) {
    guard ensurePermission() else { return }
    reflectSettings()
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    reload()
  }

  @objc func toggleCapture(_ sender: Any?) {
    if manager.isRunning {
      Task { [weak self] in
        await self?.manager.stop()
        DispatchQueue.main.async {
          Immersive3DController.shared.captureDidStop()
          self?.syncMenu()
          self?.setStatus("Capture stopped.")
        }
      }
      return
    }
    guard let selected else {
      showChooser(sender)
      setStatus("Choose a window, then start capture.")
      return
    }
    beginCapture(selected)
  }

  @objc func toggleGlasses(_ sender: Any?) {
    guard manager.isRunning || Immersive3DController.shared.captureOnGlasses else {
      setStatus("Start capture, then send it to the glasses.")
      return
    }
    Immersive3DController.shared.playOnGlasses(sender)
  }

  /// The glasses session asked for the capture picture. Returns false when the display cannot be used.
  func presentCapture(on screen: NSScreen) -> Bool {
    guard ensureOutput() != nil else { return false }
    onGlasses = true
    guard let outputWindow else {
      onGlasses = false
      return false
    }
    let pixels = Immersive3DController.pixelSize(of: screen)
    renderer.setFullSizeEyes(Immersive3DController.isFullWidthSBS(screen))
    renderer.setPixelSize(width: pixels.width, height: pixels.height, scale: screen.backingScaleFactor, lock: true)
    guard Immersive3DController.shared.placeWindowOnGlasses(outputWindow) != nil else {
      onGlasses = false
      renderer.unlockPixelSize()
      fitRendererToWindow()
      setStatus("No SmartGlasses, NXTWEAR, or 3840×1080 / 1920×1080 display is connected.")
      return false
    }
    applyGlassesScreen(screen, fullSizeEyes: Immersive3DController.isFullWidthSBS(screen))
    browserCaptureLog.info("glasses source capture \(pixels.width)x\(pixels.height) \(screen.localizedName, privacy: .public)")
    let handoff = CaptureGlassesAudioHandoff.afterPin(readerRunning: manager.routedAudioIsRunning)
    if handoff.reopenOutput {
      manager.reopenLoopbackOutput()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak manager] in
        guard let manager else { return }
        if CaptureGlassesAudioHandoff.afterPin(readerRunning: manager.routedAudioIsRunning).reopenOutput {
          manager.reopenLoopbackOutput()
        }
      }
    }
    syncMenu()
    return true
  }

  func returnCaptureToPreview() {
    guard let output = outputWindow else {
      onGlasses = false
      renderer.unlockPixelSize()
      return
    }
    onGlasses = false
    renderer.setFullSizeEyes(false)
    renderer.unlockPixelSize()
    Immersive3DController.shared.returnWindowFromGlasses(output, previewFrame: previewFrame)
    fitRendererToWindow()
    syncMenu()
  }

  @objc func toggleAudioMenu(_ sender: Any?) {
    setRouteEnabled(!settings.wantsAudio)
  }

  @objc func uninstallCaptureAudio(_ sender: Any?) {
    guard CaptureSystemOutput.ourDeviceInstalled() else {
      setStatus("IINA Capture Audio is not installed.")
      return
    }
    settings.setPlayAudio(false)
    if manager.isRunning {
      manager.stopRoutedAudio()
      CaptureAudioRouteController.end()
    }
    if CaptureAudioInstaller.uninstall() {
      setStatus("IINA Capture Audio was removed. Sound stays in the other app.")
    } else {
      setStatus("IINA Capture Audio was not removed.")
    }
    reflectSettings()
    syncMenu()
  }

  @objc func cropChromeMenu(_ sender: Any?) {
    settings.setMode(.autoChrome)
    renderer.requestCropAnalysis()
    reflectSettings()
    syncMenu()
  }

  @objc func detectVideoMenu(_ sender: Any?) {
    settings.setMode(.videoArea)
    renderer.requestCropAnalysis()
    reflectSettings()
    syncMenu()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }

  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    guard rows.indices.contains(row) else { return nil }
    return rows[row].label
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard rows.indices.contains(row) else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("capture-window")
    let label = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
    label.identifier = identifier
    label.stringValue = rows[row].label
    label.lineBreakMode = .byTruncatingTail
    return label
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard let table, table.selectedRow >= 0, rows.indices.contains(table.selectedRow) else { return }
    selected = rows[table.selectedRow]
  }

  private func buildChooser() {
    guard let content = window?.contentView else { return }
    let scroll = NSScrollView(frame: NSRect(x: 20, y: 384, width: 520, height: 280))
    let table = NSTableView(frame: scroll.bounds)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
    column.title = "Window"
    column.width = 500
    table.addTableColumn(column)
    table.headerView = nil
    table.dataSource = self
    table.delegate = self
    table.rowHeight = 22
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    self.table = table

    let audio = NSButton(checkboxWithTitle: CaptureOutputRoute.toggleTitle, target: self, action: #selector(audioCheckboxChanged(_:)))
    audio.frame = NSRect(x: 20, y: 354, width: 520, height: 22)
    audio.font = .systemFont(ofSize: 12)
    audioCheckbox = audio

    let sync = CaptureSyncOffsetControl(placement: .controls)
    sync.frame = NSRect(x: 20, y: 324, width: 520, height: 28)

    let hint = NSTextField(wrappingLabelWithString: hintText())
    hint.font = .systemFont(ofSize: 11)
    hint.textColor = .secondaryLabelColor
    hint.frame = NSRect(x: 20, y: 280, width: 520, height: 40)
    hintLabel = hint

    let segments = NSSegmentedControl(labels: ["Crop chrome", "Video area", "Manual"], trackingMode: .selectOne, target: self, action: #selector(cropModeChanged(_:)))
    segments.frame = NSRect(x: 20, y: 252, width: 520, height: 26)
    segments.selectedSegment = settings.cropMode.rawValue
    cropSegments = segments

    (topSlider, topLabel) = addSlider(title: "Top", y: 220, tag: 0, content: content)
    (bottomSlider, bottomLabel) = addSlider(title: "Bottom", y: 192, tag: 1, content: content)
    (leftSlider, leftLabel) = addSlider(title: "Left", y: 164, tag: 2, content: content)
    (rightSlider, rightLabel) = addSlider(title: "Right", y: 136, tag: 3, content: content)

    let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked(_:)))
    refresh.bezelStyle = .rounded
    refresh.frame = NSRect(x: 20, y: 96, width: 100, height: 28)
    let use = NSButton(title: "Use This Window", target: self, action: #selector(useClicked(_:)))
    use.bezelStyle = .rounded
    use.frame = NSRect(x: 380, y: 96, width: 160, height: 28)
    let status = NSTextField(wrappingLabelWithString: "Chrome crop removes a top bar. Video area trims black borders. Sliders set each edge.")
    status.font = .systemFont(ofSize: 12)
    status.textColor = .secondaryLabelColor
    status.frame = NSRect(x: 20, y: 12, width: 520, height: 76)
    statusLabel = status
    content.addSubview(scroll)
    content.addSubview(audio)
    content.addSubview(sync)
    content.addSubview(hint)
    content.addSubview(segments)
    content.addSubview(refresh)
    content.addSubview(use)
    content.addSubview(status)
    reflectSettings()
  }

  private func addSlider(title: String, y: CGFloat, tag: Int, content: NSView) -> (NSSlider, NSTextField) {
    let label = NSTextField(labelWithString: "\(title) 0%")
    label.font = .systemFont(ofSize: 12)
    label.frame = NSRect(x: 20, y: y, width: 90, height: 18)
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 0.45, target: self, action: #selector(cropSliderChanged(_:)))
    slider.frame = NSRect(x: 114, y: y - 2, width: 426, height: 22)
    slider.tag = tag
    slider.isContinuous = true
    content.addSubview(label)
    content.addSubview(slider)
    return (slider, label)
  }

  @objc private func audioCheckboxChanged(_ sender: NSButton) {
    setRouteEnabled(sender.state == .on)
  }

  private func setRouteEnabled(_ on: Bool) {
    guard audioAvailable else {
      settings.setPlayAudio(false)
      reflectSettings()
      syncMenu()
      logRoute(.needsMacOS13)
      return
    }
    if !on {
      settings.setPlayAudio(false)
      manager.stopRoutedAudio()
      CaptureAudioRouteController.end()
      reflectSettings()
      syncMenu()
      setStatus("Sound stays in the other app.")
      logRoute(.toggleOff)
      return
    }
    guard ensureCaptureDevice() else {
      settings.setPlayAudio(false)
      reflectSettings()
      syncMenu()
      setStatus("IINA Capture Audio was not installed. Sound stays in the other app.")
      logRoute(.deviceMissing)
      return
    }
    settings.setPlayAudio(true)
    reflectSettings()
    syncMenu()
    guard manager.isRunning else {
      logRoute(.notCapturing)
      return
    }
    switch CaptureAudioRouteController.beginIfEnabled() {
    case .routed, .already:
      setStatus("Browser sound is playing through IINA, in time with the picture.")
      logRoute(.started)
    case .refused:
      settings.setPlayAudio(false)
      reflectSettings()
      syncMenu()
      setStatus("Browser sound stayed in the other app because the previous output could not be saved.")
      logRoute(.previousOutputNotSaved)
    }
  }

  private func logRoute(_ offer: CaptureAudioPolicy.Offer) {
    let installed = CaptureSystemOutput.ourDeviceInstalled()
    browserCaptureLog.info("\(CaptureAudioPolicy.deviceLine(installed: installed), privacy: .public)")
    browserCaptureLog.info("\(offer.logLine, privacy: .public)")
    updateRoutePanel()
  }

  private func ensureCaptureDevice() -> Bool {
    if CaptureSystemOutput.ourDeviceInstalled() { return true }
    return CaptureAudioInstaller.install()
  }

  @objc private func cropModeChanged(_ sender: NSSegmentedControl) {
    if suppressControls { return }
    let mode = BrowserCaptureCropMode(rawValue: sender.selectedSegment) ?? .autoChrome
    settings.setMode(mode)
    renderer.requestCropAnalysis()
    syncMenu()
  }

  @objc private func cropSliderChanged(_ sender: NSSlider) {
    if suppressControls { return }
    let insets = currentSliderInsets()
    settings.setManual(insets)
    suppressControls = true
    cropSegments?.selectedSegment = BrowserCaptureCropMode.manual.rawValue
    suppressControls = false
    updateCropLabels(insets)
    syncMenu()
  }

  @objc private func refreshClicked(_ sender: Any?) {
    reload()
  }

  @objc private func useClicked(_ sender: Any?) {
    guard let table, table.selectedRow >= 0, rows.indices.contains(table.selectedRow) else {
      setStatus("Select a window in the list.")
      return
    }
    let target = rows[table.selectedRow]
    selected = target
    beginCapture(target)
  }

  private func reload() {
    let excluded = excludedWindowIDs()
    setStatus("Looking for windows…")
    Task { [weak self] in
      do {
        let found = try await self?.manager.targets(excluding: excluded) ?? []
        DispatchQueue.main.async {
          self?.rows = found
          self?.table?.reloadData()
          if let selected = self?.selected, let match = found.first(where: { $0.key == selected.key }) {
            self?.selected = match
          }
          self?.setStatus(found.isEmpty ? "No other windows are available." : "\(found.count) sources, including full-screen windows and Capture whole display. IINA's own output is left out.")
        }
      } catch {
        DispatchQueue.main.async {
          self?.setStatus(error.localizedDescription)
        }
      }
    }
  }

  private func beginCapture(_ target: BrowserCaptureTarget) {
    guard ensurePermission() else { return }
    let excluded = excludedWindowIDs()
    guard ensureOutput() != nil else { return }
    setStatus("Starting capture…")
    showOutputMessage(nil)
    Task { [weak self] in
      do {
        try await self?.manager.start(target, excluding: excluded)
        DispatchQueue.main.async {
          let offer = self?.startRoutingIfEnabled() ?? CaptureAudioPolicy.Offer.toggleOff
          self?.logRoute(offer)
          self?.showRoutePanel()
          self?.syncMenu()
          self?.setStatus(self?.captureStatus() ?? "Capturing.")
          self?.window?.orderOut(nil)
          Immersive3DController.shared.captureDidStart()
        }
      } catch {
        DispatchQueue.main.async {
          self?.setStatus(error.localizedDescription)
          self?.syncMenu()
        }
      }
    }
  }

  /// The chooser is about to close. Start the loopback only when the toggle is already on, and always say why.
  private func startRoutingIfEnabled() -> CaptureAudioPolicy.Offer {
    guard audioAvailable else { return .needsMacOS13 }
    guard settings.wantsAudio else { return .toggleOff }
    guard ensureCaptureDevice() else {
      settings.setPlayAudio(false)
      return .deviceMissing
    }
    switch CaptureAudioRouteController.beginIfEnabled() {
    case .routed, .already:
      return .started
    case .refused:
      settings.setPlayAudio(false)
      return .previousOutputNotSaved
    }
  }

  private func restartIfRunning() {
    guard manager.isRunning, let target = manager.activeTarget ?? selected else { return }
    beginCapture(target)
  }

  private func captureStatus() -> String {
    if manager.activeTarget?.kind == .display {
      return "Capturing the whole display."
    }
    if !audioAvailable {
      return "Capturing. Window audio needs macOS 13, so sound stays in the other app."
    }
    if !settings.wantsAudio || !CaptureSystemOutput.ourDeviceInstalled() {
      return "Capturing. Sound stays in the other app."
    }
    return "Capturing. Browser sound is playing through IINA, in time with the picture."
  }

  private func hintText() -> String {
    if !audioAvailable {
      return "Sound stays in the other app. Routing it through IINA needs macOS 13."
    }
    return "Plays the browser through IINA. Audio sync offset: positive delays the picture, negative delays the sound. A/V Sync Test measures a flash and a beep. macOS asks once to install IINA Capture Audio. While a capture is running, other apps use that silent device too. Stopping capture puts the previous output back."
  }

  private func reflectSettings() {
    suppressControls = true
    let routed = audioAvailable && settings.wantsAudio
    audioCheckbox?.state = routed ? .on : .off
    audioCheckbox?.isEnabled = audioAvailable
    audioCheckbox?.isHidden = false
    routePanelCheckbox?.state = routed ? .on : .off
    routePanelCheckbox?.isEnabled = audioAvailable
    updateRoutePanel()
    hintLabel?.stringValue = hintText()
    cropSegments?.selectedSegment = settings.cropMode.rawValue
    let insets = settings.appliedInsets()
    topSlider?.doubleValue = insets.top
    bottomSlider?.doubleValue = insets.bottom
    leftSlider?.doubleValue = insets.left
    rightSlider?.doubleValue = insets.right
    updateCropLabels(insets)
    suppressControls = false
  }

  private func showDetected(_ insets: BrowserCaptureInsets) {
    guard settings.cropMode != .manual else { return }
    suppressControls = true
    topSlider?.doubleValue = insets.top
    bottomSlider?.doubleValue = insets.bottom
    leftSlider?.doubleValue = insets.left
    rightSlider?.doubleValue = insets.right
    updateCropLabels(insets)
    suppressControls = false
  }

  private func currentSliderInsets() -> BrowserCaptureInsets {
    BrowserCaptureInsets(
      top: topSlider?.doubleValue ?? 0,
      left: leftSlider?.doubleValue ?? 0,
      bottom: bottomSlider?.doubleValue ?? 0,
      right: rightSlider?.doubleValue ?? 0
    )
  }

  private func updateCropLabels(_ insets: BrowserCaptureInsets) {
    topLabel?.stringValue = "Top \(percent(insets.top))"
    bottomLabel?.stringValue = "Bottom \(percent(insets.bottom))"
    leftLabel?.stringValue = "Left \(percent(insets.left))"
    rightLabel?.stringValue = "Right \(percent(insets.right))"
  }

  private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }

  private func makeRoutePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 150),
      styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.title = "Browser Capture"
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    let audio = NSButton(checkboxWithTitle: CaptureOutputRoute.toggleTitle, target: self, action: #selector(audioCheckboxChanged(_:)))
    audio.frame = NSRect(x: 16, y: 108, width: 528, height: 22)
    audio.font = .systemFont(ofSize: 12)
    routePanelCheckbox = audio
    let status = NSTextField(wrappingLabelWithString: "")
    status.font = .systemFont(ofSize: 12)
    status.frame = NSRect(x: 16, y: 16, width: 528, height: 84)
    routePanelStatus = status
    panel.contentView?.addSubview(audio)
    panel.contentView?.addSubview(status)
    return panel
  }

  /// The chooser closes when capture starts, and the picture may be on the glasses.
  /// This panel stays on the built-in display for the whole capture.
  private func showRoutePanel() {
    let panel = routePanel ?? makeRoutePanel()
    routePanel = panel
    updateRoutePanel()
    let screen = NSScreen.screens.first { Immersive3DController.isBuiltIn($0) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    var frame = panel.frame
    frame.origin.x = visible.minX + 24
    frame.origin.y = visible.minY + 24
    panel.setFrame(frame, display: true)
    panel.orderFront(nil)
  }

  private func hideRoutePanel() {
    routePanel?.orderOut(nil)
  }

  private func updateRoutePanel() {
    let routed = audioAvailable && settings.wantsAudio
    routePanelCheckbox?.state = routed ? .on : .off
    routePanelCheckbox?.isEnabled = audioAvailable
    routePanelStatus?.stringValue = CaptureAudioPolicy.statusLine(
      systemSupportsRouting: audioAvailable,
      userEnabled: settings.wantsAudio,
      deviceInstalled: CaptureSystemOutput.ourDeviceInstalled(),
      capturing: manager.isRunning
    )
  }

  private func ensurePermission() -> Bool {
    if manager.permissionGranted() { return true }
    if manager.requestPermission() { return true }
    setStatus("Screen Recording is off for IINA. Turn it on in System Settings → Privacy & Security → Screen Recording, then try again.")
    return false
  }

  private func ensureOutput() -> NSWindow? {
    if let outputWindow { return outputWindow }
    let host = NSScreen.screens.first { Immersive3DController.isBuiltIn($0) } ?? NSScreen.main
    let visible = host?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    previewFrame = NSRect(x: visible.midX - 480, y: visible.midY - 270, width: 960, height: 540)
    let window = NSWindow(
      contentRect: previewFrame,
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Browser Capture"
    window.isReleasedWhenClosed = true
    window.backgroundColor = .black
    window.delegate = self
    renderer.autoresizingMask = [.width, .height]
    window.contentView = renderer
    if outputMessage == nil {
      let message = NSTextField(wrappingLabelWithString: "")
      message.font = .systemFont(ofSize: 13, weight: .medium)
      message.textColor = .white
      message.backgroundColor = NSColor.black.withAlphaComponent(0.72)
      message.drawsBackground = true
      message.isBezeled = false
      message.isEditable = false
      message.frame = NSRect(x: 24, y: 24, width: 912, height: 96)
      message.autoresizingMask = [.width, .maxYMargin]
      message.isHidden = true
      renderer.addSubview(message)
      outputMessage = message
    }
    window.setContentSize(NSSize(width: 960, height: 540))
    window.center()
    previewFrame = window.frame
    window.orderFront(nil)
    outputWindow = window
    fitRendererToWindow()
    return window
  }

  private func applyGlassesScreen(_ screen: NSScreen, fullSizeEyes: Bool) {
    guard onGlasses, let outputWindow else { return }
    renderer.setFullSizeEyes(fullSizeEyes)
    let pixels = Immersive3DController.pixelSize(of: screen)
    guard pixels.width >= 32, pixels.height >= 32 else { return }
    let locked = GlassesDrawable.lockedPixels(
      lockedWidth: pixels.width,
      lockedHeight: pixels.height,
      interimWidth: pixels.width,
      interimHeight: pixels.height
    )
    renderer.setPixelSize(width: locked.width, height: locked.height, scale: screen.backingScaleFactor, lock: true)
    let frame = screen.frame
    let placed = outputWindow.screen?.displayId == screen.displayId
      && abs(outputWindow.frame.width - frame.width) < 1
      && abs(outputWindow.frame.height - frame.height) < 1
    if !placed {
      Immersive3DController.shared.repinExternalWindow(outputWindow, on: screen)
    }
  }

  private func fitRendererToWindow() {
    guard let outputWindow, !onGlasses else { return }
    let scale = Double(max(outputWindow.backingScaleFactor, 1))
    outputWindow.layoutIfNeeded()
    var size = renderer.bounds.size
    if size.width < 32 || size.height < 32 {
      outputWindow.setContentSize(NSSize(width: CGFloat(GlassesDrawable.previewPointWidth), height: CGFloat(GlassesDrawable.previewPointHeight)))
      outputWindow.layoutIfNeeded()
      size = renderer.bounds.size
    }
    let pixels = GlassesDrawable.pixels(pointsWidth: Double(size.width), pointsHeight: Double(size.height), scale: scale)
      ?? GlassesDrawable.previewPixels(scale: scale)
    renderer.setPixelSize(width: pixels.width, height: pixels.height, scale: CGFloat(scale), lock: false)
  }

  private func refreshOutputPixels() {
    if refreshingPixels { return }
    refreshingPixels = true
    defer { refreshingPixels = false }
    if onGlasses {
      renderer.reapplyLockedSize()
    } else {
      fitRendererToWindow()
    }
  }

  private func showOutputMessage(_ text: String?) {
    let work = {
      self.outputMessage?.stringValue = text ?? ""
      self.outputMessage?.isHidden = text == nil || text?.isEmpty == true
    }
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  private func setStatus(_ text: String) {
    let work: () -> Void = { self.statusLabel?.stringValue = text }
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  func windowDidResize(_ notification: Notification) {
    guard (notification.object as? NSWindow) == outputWindow else { return }
    refreshOutputPixels()
  }

  func windowDidChangeScreen(_ notification: Notification) {
    guard (notification.object as? NSWindow) == outputWindow else { return }
    refreshOutputPixels()
  }

  func windowDidChangeBackingProperties(_ notification: Notification) {
    guard (notification.object as? NSWindow) == outputWindow else { return }
    refreshOutputPixels()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard sender == outputWindow else { return true }
    if onGlasses {
      Immersive3DController.shared.playOnGlasses(nil)
      return false
    }
    Task { [weak self] in
      await self?.manager.stop()
      DispatchQueue.main.async {
        Immersive3DController.shared.captureDidStop()
        self?.syncMenu()
      }
    }
    return true
  }

  func windowWillClose(_ notification: Notification) {
    guard (notification.object as? NSWindow) == outputWindow else { return }
    outputWindow = nil
    onGlasses = false
    syncMenu()
  }
}
