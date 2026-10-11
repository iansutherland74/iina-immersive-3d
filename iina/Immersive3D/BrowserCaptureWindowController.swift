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
  private var outputWindow: NSWindow?
  private var previewFrame = NSRect(x: 0, y: 0, width: 960, height: 540)
  private var onGlasses = false
  private var rows: [BrowserCaptureTarget] = []
  private var selectedID: CGWindowID?
  private var table: NSTableView?
  private var statusLabel: NSTextField?
  private var outputMessage: NSTextField?
  private var chooseItem: NSMenuItem?
  private var toggleItem: NSMenuItem?
  private var glassesItem: NSMenuItem?

  override init(window: NSWindow?) {
    let chooser = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    chooser.title = "Choose Capture Window"
    super.init(window: chooser)
    buildChooser()
    manager.onFrame = { [weak self] buffer in
      self?.renderer.consume(buffer)
    }
    manager.onStatus = { [weak self] text in
      self?.showOutputMessage(text)
      self?.setStatus(text ?? "")
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
    return [choose, toggle, glasses]
  }

  func syncMenu() {
    toggleItem?.title = manager.isRunning ? "Stop Capture" : "Start Capture"
    glassesItem?.title = onGlasses ? "Stop Sending Capture to Glasses" : "Send Capture to Glasses"
    glassesItem?.isEnabled = manager.isRunning || onGlasses
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
          self?.setStatus("Capture stopped. Audio stayed in the other app.")
        }
      }
      return
    }
    guard let selectedID else {
      showChooser(sender)
      setStatus("Choose a window, then start capture.")
      return
    }
    beginCapture(selectedID)
  }

  @objc func toggleGlasses(_ sender: Any?) {
    guard let output = ensureOutput() else { return }
    if onGlasses {
      Immersive3DController.shared.returnWindowFromGlasses(output, previewFrame: previewFrame)
      onGlasses = false
      renderer.setFullSizeEyes(false)
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
    selectedID = rows[table.selectedRow].id
  }

  private func buildChooser() {
    guard let content = window?.contentView else { return }
    let scroll = NSScrollView(frame: NSRect(x: 20, y: 88, width: 480, height: 280))
    let table = NSTableView(frame: scroll.bounds)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
    column.title = "Window"
    column.width = 460
    table.addTableColumn(column)
    table.headerView = nil
    table.dataSource = self
    table.delegate = self
    table.rowHeight = 22
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    self.table = table
    let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked(_:)))
    refresh.bezelStyle = .rounded
    refresh.frame = NSRect(x: 20, y: 48, width: 100, height: 28)
    let use = NSButton(title: "Use This Window", target: self, action: #selector(useClicked(_:)))
    use.bezelStyle = .rounded
    use.frame = NSRect(x: 360, y: 48, width: 140, height: 28)
    let status = NSTextField(wrappingLabelWithString: "Audio stays in the browser. Protected video stays black.")
    status.font = .systemFont(ofSize: 12)
    status.textColor = .secondaryLabelColor
    status.frame = NSRect(x: 20, y: 8, width: 480, height: 36)
    statusLabel = status
    content.addSubview(scroll)
    content.addSubview(refresh)
    content.addSubview(use)
    content.addSubview(status)
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
    selectedID = target.id
    beginCapture(target.id)
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
          self?.setStatus(found.isEmpty ? "No other windows are on screen." : "\(found.count) windows. IINA's own output is left out.")
        }
      } catch {
        DispatchQueue.main.async {
          self?.setStatus(error.localizedDescription)
        }
      }
    }
  }

  private func beginCapture(_ id: CGWindowID) {
    guard ensurePermission() else { return }
    let excluded = excludedWindowIDs()
    guard ensureOutput() != nil else { return }
    setStatus("Starting capture…")
    Task { [weak self] in
      do {
        try await self?.manager.start(windowID: id, excluding: excluded)
        DispatchQueue.main.async {
          self?.syncMenu()
          self?.setStatus("Capturing. Audio is still playing in the other app.")
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
    window.setFrame(previewFrame, display: false)
    fitRendererToWindow()
    window.orderFront(nil)
    outputWindow = window
    return window
  }

  private func applyGlassesScreen(_ screen: NSScreen, fullSizeEyes: Bool) {
    guard onGlasses, let outputWindow else { return }
    renderer.setFullSizeEyes(fullSizeEyes)
    let pixels = Immersive3DController.pixelSize(of: screen)
    renderer.setPixelSize(width: pixels.width, height: pixels.height, scale: screen.backingScaleFactor)
    Immersive3DController.shared.repinExternalWindow(outputWindow, on: screen)
  }

  private func fitRendererToWindow() {
    guard let outputWindow else { return }
    let scale = outputWindow.backingScaleFactor
    let size = outputWindow.contentView?.bounds.size ?? outputWindow.frame.size
    renderer.setPixelSize(width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()), scale: scale)
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
    statusLabel?.stringValue = text
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard sender == outputWindow else { return true }
    if onGlasses {
      Immersive3DController.shared.returnWindowFromGlasses(sender, previewFrame: previewFrame)
      onGlasses = false
      renderer.setFullSizeEyes(false)
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
