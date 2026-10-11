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
  private var muteCheckbox: NSButton?
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
  private var muteItem: NSMenuItem?
  private var chromeItem: NSMenuItem?
  private var videoItem: NSMenuItem?

  private var audioAvailable: Bool {
    if #available(macOS 13.0, *) { return true }
    return false
  }

  private var muteAvailable: Bool {
    if #available(macOS 14.2, *) { return true }
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
    manager.onFrame = { [weak self] buffer, time in
      self?.renderer.consume(buffer, at: time)
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
    manager.onMuteChanged = { [weak self] in
      self?.reflectSettings()
      self?.syncMenu()
    }
    settings.onDetected = { [weak self] insets in
      self?.showDetected(insets)
    }
    renderer.onBlack = { [weak self] black in
      self?.showOutputMessage(black ? BrowserCaptureManager.protectedMessage : nil)
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
    let audio = NSMenuItem(title: "Play Capture Audio", action: #selector(toggleAudioMenu(_:)), keyEquivalent: "")
    audio.target = self
    audioItem = audio
    let mute = NSMenuItem(title: "Mute Source App", action: #selector(toggleMuteMenu(_:)), keyEquivalent: "")
    mute.target = self
    muteItem = mute
    let chrome = NSMenuItem(title: "Crop Window Chrome", action: #selector(cropChromeMenu(_:)), keyEquivalent: "")
    chrome.target = self
    chromeItem = chrome
    let video = NSMenuItem(title: "Detect Video Area", action: #selector(detectVideoMenu(_:)), keyEquivalent: "")
    video.target = self
    videoItem = video
    return [choose, toggle, glasses, audio, mute, chrome, video]
  }

  func syncMenu() {
    toggleItem?.title = manager.isRunning ? "Stop Capture" : "Start Capture"
    glassesItem?.title = onGlasses ? "Stop Sending Capture to Glasses" : "Send Capture to Glasses"
    glassesItem?.isEnabled = manager.isRunning || onGlasses
    audioItem?.state = audioAvailable && settings.wantsAudio ? .on : .off
    audioItem?.isEnabled = audioAvailable
    muteItem?.state = muteAvailable && settings.wantsMute ? .on : .off
    muteItem?.isEnabled = muteAvailable
    let mode = settings.cropMode
    chromeItem?.state = mode == .autoChrome ? .on : .off
    videoItem?.state = mode == .videoArea ? .on : .off
  }

  func stopAll() {
    onGlasses = false
    outputWindow?.orderOut(nil)
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
    guard let output = ensureOutput() else { return }
    if onGlasses {
      onGlasses = false
      renderer.setFullSizeEyes(false)
      Immersive3DController.shared.returnWindowFromGlasses(output, previewFrame: previewFrame)
      fitRendererToWindow()
      syncMenu()
      return
    }
    guard manager.isRunning else {
      setStatus("Start capture, then send it to the glasses.")
      return
    }
    guard let placed = Immersive3DController.shared.placeWindowOnGlasses(output) else {
      setStatus("No SmartGlasses, NXTWEAR, or 3840×1080 / 1920×1080 display is connected.")
      return
    }
    onGlasses = true
    applyGlassesScreen(placed.screen, fullSizeEyes: placed.fullSizeEyes)
    syncMenu()
  }

  @objc func toggleAudioMenu(_ sender: Any?) {
    guard audioAvailable else { return }
    settings.setPlayAudio(!settings.wantsAudio)
    reflectSettings()
    syncMenu()
    restartIfRunning()
  }

  @objc func toggleMuteMenu(_ sender: Any?) {
    guard muteAvailable else {
      setStatus(BrowserCaptureManager.muteNeedsNewerOS)
      return
    }
    manager.setSourceMuted(!settings.wantsMute)
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
    let scroll = NSScrollView(frame: NSRect(x: 20, y: 356, width: 520, height: 308))
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

    let audio = NSButton(checkboxWithTitle: "Play window audio", target: self, action: #selector(audioCheckboxChanged(_:)))
    audio.frame = NSRect(x: 20, y: 326, width: 240, height: 22)
    audio.state = audioAvailable && settings.wantsAudio ? .on : .off
    audio.isEnabled = audioAvailable
    audioCheckbox = audio

    let mute = NSButton(checkboxWithTitle: "Mute source app", target: self, action: #selector(muteCheckboxChanged(_:)))
    mute.frame = NSRect(x: 280, y: 326, width: 240, height: 22)
    mute.state = muteAvailable && settings.wantsMute ? .on : .off
    mute.isEnabled = muteAvailable
    muteCheckbox = mute

    let hint = NSTextField(wrappingLabelWithString: hintText())
    hint.font = .systemFont(ofSize: 11)
    hint.textColor = .secondaryLabelColor
    hint.frame = NSRect(x: 20, y: 284, width: 520, height: 36)
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
    content.addSubview(mute)
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
    guard audioAvailable else { return }
    settings.setPlayAudio(sender.state == .on)
    syncMenu()
    restartIfRunning()
  }

  @objc private func muteCheckboxChanged(_ sender: NSButton) {
    guard muteAvailable else { return }
    manager.setSourceMuted(sender.state == .on)
    syncMenu()
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
          self?.syncMenu()
          self?.setStatus(self?.captureStatus() ?? "Capturing.")
          self?.window?.orderOut(nil)
        }
      } catch {
        DispatchQueue.main.async {
          self?.setStatus(error.localizedDescription)
          self?.syncMenu()
        }
      }
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
    if !settings.wantsAudio {
      return "Capturing. Window audio is off, so sound stays in the other app."
    }
    if settings.wantsMute {
      return "Capturing. Window audio plays with the picture, and the source app is muted."
    }
    return "Capturing. Window audio plays with the picture. The other app still plays until Mute source app is on."
  }

  private func hintText() -> String {
    if !audioAvailable {
      return "Window audio capture needs macOS 13. Sound stays in the other app."
    }
    if !muteAvailable {
      return BrowserCaptureManager.muteNeedsNewerOS
    }
    return "Mute source app silences that app while IINA plays the capture."
  }

  private func reflectSettings() {
    suppressControls = true
    audioCheckbox?.state = audioAvailable && settings.wantsAudio ? .on : .off
    audioCheckbox?.isEnabled = audioAvailable
    muteCheckbox?.state = muteAvailable && settings.wantsMute ? .on : .off
    muteCheckbox?.isEnabled = muteAvailable
    cropSegments?.selectedSegment = settings.cropMode.rawValue
    let insets = settings.appliedInsets()
    topSlider?.doubleValue = insets.top
    bottomSlider?.doubleValue = insets.bottom
    leftSlider?.doubleValue = insets.left
    rightSlider?.doubleValue = insets.right
    updateCropLabels(insets)
    hintLabel?.stringValue = hintText()
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
    renderer.setPixelSize(width: pixels.width, height: pixels.height, scale: screen.backingScaleFactor, lock: true)
    Immersive3DController.shared.repinExternalWindow(outputWindow, on: screen)
  }

  private func fitRendererToWindow() {
    guard let outputWindow, !onGlasses else { return }
    let scale = max(outputWindow.backingScaleFactor, 1)
    outputWindow.layoutIfNeeded()
    var size = renderer.bounds.size
    if size.width < 32 || size.height < 32 {
      outputWindow.setContentSize(NSSize(width: 960, height: 540))
      outputWindow.layoutIfNeeded()
      size = renderer.bounds.size
    }
    if size.width < 32 || size.height < 32 {
      size = NSSize(width: 960, height: 540)
    }
    renderer.setPixelSize(
      width: Int((size.width * scale).rounded()),
      height: Int((size.height * scale).rounded()),
      scale: scale,
      lock: false
    )
  }

  private func refreshOutputPixels() {
    if refreshingPixels { return }
    refreshingPixels = true
    defer { refreshingPixels = false }
    if onGlasses, let screen = outputWindow?.screen {
      applyGlassesScreen(screen, fullSizeEyes: Immersive3DController.isFullWidthSBS(screen))
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
      onGlasses = false
      renderer.setFullSizeEyes(false)
      Immersive3DController.shared.returnWindowFromGlasses(sender, previewFrame: previewFrame)
      fitRendererToWindow()
      syncMenu()
      return false
    }
    Task { [weak self] in
      await self?.manager.stop()
      DispatchQueue.main.async { self?.syncMenu() }
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
