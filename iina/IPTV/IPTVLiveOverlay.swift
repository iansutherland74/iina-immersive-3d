//
//  IPTVLiveOverlay.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  TiviMate-style overlay for a live channel. It sits on the player window,
//  including the Play on Glasses window. Side-by-side 3D draws the same
//  overlay into each eye half. A flat picture gets one overlay.

import Cocoa

final class IPTVLiveSession {
  let source: IPTVSource
  var item: IPTVItem
  var channels: [IPTVItem]
  var guide: IPTVEPG
  var catchup: IPTVProgramme?
  var previousItemID: String?

  init(source: IPTVSource, item: IPTVItem, channels: [IPTVItem], guide: IPTVEPG, catchup: IPTVProgramme?) {
    self.source = source
    self.item = item
    self.channels = channels
    self.guide = guide
    self.catchup = catchup
  }

  func number(of item: IPTVItem) -> Int {
    (channels.firstIndex { $0.id == item.id } ?? 0) + 1
  }

  func groupChannels() -> [IPTVItem] {
    let group = item.group
    let matched = channels.filter { $0.group == group }
    return matched.isEmpty ? channels : matched
  }
}

/// Keyboard-driven live TV chrome. Playback keeps running underneath.
final class IPTVLiveOverlayController {
  static let shared = IPTVLiveOverlayController()

  enum Mode {
    case hidden
    case banner
    case list
    case guide
  }

  private(set) var session: IPTVLiveSession?
  private(set) var mode: Mode = .hidden
  private(set) var digits = ""
  private(set) var notice: String?
  private(set) var listTop = 0
  private(set) var guideTop = 0
  private(set) var guideRow = 0
  private(set) var guideAnchor = Date()
  private(set) var guideFocus = Date()
  private(set) var listIndex = 0
  /// Group shown in the channel list. Nil follows the channel that is playing.
  private var browsingGroup: String?

  private let host = IPTVLiveOverlayHost()
  private var keyMonitor: Any?
  private var hideTimer: Timer?
  private var digitTimer: Timer?
  private var clock: Timer?
  private var playGeneration = 0
  private var acceptedGeneration = 0
  private var lastPlayRequest = Date.distantPast
  private var scrollAccum: CGFloat = 0
  private var lastPreciseZap = Date.distantPast
  private var logoRequests = Set<String>()

  private init() {}

  static var duplicatesEyes: Bool {
    guard Immersive3DController.shared.glassesActive else { return false }
    let snap = Immersive3DController.shared.currentSnapshot()
    // Flat 2D on the glasses stays one overlay. Side-by-side (converted or already SBS) is drawn twice.
    return snap.shouldProcess || snap.passThroughSBS
  }

  func begin(source: IPTVSource, item: IPTVItem, channels: [IPTVItem], guide: IPTVEPG, catchup: IPTVProgramme?) {
    let previous: String?
    if let session, session.source.id == source.id, session.item.id != item.id {
      previous = session.item.id
    } else if let session, session.source.id == source.id {
      previous = session.previousItemID
    } else {
      previous = nil
    }
    var list = channels.filter { $0.kind == .live }
    if list.isEmpty { list = [item] }
    if !list.contains(where: { $0.id == item.id }) { list.append(item) }
    let next = IPTVLiveSession(source: source, item: item, channels: list, guide: guide, catchup: catchup)
    next.previousItemID = previous
    session = next
    lastPlayRequest = Date()
    playGeneration += 1
    digits = ""
    notice = nil
    browsingGroup = nil
    listIndex = 0
    installKeyMonitor()
    IPTVBrowseOverlayController.shared.noteLiveSession()
    show(.banner)
  }

  func replaceGuide(_ guide: IPTVEPG, sourceID: UUID) {
    guard session?.source.id == sourceID else { return }
    session?.guide = guide
    redraw()
  }

  /// True only while this overlay's live channel is the file that is playing.
  func holdsLiveCaption(path: String) -> Bool {
    guard let session else { return false }
    if session.catchup != nil { return false }
    guard session.item.kind == .live else { return false }
    guard !path.isEmpty else { return false }
    return session.matches(path)
  }

  func end() {
    removeKeyMonitor()
    session = nil
    mode = .hidden
    digits = ""
    notice = nil
    browsingGroup = nil
    listIndex = 0
    hideTimer?.invalidate()
    digitTimer?.invalidate()
    clock?.invalidate()
    clock = nil
    host.removeFromSuperview()
  }

  /// The first file start after `begin` or a channel change belongs to this session.
  /// A later file we did not request clears it.
  func noteFileStarted(path: String) {
    guard let session else { return }
    // HLS can emit more than one start-file. The first events after a tune stay with this channel.
    if playGeneration != acceptedGeneration || Date().timeIntervalSince(lastPlayRequest) < 3 {
      acceptedGeneration = playGeneration
      return
    }
    if session.matches(path) { return }
    end()
  }

  func attachIfNeeded() {
    guard session != nil else {
      host.removeFromSuperview()
      return
    }
    guard !PlayerCore.playerCores.isEmpty, let main = PlayerCore.active.mainWindow else { return }
    guard main.loaded, let container = main.videoViewContainer else { return }
    if host.superview !== container {
      host.removeFromSuperview()
      host.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(host)
      NSLayoutConstraint.activate([
        host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        host.topAnchor.constraint(equalTo: container.topAnchor),
        host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
      ])
    }
    let anchor = main.videoView.superview === container ? main.videoView : nil
    container.addSubview(host, positioned: .above, relativeTo: anchor)
    IPTVBrowseOverlayController.shared.bringToFront()
    GlassesEyeControls.shared.bringToFront()
    host.needsLayout = true
    ensureClock()
    redraw()
  }

  // MARK: - Input

  func handleKeyDown(_ event: NSEvent) -> Bool {
    if IPTVBrowseOverlayController.shared.capturesInput { return false }
    guard session != nil else { return false }
    if !PlayerCore.playerCores.isEmpty, PlayerCore.active.mainWindow.window?.firstResponder is NSTextView {
      return false
    }
    if !event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
      return false
    }
    let raw = event.characters ?? ""
    let plain = event.charactersIgnoringModifiers ?? ""
    let code = event.keyCode

    if code == 53 || plain == "\u{1b}" {
      if !digits.isEmpty {
        digits = ""
        digitTimer?.invalidate()
        redraw()
        return true
      }
      if mode != .hidden {
        hide()
        return true
      }
      return false
    }
    if code == 51 || code == 117 || plain == "\u{7f}" || plain == "\u{8}" {
      if !digits.isEmpty {
        digits.removeLast()
        armDigits()
        redraw()
      } else if mode == .list || mode == .guide {
        hide()
      } else {
        toggleLastChannel()
      }
      return true
    }
    if raw.count == 1, let scalar = raw.unicodeScalars.first, scalar.value < 128, CharacterSet.decimalDigits.contains(scalar) {
      digits.append(Character(scalar))
      if digits.count > 5 { digits = String(digits.suffix(5)) }
      armDigits()
      if mode == .hidden { show(.banner) } else { redraw() }
      return true
    }
    if code == 36 || code == 76 || plain == "\r" || plain == "\u{3}" {
      if !digits.isEmpty {
        commitDigits()
        return true
      }
      switch mode {
      case .list:
        activateListSelection()
      case .guide:
        activateGuide()
      case .hidden, .banner:
        showList()
      }
      return true
    }
    if plain.lowercased() == "g" {
      showGuide()
      return true
    }
    if code == 126 || plain == "\u{f700}" {
      if mode == .guide { moveGuide(rows: -1) }
      else if mode == .list { moveList(by: -1) }
      else { changeChannel(by: -1) }
      return true
    }
    if code == 125 || plain == "\u{f701}" {
      if mode == .guide { moveGuide(rows: 1) }
      else if mode == .list { moveList(by: 1) }
      else { changeChannel(by: 1) }
      return true
    }
    if code == 116 || plain == "\u{f72c}" {
      if mode == .guide { moveGuide(rows: -visibleGuideRows()) }
      else if mode == .list { moveList(by: -visibleListRows()) }
      else { changeChannel(by: -10) }
      return true
    }
    if code == 121 || plain == "\u{f72d}" {
      if mode == .guide { moveGuide(rows: visibleGuideRows()) }
      else if mode == .list { moveList(by: visibleListRows()) }
      else { changeChannel(by: 10) }
      return true
    }
    if code == 123 || plain == "\u{f702}" {
      if mode == .guide { moveGuide(programmes: -1); return true }
      if mode == .list { switchGroup(by: -1); return true }
      return false
    }
    if code == 124 || plain == "\u{f703}" {
      if mode == .guide { moveGuide(programmes: 1); return true }
      if mode == .list { switchGroup(by: 1); return true }
      return false
    }
    return false
  }

  /// One line per navigation key while a live session exists, including keys that
  /// were not consumed, so a glasses test can see where the event went.
  func logKey(_ event: NSEvent, source: String, consumed: Bool) {
    guard session != nil else { return }
    let code = event.keyCode
    let navigation = [36, 51, 53, 76, 116, 117, 121, 123, 124, 125, 126].contains(Int(code))
    guard navigation || mode == .list || mode == .guide else { return }
    let eventWindow = event.window
    let keyWindow = NSApp.keyWindow
    let message = "IPTV key route source=\(source) code=\(code) chars=\(event.charactersIgnoringModifiers ?? "") mode=\(mode) consumed=\(consumed) eventWindow=\(eventWindow.map { String(describing: type(of: $0)) } ?? "nil") eventIsKey=\(eventWindow?.isKeyWindow ?? false) keyWindow=\(keyWindow.map { String(describing: type(of: $0)) } ?? "nil") keyTitle=\(keyWindow?.title ?? "") glasses=\(Immersive3DController.shared.glassesActive) canBecomeKey=\((eventWindow as? MainWindow)?.canBecomeKey ?? (keyWindow as? MainWindow)?.canBecomeKey ?? false)"
    NSLog("%@", message)
    Logger.log(message, level: .warning)
  }

  /// Remote next/previous. Returns true when a live session consumed the key.
  func zapFromRemote(next: Bool) -> Bool {
    if IPTVBrowseOverlayController.shared.capturesInput { return false }
    guard session != nil else { return false }
    if mode == .list {
      moveList(by: next ? 1 : -1)
      return true
    }
    if mode == .guide {
      moveGuide(rows: next ? 1 : -1)
      return true
    }
    changeChannel(by: next ? 1 : -1)
    return true
  }

  func handleScroll(_ event: NSEvent) -> Bool {
    if IPTVBrowseOverlayController.shared.capturesInput { return false }
    guard session != nil else { return false }
    let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
    if horizontal && mode != .list && mode != .guide { return false }
    if event.momentumPhase.contains(.began) || event.momentumPhase.contains(.changed) {
      return mode == .list || mode == .guide
    }
    if mode == .list || mode == .guide {
      if horizontal {
        let step = event.scrollingDeltaX > 0 ? -1 : 1
        if mode == .list { switchGroup(by: step) } else { moveGuide(programmes: step) }
        return true
      }
      let delta = event.scrollingDeltaY
      guard abs(delta) > 0.4 else { return true }
      let step = delta > 0 ? -1 : 1
      if event.hasPreciseScrollingDeltas {
        scrollAccum += delta
        guard abs(scrollAccum) >= 36 else { return true }
        scrollAccum = 0
      }
      if mode == .list { moveList(by: step) } else { moveGuide(rows: step) }
      return true
    }
    let delta = event.scrollingDeltaY
    guard abs(delta) > 0.4 else { return false }
    let direction = delta > 0 ? -1 : 1
    if event.hasPreciseScrollingDeltas {
      let now = Date()
      guard now.timeIntervalSince(lastPreciseZap) > 0.28 else { return true }
      lastPreciseZap = now
    }
    changeChannel(by: direction)
    return true
  }

  func handleClick(in pane: IPTVLiveOverlayPane, event: NSEvent) {
    if IPTVBrowseOverlayController.shared.capturesInput { return }
    clearDigits()
    guard let session else { return }
    if event.clickCount >= 2 {
      guard !PlayerCore.playerCores.isEmpty else { return }
      PlayerCore.active.mainWindow.toggleWindowFullScreen()
      return
    }
    let point = pane.convert(event.locationInWindow, from: nil)
    let chrome = IPTVLiveChrome.layout(in: pane.bounds, mode: mode)
    if mode != .guide, chrome.channelsButton.contains(point) {
      if mode == .list { hide() } else { showList() }
      return
    }
    if mode != .guide, chrome.guideButton.contains(point) {
      showGuide()
      return
    }
    if mode == .list, let row = IPTVLiveChrome.listRow(at: point, in: chrome.list) {
      let rows = listedChannels()
      let index = listTop + row
      guard rows.indices.contains(index) else { return }
      listIndex = index
      play(rows[index], catchup: nil)
      return
    }
    if mode == .guide, let hit = guideHit(at: point, in: chrome.guide) {
      guideRow = hit.row
      guideFocus = hit.programme?.start.addingTimeInterval(1) ?? guideFocus
      revealGuideSelection()
      if let programme = hit.programme {
        activate(programme, on: hit.row)
      }
      redraw()
      return
    }
    if mode == .list || mode == .guide {
      hide()
    } else {
      showList()
    }
  }

  /// Pointer moved over one eye half. The pane's local point is already that half,
  /// so the same row lights up in both eyes.
  func handleHover(_ event: NSEvent) {
    if IPTVBrowseOverlayController.shared.capturesInput { return }
    guard session != nil, mode == .list || mode == .guide else { return }
    guard let pane = pane(containing: event) else { return }
    let point = pane.convert(event.locationInWindow, from: nil)
    let chrome = IPTVLiveChrome.layout(in: pane.bounds, mode: mode)
    if mode == .list, let row = IPTVLiveChrome.listRow(at: point, in: chrome.list) {
      let index = listTop + row
      guard listedChannels().indices.contains(index), index != listIndex else { return }
      listIndex = index
      armHide()
      redraw()
      return
    }
    if mode == .guide, let hit = guideHit(at: point, in: chrome.guide) {
      let previous = selectedProgramme()?.start
      let nextStart = hit.programme?.start
      guard guideRow != hit.row || previous != nextStart else { return }
      guideRow = hit.row
      if let programme = hit.programme {
        guideFocus = programme.start.addingTimeInterval(1)
      }
      revealGuideSelection()
      armHide()
      redraw()
    }
  }

  func listedChannels() -> [IPTVItem] {
    guard let session else { return [] }
    let group = browsingGroup ?? session.item.group
    let matched = session.channels.filter { $0.group == group }
    return matched.isEmpty ? session.channels : matched
  }

  func listedGroupTitle() -> String {
    let group = browsingGroup ?? session?.item.group ?? ""
    let name = group.isEmpty ? "Ungrouped" : group
    return listedGroups().count > 1 ? "\(name)   ← →" : name
  }

  private func listedGroups() -> [String] {
    guard let session else { return [] }
    var ordered: [String] = []
    var seen = Set<String>()
    for channel in session.channels where seen.insert(channel.group).inserted {
      ordered.append(channel.group)
    }
    return ordered
  }

  private func moveList(by delta: Int) {
    let rows = listedChannels()
    guard !rows.isEmpty else { return }
    let count = rows.count
    listIndex = ((listIndex + delta) % count + count) % count
    revealListSelection()
    armHide()
    redraw()
  }

  private func switchGroup(by delta: Int) {
    let groups = listedGroups()
    guard let session, groups.count > 1 else { return }
    let current = browsingGroup ?? session.item.group
    let index = groups.firstIndex(of: current) ?? 0
    let count = groups.count
    let next = ((index + delta) % count + count) % count
    browsingGroup = groups[next]
    let rows = listedChannels()
    listIndex = rows.firstIndex { $0.id == session.item.id } ?? 0
    listTop = 0
    revealListSelection()
    notice = groups[next].isEmpty ? "Ungrouped" : groups[next]
    armHide()
    redraw()
  }

  private func activateListSelection() {
    let rows = listedChannels()
    guard rows.indices.contains(listIndex) else { return }
    play(rows[listIndex], catchup: nil)
  }

  private func visibleListRows() -> Int {
    guard let pane = host.panes.first(where: { !$0.isHidden }) else { return 8 }
    let height = IPTVLiveChrome.layout(in: pane.bounds, mode: .list).list.height
    return max(1, Int((height - 50) / 54))
  }

  private func visibleGuideRows() -> Int {
    guard let pane = host.panes.first(where: { !$0.isHidden }) else { return 8 }
    let height = IPTVLiveChrome.layout(in: pane.bounds, mode: .guide).guide.height
    return max(1, Int((height - 46) / 46))
  }

  private func pane(containing event: NSEvent) -> IPTVLiveOverlayPane? {
    host.panes.first { pane in
      guard !pane.isHidden, pane.window != nil else { return false }
      let local = pane.convert(event.locationInWindow, from: nil)
      return pane.bounds.contains(local)
    }
  }

  private func claimKeyWindow() {
    guard !PlayerCore.playerCores.isEmpty, let main = PlayerCore.active.mainWindow else { return }
    guard let window = main.window else { return }
    if Immersive3DController.shared.glassesActive, let mainWindow = window as? MainWindow {
      mainWindow.forceKeyAndMain = true
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(window.contentView)
  }

  private func installKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.session != nil else { return event }
      // The movies and series overlay is in front. Let its monitor take the key.
      if IPTVBrowseOverlayController.shared.capturesInput { return event }
      let source: String
      if self.shouldRoute(event) {
        source = "monitor"
      } else if self.shouldRouteGlasses(event) {
        source = "monitor-glasses"
      } else {
        self.logKey(event, source: "monitor-pass", consumed: false)
        return event
      }
      let consumed = self.handleKeyDown(event)
      self.logKey(event, source: source, consumed: consumed)
      // Swallow the event when the overlay handled it so mpv bindings and the
      // player window do not see it a second time.
      return consumed ? nil : event
    }
  }

  private func removeKeyMonitor() {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
  }

  /// Overlay list or guide is open, so this key must not fall through to an mpv binding.
  private func shouldRoute(_ event: NSEvent) -> Bool {
    guard session != nil, mode == .list || mode == .guide else { return false }
    if !event.modifierFlags.intersection([.command, .option, .control]).isEmpty { return false }
    if event.window?.firstResponder is NSTextView { return false }
    if NSApp.keyWindow?.firstResponder is NSTextView { return false }
    guard !PlayerCore.playerCores.isEmpty, let main = PlayerCore.active.mainWindow else { return false }
    if event.window === main.window { return true }
    // The glasses window is borderless. If it is not key yet, the utility panel may
    // still be the key window. Route those keys while the overlay is open.
    return Immersive3DController.shared.glassesActive
  }

  /// Channel keys while Play on Glasses is up, even if the borderless window is not key
  /// and the utility panel received the event. List and guide use `shouldRoute` instead.
  private func shouldRouteGlasses(_ event: NSEvent) -> Bool {
    guard Immersive3DController.shared.glassesActive, session != nil else { return false }
    guard mode != .list, mode != .guide else { return false }
    if !event.modifierFlags.intersection([.command, .option, .control]).isEmpty { return false }
    if event.window?.firstResponder is NSTextView || NSApp.keyWindow?.firstResponder is NSTextView { return false }
    return Self.isNavigationKey(event)
  }

  private static func isNavigationKey(_ event: NSEvent) -> Bool {
    let code = Int(event.keyCode)
    if [36, 51, 53, 76, 116, 117, 121, 123, 124, 125, 126].contains(code) { return true }
    let plain = (event.charactersIgnoringModifiers ?? "").lowercased()
    if plain == "g" || plain == "\u{1b}" || plain == "\r" || plain == "\u{3}" { return true }
    if plain.count == 1, let scalar = plain.unicodeScalars.first, CharacterSet.decimalDigits.contains(scalar) {
      return true
    }
    return false
  }

  // MARK: - Tuning

  func changeChannel(by delta: Int) {
    clearDigits()
    guard let session else { return }
    let group = session.groupChannels()
    guard !group.isEmpty else { return }
    let current = group.firstIndex { $0.id == session.item.id } ?? 0
    let count = group.count
    let next = ((current + delta) % count + count) % count
    if group[next].id == session.item.id && session.catchup == nil {
      if mode == .hidden { show(.banner) } else { armHide(); redraw() }
      return
    }
    play(group[next], catchup: nil)
  }

  func toggleLastChannel() {
    clearDigits()
    guard let session, let previous = session.previousItemID,
          let item = session.channels.first(where: { $0.id == previous }) else {
      notice = "No previous channel"
      show(.banner)
      return
    }
    play(item, catchup: nil)
  }

  private func commitDigits() {
    digitTimer?.invalidate()
    let typed = digits
    digits = ""
    guard let number = Int(typed), number > 0 else {
      notice = "No channel \(typed)"
      show(.banner)
      return
    }
    guard let session, session.channels.indices.contains(number - 1) else {
      notice = "No channel \(number)"
      show(.banner)
      return
    }
    play(session.channels[number - 1], catchup: nil)
  }

  private func play(_ item: IPTVItem, catchup: IPTVProgramme?) {
    guard let session else { return }
    guard !PlayerCore.playerCores.isEmpty else { return }
    let url: URL?
    if let catchup {
      url = IPTVLibrary.shared.catchupURL(for: item, source: session.source, programme: catchup)
    } else {
      url = IPTVLibrary.shared.playbackURL(for: item, source: session.source)
    }
    guard let url else {
      notice = catchup == nil ? "No stream address for \(item.name)" : "No catch-up for \(item.name)"
      if mode == .hidden { show(.banner) } else { armHide(); redraw() }
      return
    }
    if item.id == session.item.id && catchup == nil && session.catchup == nil {
      notice = nil
      if mode == .hidden || mode == .banner { show(.banner) } else { armHide(); redraw() }
      return
    }
    if item.id != session.item.id {
      session.previousItemID = session.item.id
    }
    session.item = item
    session.catchup = catchup
    lastPlayRequest = Date()
    playGeneration += 1
    let title = catchup.map { "\(item.name) — \($0.title)" } ?? item.name
    IPTVLibrary.shared.registerPlayback(stream: url, source: session.source, item: item, title: title)
    PlayerCore.active.openURL(url)
    if mode == .guide || mode == .list {
      armHide()
      revealCurrent()
      redraw()
    } else {
      show(.banner)
    }
    attachIfNeeded()
  }

  func showChannelList() {
    guard session != nil else { return }
    showList()
  }

  func showProgrammeGuide() {
    guard session != nil else { return }
    showGuide()
  }

  private func showList() {
    clearDigits()
    revealCurrent()
    show(.list)
  }

  private func showGuide() {
    clearDigits()
    guard let session else { return }
    let index = session.channels.firstIndex { $0.id == session.item.id } ?? 0
    guideRow = index
    guideFocus = Date()
    guideAnchor = Date().addingTimeInterval(-20 * 60)
    revealGuideSelection()
    show(.guide)
  }

  private func activateGuide() {
    guard let programme = selectedProgramme() else { return }
    activate(programme, on: guideRow)
  }

  private func activate(_ programme: IPTVProgramme, on row: Int) {
    guard let session, session.channels.indices.contains(row) else { return }
    let item = session.channels[row]
    let now = Date()
    if programme.start <= now && programme.stop > now {
      play(item, catchup: nil)
      return
    }
    if IPTVCatchup.canPlayFromStart(item, programme, now: now) {
      play(item, catchup: programme)
      return
    }
    if programme.start > now {
      notice = "\(programme.title) has not started"
    } else {
      notice = "No catch-up for \(programme.title)"
    }
    armHide()
    redraw()
  }

  private func moveGuide(rows: Int) {
    guard let session, !session.channels.isEmpty else { return }
    guideRow = min(max(0, guideRow + rows), session.channels.count - 1)
    revealGuideSelection()
    armHide()
    redraw()
  }

  private func moveGuide(programmes delta: Int) {
    guard let session, session.channels.indices.contains(guideRow) else { return }
    let item = session.channels[guideRow]
    let list = session.guide.programmes(for: item)
    guard !list.isEmpty else { return }
    let current = selectedProgramme() ?? list[0]
    if delta < 0 {
      if let previous = list.last(where: { $0.start < current.start }) {
        guideFocus = previous.start.addingTimeInterval(1)
      }
    } else if let next = list.first(where: { $0.start > current.start }) {
      guideFocus = next.start.addingTimeInterval(1)
    }
    revealGuideSelection()
    armHide()
    redraw()
  }

  func selectedProgramme() -> IPTVProgramme? {
    guard let session, session.channels.indices.contains(guideRow) else { return nil }
    let list = session.guide.programmes(for: session.channels[guideRow])
    if let hit = list.first(where: { $0.start <= guideFocus && $0.stop > guideFocus }) { return hit }
    return list.first { $0.start > guideFocus } ?? list.last
  }

  private func revealCurrent() {
    guard let session else { return }
    browsingGroup = nil
    let rows = listedChannels()
    listIndex = rows.firstIndex { $0.id == session.item.id } ?? 0
    revealListSelection()
  }

  private func revealListSelection() {
    let page = visibleListRows()
    if listIndex < listTop { listTop = listIndex }
    if listIndex >= listTop + page { listTop = max(0, listIndex - page + 1) }
  }

  private func revealGuideSelection() {
    guard session != nil else { return }
    let page = visibleGuideRows()
    if guideRow < guideTop { guideTop = guideRow }
    if guideRow >= guideTop + page { guideTop = max(0, guideRow - page + 1) }
    if let programme = selectedProgramme() {
      let visible = 90 * 60.0
      if programme.start < guideAnchor {
        guideAnchor = programme.start.addingTimeInterval(-8 * 60)
      } else if programme.start.timeIntervalSince(guideAnchor) > visible {
        guideAnchor = programme.start.addingTimeInterval(-30 * 60)
      }
    }
  }

  private func guideHit(at point: NSPoint, in grid: NSRect) -> (row: Int, programme: IPTVProgramme?)? {
    guard let session, grid.contains(point) else { return nil }
    let header: CGFloat = 28
    let rowHeight: CGFloat = 46
    let channelWidth: CGFloat = 188
    guard point.y >= grid.minY + header else { return nil }
    let row = guideTop + Int((point.y - grid.minY - header) / rowHeight)
    guard session.channels.indices.contains(row) else { return nil }
    guard point.x >= grid.minX + channelWidth else {
      return (row, selectedProgrammeOnRow(row))
    }
    let hourWidth: CGFloat = 220
    let instant = guideAnchor.addingTimeInterval(TimeInterval((point.x - grid.minX - channelWidth) / hourWidth) * 3600)
    let list = session.guide.programmes(for: session.channels[row])
    let programme = list.first { $0.start <= instant && $0.stop > instant }
    return (row, programme)
  }

  private func selectedProgrammeOnRow(_ row: Int) -> IPTVProgramme? {
    guard let session, session.channels.indices.contains(row) else { return nil }
    let list = session.guide.programmes(for: session.channels[row])
    return list.first { $0.start <= guideFocus && $0.stop > guideFocus }
  }

  // MARK: - Visibility

  private func show(_ next: Mode) {
    mode = next
    if next == .list || next == .guide {
      claimKeyWindow()
    }
    armHide()
    attachIfNeeded()
    redraw()
  }

  private func hide() {
    mode = .hidden
    notice = nil
    hideTimer?.invalidate()
    redraw()
  }

  private func armHide() {
    hideTimer?.invalidate()
    guard digits.isEmpty else { return }
    let delay: TimeInterval
    switch mode {
    case .hidden: return
    case .banner: delay = 6
    case .list: delay = 9
    case .guide: delay = 12
    }
    hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      self?.hide()
    }
  }

  private func clearDigits() {
    digits = ""
    digitTimer?.invalidate()
  }

  private func armDigits() {
    digitTimer?.invalidate()
    hideTimer?.invalidate()
    digitTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
      self?.commitDigits()
    }
  }

  private func ensureClock() {
    guard clock == nil else { return }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      self?.tick()
    }
    RunLoop.main.add(timer, forMode: .common)
    clock = timer
  }

  private func tick() {
    guard session != nil else {
      clock?.invalidate()
      clock = nil
      return
    }
    if mode != .hidden || !digits.isEmpty {
      host.needsLayout = true
      redraw()
    }
  }

  func redraw() {
    host.needsLayout = true
    host.needsDisplay = true
    for pane in host.panes {
      pane.needsDisplay = true
    }
  }

  func logo(for item: IPTVItem) -> NSImage? {
    guard let raw = item.logoURL, let url = URL(string: raw) else { return nil }
    if let image = IPTVImageLoader.shared.cachedImage(for: url) { return image }
    if logoRequests.insert(url.absoluteString).inserted {
      IPTVImageLoader.shared.load(url) { [weak self] _ in
        self?.redraw()
      }
    }
    return nil
  }

  func progress(for programme: IPTVProgramme, catchup: Bool) -> CGFloat {
    let length = programme.stop.timeIntervalSince(programme.start)
    guard length > 1 else { return 0 }
    if catchup, !PlayerCore.playerCores.isEmpty, let position = PlayerCore.active.info.videoPosition?.second, position.isFinite {
      return CGFloat(min(1, max(0, position / length)))
    }
    let now = Date()
    return CGFloat(min(1, max(0, now.timeIntervalSince(programme.start) / length)))
  }
}

private extension IPTVLiveSession {
  func matches(_ path: String) -> Bool {
    if let streamID = item.streamID, !streamID.isEmpty, path.contains(streamID) { return true }
    if let absolute = item.absoluteURL, let url = URL(string: absolute) {
      if path.contains(url.path) && !url.path.isEmpty && url.path != "/" { return true }
    }
    if path.contains(item.id) { return true }
    return false
  }
}

struct IPTVLiveChrome {
  var banner = NSRect.zero
  var channelsButton = NSRect.zero
  var guideButton = NSRect.zero
  var list = NSRect.zero
  var guide = NSRect.zero

  static func layout(in bounds: NSRect, mode: IPTVLiveOverlayController.Mode) -> IPTVLiveChrome {
    var chrome = IPTVLiveChrome()
    let inset: CGFloat = 18
    // The per-eye control bar sits on the bottom of each half while the pointer is showing it.
    let reserve: CGFloat = GlassesEyeControls.shared.shown ? 80 : 0
    let bannerHeight: CGFloat = min(132, max(96, bounds.height * 0.22))
    chrome.banner = NSRect(x: inset, y: bounds.height - bannerHeight - inset - reserve, width: max(0, bounds.width - inset * 2), height: bannerHeight)
    let buttonWidth: CGFloat = 92
    let buttonHeight: CGFloat = 26
    chrome.guideButton = NSRect(x: chrome.banner.maxX - buttonWidth - 14, y: chrome.banner.minY + 12, width: buttonWidth, height: buttonHeight)
    chrome.channelsButton = NSRect(x: chrome.guideButton.minX - buttonWidth - 8, y: chrome.guideButton.minY, width: buttonWidth, height: buttonHeight)
    if mode == .list {
      let width = min(440, max(240, bounds.width * 0.46))
      chrome.list = NSRect(x: inset, y: inset, width: width, height: max(0, chrome.banner.minY - inset * 2))
    }
    if mode == .guide {
      chrome.guide = NSRect(x: inset, y: inset, width: max(0, bounds.width - inset * 2), height: max(0, bounds.height - inset * 2 - reserve))
      chrome.banner = .zero
      chrome.channelsButton = .zero
      chrome.guideButton = .zero
    }
    return chrome
  }

  static func listRow(at point: NSPoint, in list: NSRect) -> Int? {
    guard list.contains(point) else { return nil }
    let header: CGFloat = 32
    let rowHeight: CGFloat = 54
    guard point.y >= list.minY + header else { return nil }
    return Int((point.y - list.minY - header) / rowHeight)
  }
}

final class IPTVLiveOverlayHost: NSView {
  let panes = [IPTVLiveOverlayPane(), IPTVLiveOverlayPane()]

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    for pane in panes {
      pane.translatesAutoresizingMaskIntoConstraints = true
      pane.autoresizingMask = []
      addSubview(pane)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    let duplicate = IPTVLiveOverlayController.duplicatesEyes && bounds.width >= 640
    let slots = duplicate ? 2 : 1
    let width = bounds.width / CGFloat(slots)
    for (index, pane) in panes.enumerated() {
      let shown = index < slots && width >= 32 && bounds.height >= 32
      pane.isHidden = !shown
      if shown {
        pane.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
      }
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard IPTVLiveOverlayController.shared.session != nil else { return nil }
    return super.hitTest(point)
  }
}

final class IPTVLiveOverlayPane: NSView {
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach { removeTrackingArea($0) }
    addTrackingArea(NSTrackingArea(
      rect: bounds,
      options: [.mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
      owner: self,
      userInfo: nil
    ))
  }

  override func mouseMoved(with event: NSEvent) {
    IPTVLiveOverlayController.shared.handleHover(event)
  }

  override func mouseDown(with event: NSEvent) {
    IPTVLiveOverlayController.shared.handleClick(in: self, event: event)
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.setFill()
    dirtyRect.fill()
    let controller = IPTVLiveOverlayController.shared
    guard let session = controller.session else { return }
    if controller.mode == .hidden && controller.digits.isEmpty {
      drawSyncChip(in: bounds)
      return
    }
    let chrome = IPTVLiveChrome.layout(in: bounds, mode: controller.mode)
    if controller.mode == .list { drawList(session, in: chrome.list, controller: controller) }
    if controller.mode == .guide {
      drawGuide(session, in: chrome.guide, controller: controller)
      drawSyncChip(in: bounds)
    }
    if controller.mode != .guide { drawBanner(session, chrome: chrome, controller: controller) }
    if !controller.digits.isEmpty { drawDigits(controller.digits) }
  }

  private func drawSyncChip(in bounds: NSRect) {
    guard let sync = LiveCaptionController.shared.transientBannerText else { return }
    let height: CGFloat = 28
    let width = min(420, max(220, bounds.width * 0.34))
    let y: CGFloat = 18
    let rect = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: height)
    IPTVLiveDraw.panel(rect, radius: 8)
    IPTVLiveDraw.text(sync, in: rect.insetBy(dx: 10, dy: 4), font: .systemFont(ofSize: 13, weight: .semibold), color: .white, align: .center)
  }

  private func drawBanner(_ session: IPTVLiveSession, chrome: IPTVLiveChrome, controller: IPTVLiveOverlayController) {
    let rect = chrome.banner
    guard rect.width > 40, rect.height > 40 else { return }
    IPTVLiveDraw.panel(rect, radius: 14)
    let logoRect = NSRect(x: rect.minX + 14, y: rect.minY + 14, width: rect.height - 28, height: rect.height - 28)
    IPTVLiveDraw.logo(controller.logo(for: session.item), in: logoRect, title: session.item.name)
    let textX = logoRect.maxX + 12
    let textWidth = max(40, chrome.channelsButton.minX - textX - 8)
    let number = session.number(of: session.item)
    let now = Date()
    let pair = session.guide.nowAndNext(for: session.item, at: now)
    let title = "\(number)   \(session.item.name)"
    IPTVLiveDraw.text(title, in: NSRect(x: textX, y: rect.minY + 12, width: textWidth, height: 26), font: .systemFont(ofSize: 18, weight: .semibold), color: .white)
    let programme: IPTVProgramme?
    let secondary: String
    if let catchup = session.catchup {
      programme = catchup
      secondary = "Catch-up · \(IPTVLiveDraw.clock.string(from: catchup.start))–\(IPTVLiveDraw.clock.string(from: catchup.stop))"
    } else {
      programme = pair.now
      secondary = pair.next.map { "Next  \($0.title)" } ?? " "
    }
    let nowTitle = programme?.title ?? (controller.notice ?? "No programme information")
    IPTVLiveDraw.text(nowTitle, in: NSRect(x: textX, y: rect.minY + 40, width: textWidth, height: 20), font: .systemFont(ofSize: 14, weight: .medium), color: NSColor(calibratedWhite: 1, alpha: 0.92))
    if let programme {
      let bar = NSRect(x: textX, y: rect.minY + 64, width: textWidth, height: 6)
      IPTVLiveDraw.progress(controller.progress(for: programme, catchup: session.catchup != nil), in: bar)
    }
    IPTVLiveDraw.text(secondary, in: NSRect(x: textX, y: rect.minY + 76, width: textWidth, height: 18), font: .systemFont(ofSize: 12, weight: .regular), color: NSColor(calibratedWhite: 1, alpha: 0.72))
    if rect.height > 108, let sync = LiveCaptionController.shared.transientBannerText {
      IPTVLiveDraw.text(sync, in: NSRect(x: textX, y: rect.maxY - 22, width: textWidth, height: 16), font: .systemFont(ofSize: 12, weight: .semibold), color: NSColor(calibratedRed: 0.55, green: 0.88, blue: 1, alpha: 1))
    } else if rect.height > 108 {
      let footer = controller.notice ?? "↑↓ channel    0–9    ⌫ last    ⏎ list    G guide"
      let footerColor = controller.notice == nil ? NSColor(calibratedWhite: 1, alpha: 0.55) : NSColor(calibratedRed: 1, green: 0.75, blue: 0.4, alpha: 1)
      IPTVLiveDraw.text(footer, in: NSRect(x: textX, y: rect.maxY - 26, width: max(40, rect.maxX - textX - 16), height: 16), font: .systemFont(ofSize: 11, weight: .medium), color: footerColor)
    }
    IPTVLiveDraw.button("Channels", in: chrome.channelsButton)
    IPTVLiveDraw.button("Guide", in: chrome.guideButton)
  }

  private func drawList(_ session: IPTVLiveSession, in rect: NSRect, controller: IPTVLiveOverlayController) {
    guard rect.width > 40, rect.height > 40 else { return }
    IPTVLiveDraw.panel(rect, radius: 14)
    IPTVLiveDraw.text(controller.listedGroupTitle(), in: NSRect(x: rect.minX + 14, y: rect.minY + 6, width: rect.width - 28, height: 22), font: .systemFont(ofSize: 13, weight: .semibold), color: NSColor(calibratedWhite: 1, alpha: 0.8))
    let rows = controller.listedChannels()
    let rowHeight: CGFloat = 54
    let header: CGFloat = 32
    var y = rect.minY + header
    var index = controller.listTop
    let now = Date()
    while index < rows.count && y + rowHeight <= rect.maxY - 18 {
      let item = rows[index]
      let row = NSRect(x: rect.minX + 8, y: y, width: rect.width - 16, height: rowHeight - 4)
      if index == controller.listIndex {
        IPTVLiveDraw.fill(row, radius: 8, color: NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.90, alpha: 0.92))
      } else if item.id == session.item.id {
        IPTVLiveDraw.fill(row, radius: 8, color: NSColor(calibratedWhite: 1, alpha: 0.14))
      }
      let logo = NSRect(x: row.minX + 6, y: row.minY + 6, width: 36, height: 36)
      IPTVLiveDraw.logo(controller.logo(for: item), in: logo, title: item.name)
      let pair = session.guide.nowAndNext(for: item, at: now)
      let name = "\(session.number(of: item))  \(item.name)"
      IPTVLiveDraw.text(name, in: NSRect(x: logo.maxX + 8, y: row.minY + 4, width: row.width - 58, height: 18), font: .systemFont(ofSize: 13, weight: .semibold), color: .white)
      IPTVLiveDraw.text(pair.now?.title ?? " ", in: NSRect(x: logo.maxX + 8, y: row.minY + 22, width: row.width - 58, height: 14), font: .systemFont(ofSize: 11, weight: .regular), color: NSColor(calibratedWhite: 1, alpha: 0.85))
      IPTVLiveDraw.text(pair.next.map { "Next  \($0.title)" } ?? " ", in: NSRect(x: logo.maxX + 8, y: row.minY + 36, width: row.width - 58, height: 12), font: .systemFont(ofSize: 10, weight: .regular), color: NSColor(calibratedWhite: 1, alpha: 0.6))
      y += rowHeight
      index += 1
    }
    let hint = controller.notice ?? "↑↓ select    ←→ group    ⏎ play    Esc close"
    IPTVLiveDraw.text(hint, in: NSRect(x: rect.minX + 12, y: rect.maxY - 18, width: rect.width - 24, height: 14), font: .systemFont(ofSize: 10, weight: .medium), color: NSColor(calibratedWhite: 1, alpha: 0.7))
  }

  private func drawGuide(_ session: IPTVLiveSession, in rect: NSRect, controller: IPTVLiveOverlayController) {
    guard rect.width > 80, rect.height > 80 else { return }
    IPTVLiveDraw.panel(rect, radius: 14)
    let header: CGFloat = 28
    let rowHeight: CGFloat = 46
    let channelWidth: CGFloat = 188
    let hourWidth: CGFloat = 220
    IPTVLiveDraw.text("Guide", in: NSRect(x: rect.minX + 12, y: rect.minY + 4, width: channelWidth - 16, height: 20), font: .systemFont(ofSize: 12, weight: .semibold), color: NSColor(calibratedWhite: 1, alpha: 0.8))
    let gridLeft = rect.minX + channelWidth
    let hours = max(1, Int((rect.width - channelWidth) / hourWidth) + 1)
    for hour in 0..<hours {
      let instant = controller.guideAnchor.addingTimeInterval(TimeInterval(hour) * 3600)
      let x = gridLeft + CGFloat(hour) * hourWidth
      guard x < rect.maxX else { break }
      IPTVLiveDraw.text(IPTVLiveDraw.clock.string(from: instant), in: NSRect(x: x + 4, y: rect.minY + 4, width: hourWidth - 8, height: 20), font: .systemFont(ofSize: 11, weight: .medium), color: NSColor(calibratedWhite: 1, alpha: 0.7))
    }
    let now = Date()
    var y = rect.minY + header
    var index = controller.guideTop
    let selected = controller.selectedProgramme()
    while index < session.channels.count && y + rowHeight <= rect.maxY - 18 {
      let item = session.channels[index]
      let row = NSRect(x: rect.minX + 6, y: y, width: rect.width - 12, height: rowHeight - 4)
      if index == controller.guideRow {
        IPTVLiveDraw.fill(row, radius: 6, color: NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.90, alpha: 0.28))
      }
      IPTVLiveDraw.text("\(session.number(of: item))  \(item.name)", in: NSRect(x: rect.minX + 10, y: y + 12, width: channelWidth - 18, height: 18), font: .systemFont(ofSize: 12, weight: .semibold), color: .white)
      let programmes = session.guide.programmes(for: item)
      let windowEnd = controller.guideAnchor.addingTimeInterval(TimeInterval((rect.width - channelWidth) / hourWidth) * 3600)
      for programme in programmes where programme.stop > controller.guideAnchor && programme.start < windowEnd {
        let start = max(programme.start, controller.guideAnchor)
        let stop = min(programme.stop, windowEnd)
        let x = gridLeft + CGFloat(start.timeIntervalSince(controller.guideAnchor) / 3600) * hourWidth
        let w = max(4, CGFloat(stop.timeIntervalSince(start) / 3600) * hourWidth - 3)
        let blockWidth = min(w, rect.maxX - x - 6)
        guard blockWidth > 2 else { continue }
        let block = NSRect(x: x, y: y + 6, width: blockWidth, height: rowHeight - 16)
        let onAir = programme.start <= now && programme.stop > now
        let past = programme.stop <= now
        let color: NSColor
        if onAir {
          color = NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.90, alpha: 0.85)
        } else if past && IPTVCatchup.canPlayFromStart(item, programme, now: now) {
          color = NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.32, alpha: 0.8)
        } else if past {
          color = NSColor(calibratedWhite: 1, alpha: 0.12)
        } else {
          color = NSColor(calibratedWhite: 1, alpha: 0.2)
        }
        IPTVLiveDraw.fill(block, radius: 4, color: color)
        if index == controller.guideRow, let selected, selected.start == programme.start {
          NSColor.white.setStroke()
          let path = NSBezierPath(roundedRect: block.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
          path.lineWidth = 1.5
          path.stroke()
        }
        if block.width > 36 {
          IPTVLiveDraw.text(programme.title, in: block.insetBy(dx: 6, dy: 4), font: .systemFont(ofSize: 11, weight: .medium), color: .white)
        }
      }
      y += rowHeight
      index += 1
    }
    let hint = controller.notice ?? "↑↓ select · ←→ time · ⏎ play · Esc close · hover highlights"
    IPTVLiveDraw.text(hint, in: NSRect(x: rect.minX + 12, y: rect.maxY - 20, width: rect.width - 24, height: 16), font: .systemFont(ofSize: 11, weight: .regular), color: NSColor(calibratedWhite: 1, alpha: 0.75))
  }

  private func drawDigits(_ digits: String) {
    let width = min(bounds.width - 48, 280)
    let rect = NSRect(x: (bounds.width - width) / 2, y: bounds.height * 0.28, width: width, height: 84)
    IPTVLiveDraw.panel(rect, radius: 16)
    IPTVLiveDraw.text(digits, in: rect.insetBy(dx: 12, dy: 16), font: .monospacedDigitSystemFont(ofSize: 42, weight: .semibold), color: .white, align: .center)
  }
}

enum IPTVLiveDraw {
  static let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
  }()

  static func panel(_ rect: NSRect, radius: CGFloat) {
    fill(rect, radius: radius, color: NSColor(calibratedWhite: 0.04, alpha: 0.78))
    NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.lineWidth = 1
    path.stroke()
  }

  static func fill(_ rect: NSRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
  }

  static func button(_ title: String, in rect: NSRect) {
    guard rect.width > 8 else { return }
    fill(rect, radius: 6, color: NSColor(calibratedWhite: 1, alpha: 0.16))
    text(title, in: rect.insetBy(dx: 4, dy: 4), font: .systemFont(ofSize: 12, weight: .semibold), color: .white, align: .center)
  }

  static func progress(_ fraction: CGFloat, in rect: NSRect) {
    fill(rect, radius: 3, color: NSColor(calibratedWhite: 1, alpha: 0.22))
    let width = max(0, min(1, fraction)) * rect.width
    guard width > 0 else { return }
    fill(NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height), radius: 3, color: .white)
  }

  static func logo(_ image: NSImage?, in rect: NSRect, title: String) {
    fill(rect, radius: 6, color: NSColor(calibratedWhite: 1, alpha: 0.12))
    if let image {
      image.draw(in: rect.insetBy(dx: 2, dy: 2), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      return
    }
    let letter = String(title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    text(letter.isEmpty ? "?" : letter, in: rect, font: .systemFont(ofSize: 14, weight: .bold), color: .white, align: .center)
  }

  static func text(_ string: String, in rect: NSRect, font: NSFont, color: NSColor, align: NSTextAlignment = .left, wrap: Bool = false) {
    guard rect.width > 2, rect.height > 2 else { return }
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
    style.alignment = align
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: style
    ]
    (string as NSString).draw(in: rect, withAttributes: attributes)
  }
}
