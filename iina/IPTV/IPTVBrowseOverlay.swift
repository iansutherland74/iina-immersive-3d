//
//  IPTVBrowseOverlay.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Movies, series, continue watching, favourites, and search on the same
//  full-screen overlay as live TV. Side-by-side glasses draw it into each eye.

import Cocoa

/// Library browser drawn on the player, including the glasses window.
final class IPTVBrowseOverlayController {
  static let shared = IPTVBrowseOverlayController()

  enum Screen: Equatable {
    case hidden
    case menu
    case grid
    case search
    case details
    case episodes
    case next
  }

  enum Section: Equatable {
    case live
    case movies
    case series
    case continueWatching
    case favourites
    case search
  }

  enum Zone: Equatable {
    case rail
    case body
  }

  enum Action {
    case play
    case resume
    case episodes
    case trailer
    case favourite
  }

  enum Hit {
    case none
    case outside
    case menu(Int)
    case rail(Int)
    case body(Int)
    case action(Int)
    case season(Int)
    case episode(Int)
    case nextPlay
    case nextCancel
  }

  struct WatchMark {
    var fraction: CGFloat
    var label: String?
  }

  private struct PlaybackContext {
    var source: IPTVSource
    var series: IPTVItem?
    var episodes: [IPTVEpisodeDetails]
    var itemID: String
  }

  private struct NextPrompt {
    var episode: IPTVEpisodeDetails
    var series: IPTVItem?
    var episodes: [IPTVEpisodeDetails]
  }

  static let menuTitles = ["Live TV", "Movies", "Series", "Continue watching", "Favourites", "Search"]

  private(set) var screen: Screen = .hidden
  private(set) var section: Section = .movies
  private(set) var zone: Zone = .rail
  private(set) var menuIndex = 0
  private(set) var railIndex = 0
  private(set) var railTop = 0
  private(set) var bodyIndex = 0
  private(set) var bodyTop = 0
  private(set) var actionIndex = 0
  private(set) var seasonIndex = 0
  private(set) var seasonTop = 0
  private(set) var episodeIndex = 0
  private(set) var episodeTop = 0
  private(set) var query = ""
  private(set) var status: String?
  private(set) var source: IPTVSource?
  private(set) var detailItem: IPTVItem?
  private(set) var details: IPTVTitleDetails?
  private(set) var nextSeconds = 10
  private(set) var nextAction = 0

  var capturesInput: Bool { screen != .hidden }

  private let host = IPTVBrowseOverlayHost()
  private var keyMonitor: Any?
  private var catalog: IPTVCatalog?
  private var catalogSourceID: UUID?
  private var lastSource: IPTVSource?
  private var playbackContext: PlaybackContext?
  private var prompted: NextPrompt?
  private var pendingEpisodeID: String?
  private var savedRail = 0
  private var savedBody = 0
  private var savedZone: Zone = .rail
  private var returnToSearch = false
  private var loadGeneration = 0
  private var nextGeneration = 0
  private var nextTimer: Timer?
  private var scrollAccum: CGFloat = 0
  private var imageRequests = Set<String>()

  private init() {}

  func noteLiveSession() {
    if let source = IPTVLiveOverlayController.shared.session?.source {
      lastSource = source
    }
    installMonitor()
  }

  func notePlaybackRegistered() {
    if let active = IPTVLibrary.shared.activePlayback(),
       let match = IPTVLibrary.shared.sources.first(where: { $0.id == active.sourceID }) {
      lastSource = match
    }
    installMonitor()
  }

  /// A file that is not this IPTV session should stop borrowing the M key.
  func noteForeignFile() {
    guard screen == .hidden else { return }
    guard IPTVLibrary.shared.activePlayback() == nil else { return }
    guard IPTVLiveOverlayController.shared.session == nil else { return }
    lastSource = nil
  }

  /// Called before watch progress is cleared. Natural end of an episode offers the next one.
  func noteFileEnded(position: Double?, duration: Double?, stopped: Bool) {
    nextGeneration += 1
    let generation = nextGeneration
    if stopped {
      if screen == .next { dismissToVideo() }
      return
    }
    guard let active = IPTVLibrary.shared.activePlayback() else { return }
    guard active.record.kind == IPTVItemKind.episode.rawValue else { return }
    let played: Double
    if let position, position.isFinite {
      played = position
    } else {
      played = active.record.position
    }
    let length: Double
    if let duration, duration.isFinite {
      length = duration
    } else {
      length = active.record.duration
    }
    if length > 30 {
      if played < length - 45 && played / length < 0.85 { return }
    } else if played < 5 {
      return
    }
    if let context = playbackContext,
       context.itemID == active.itemID || context.episodes.contains(where: { $0.item.id == active.itemID }),
       let next = nextEpisode(after: active.itemID, in: context.episodes) {
      source = context.source
      lastSource = context.source
      presentNext(next, series: context.series, episodes: context.episodes)
      return
    }
    guard let seriesID = active.record.seriesItemID else { return }
    let resolved = IPTVLibrary.shared.sources.first { $0.id == active.sourceID } ?? playbackContext?.source
    guard let resolved else { return }
    let found = (catalogSourceID == resolved.id ? catalog : nil) ?? IPTVLibrary.shared.cache(for: resolved)
    guard let series = found?.items.first(where: { $0.id == seriesID && $0.kind == .series }) else { return }
    IPTVLibrary.shared.loadTitleDetails(for: series, source: resolved) { [weak self] result in
      self?.onMain {
        guard let self, generation == self.nextGeneration else { return }
        guard case .success(let payload) = result else { return }
        guard let next = self.nextEpisode(after: active.itemID, in: payload.0.episodes) else { return }
        self.source = resolved
        self.lastSource = resolved
        self.playbackContext = PlaybackContext(source: resolved, series: series, episodes: payload.0.episodes, itemID: active.itemID)
        self.presentNext(next, series: series, episodes: payload.0.episodes)
      }
    }
  }

  func bringToFront() {
    guard host.superview != nil else { return }
    host.superview?.addSubview(host, positioned: .above, relativeTo: nil)
    GlassesEyeControls.shared.bringToFront()
  }

  func attachIfNeeded() {
    guard screen != .hidden else {
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
    bringToFront()
    host.needsLayout = true
    redraw()
  }

  // MARK: - Input

  func handleKeyDown(_ event: NSEvent) -> Bool {
    if currentFirstResponderIsText() { return false }
    if !event.modifierFlags.intersection([.command, .option, .control]).isEmpty { return false }
    let plain = event.charactersIgnoringModifiers ?? ""
    let code = event.keyCode
    if screen == .hidden {
      guard isMenuChord(code, plain), contextSource() != nil else { return false }
      showMenu()
      return true
    }
    if screen == .search, isTyping(plain) {
      query.append(plain)
      if query.count > 64 { query = String(query.prefix(64)) }
      bodyIndex = 0
      bodyTop = 0
      zone = .body
      redraw()
      return true
    }
    if code == 115 || (plain.count == 1 && plain.lowercased() == "m") {
      showMenu()
      return true
    }
    if code == 53 || plain == "\u{1b}" {
      goBack()
      return true
    }
    if code == 51 || code == 117 || plain == "\u{7f}" || plain == "\u{8}" {
      if screen == .search, !query.isEmpty {
        query.removeLast()
        bodyIndex = 0
        bodyTop = 0
        redraw()
        return true
      }
      goBack()
      return true
    }
    if code == 36 || code == 76 || plain == "\r" || plain == "\u{3}" {
      activate()
      return true
    }
    if code == 126 || plain == "\u{f700}" {
      moveVertical(-1)
      return true
    }
    if code == 125 || plain == "\u{f701}" {
      moveVertical(1)
      return true
    }
    if code == 116 || plain == "\u{f72c}" {
      moveVertical(pageStep(up: true))
      return true
    }
    if code == 121 || plain == "\u{f72d}" {
      moveVertical(pageStep(up: false))
      return true
    }
    if code == 123 || plain == "\u{f702}" {
      moveHorizontal(-1)
      return true
    }
    if code == 124 || plain == "\u{f703}" {
      moveHorizontal(1)
      return true
    }
    return true
  }

  func logKey(_ event: NSEvent, source: String, consumed: Bool) {
    guard consumed || screen != .hidden else { return }
    let eventWindow = event.window
    let keyWindow = NSApp.keyWindow
    let message = "IPTV key route source=\(source) code=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "") mode=browse-\(screen) consumed=\(consumed) eventWindow=\(eventWindow.map { String(describing: type(of: $0)) } ?? "nil") eventIsKey=\(eventWindow?.isKeyWindow ?? false) keyWindow=\(keyWindow.map { String(describing: type(of: $0)) } ?? "nil") keyTitle=\(keyWindow?.title ?? "") glasses=\(Immersive3DController.shared.glassesActive) canBecomeKey=\((eventWindow as? MainWindow)?.canBecomeKey ?? (keyWindow as? MainWindow)?.canBecomeKey ?? false)"
    NSLog("%@", message)
    Logger.log(message, level: .warning)
  }

  func moveFromRemote(next: Bool) -> Bool {
    guard screen != .hidden else { return false }
    moveVertical(next ? 1 : -1)
    return true
  }

  func handleScroll(_ event: NSEvent) -> Bool {
    guard screen != .hidden else { return false }
    if event.momentumPhase.contains(.began) || event.momentumPhase.contains(.changed) { return true }
    let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
    let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
    guard abs(delta) > 0.4 else { return true }
    var step = delta > 0 ? -1 : 1
    if event.hasPreciseScrollingDeltas {
      scrollAccum += delta
      guard abs(scrollAccum) >= 36 else { return true }
      step = scrollAccum > 0 ? -1 : 1
      scrollAccum = 0
    }
    if horizontal {
      moveHorizontal(step)
      return true
    }
    if let pane = pane(containing: event) {
      let point = pane.convert(event.locationInWindow, from: nil)
      let layout = makeLayout(pane.bounds)
      let onRail = layout.rail.contains(point) || layout.seasonRail.contains(point)
      if onRail {
        if screen == .episodes { moveSeason(step) } else { moveRail(step) }
        return true
      }
    }
    moveVertical(step)
    return true
  }

  func handleHover(_ event: NSEvent) {
    guard screen != .hidden, let pane = pane(containing: event) else { return }
    let point = pane.convert(event.locationInWindow, from: nil)
    applyHover(hitTest(point, layout: makeLayout(pane.bounds)))
  }

  func handleClick(in pane: IPTVBrowseOverlayPane, event: NSEvent) {
    guard event.clickCount == 1 else { return }
    let point = pane.convert(event.locationInWindow, from: nil)
    let hit = hitTest(point, layout: makeLayout(pane.bounds))
    switch hit {
    case .none:
      break
    case .outside:
      if screen == .menu || screen == .next { goBack() }
    case .menu(let index):
      menuIndex = index
      activateMenu()
    case .rail(let index):
      railIndex = index
      bodyIndex = 0
      bodyTop = 0
      zone = .body
      revealBody()
      redraw()
    case .body(let index):
      zone = .body
      bodyIndex = index
      activateBody()
    case .action(let index):
      actionIndex = index
      activateDetails()
    case .season(let index):
      seasonIndex = index
      episodeIndex = 0
      episodeTop = 0
      zone = .body
      revealEpisode()
      redraw()
    case .episode(let index):
      zone = .body
      episodeIndex = index
      playFocusedEpisode()
    case .nextPlay:
      nextAction = 0
      playPrompted()
    case .nextCancel:
      goBack()
    }
  }

  // MARK: - Model

  func usesPosters() -> Bool {
    section != .live
  }

  func headerTitle() -> String {
    switch section {
    case .live: return "Live TV"
    case .movies: return "Movies"
    case .series: return "Series"
    case .continueWatching: return "Continue watching"
    case .favourites: return "Favourites"
    case .search: return "Search"
    }
  }

  func headerDetail() -> String {
    if section == .search {
      return query.isEmpty ? "Type a title" : "\(bodyItems().count) matches"
    }
    let titles = railTitles()
    let name = titles.indices.contains(railIndex) ? titles[railIndex] : ""
    return "\(name)  ·  \(bodyItems().count)"
  }

  func hintText() -> String {
    if let status, !status.isEmpty { return status }
    switch screen {
    case .hidden:
      return ""
    case .menu:
      return "↑↓ choose    ⏎ open    Esc close"
    case .grid where section == .live:
      return "↑↓ channel    ←→ group    ⏎ play    Esc back"
    case .grid:
      return zone == .rail ? "↑↓ category    → titles    ⏎ enter    Esc back" : "↑↓←→ title    ← categories    ⏎ open    Esc back"
    case .search:
      return query.isEmpty ? "Type a title    Esc back" : "Type to search    ↑↓←→ move    ⌫ delete    Esc back"
    case .details:
      return "←→ action    ⏎ do    Esc back"
    case .episodes:
      return zone == .rail ? "↑↓ season    → episodes    Esc back" : "↑↓ episode    ← seasons    ⏎ play    Esc back"
    case .next:
      return "⏎ now    Esc cancel    playing in \(nextSeconds)s"
    }
  }

  func placeholder() -> String? {
    switch screen {
    case .grid, .search:
      if catalog == nil { return "Loading the catalog…" }
      if section == .search && query.isEmpty { return "Type a title" }
      if bodyItems().isEmpty { return section == .search ? "No matches" : "Nothing here" }
    case .episodes:
      if (details?.episodes ?? []).isEmpty { return status ?? "No episodes" }
      if episodesInSeason().isEmpty { return "No episodes in this season" }
    case .details:
      if details == nil { return "Loading details…" }
    default:
      break
    }
    return nil
  }

  func railTitles() -> [String] {
    switch section {
    case .movies:
      return ["All"] + groupNames(.vod).map(Self.groupTitle)
    case .series:
      return ["All"] + groupNames(.series).map(Self.groupTitle)
    case .live:
      return ["All"] + groupNames(.live).map(Self.groupTitle)
    case .continueWatching:
      return ["All", "Movies", "Episodes"]
    case .favourites:
      return ["All", "Movies", "Series", "Live"]
    case .search:
      return ["All", "Movies", "Series", "Live"]
    }
  }

  func bodyItems() -> [IPTVItem] {
    guard let source else { return [] }
    switch section {
    case .movies:
      return grouped(catalogItems().filter { $0.kind == .vod }, kind: .vod)
    case .series:
      return grouped(catalogItems().filter { $0.kind == .series }, kind: .series)
    case .live:
      return grouped(catalogItems().filter { $0.kind == .live }, kind: .live)
    case .continueWatching:
      let movies = IPTVLibrary.shared.continueWatching(source: source, kind: .vod)
      let episodes = IPTVLibrary.shared.continueWatching(source: source, kind: .episode)
      switch railIndex {
      case 1: return movies
      case 2: return episodes
      default:
        return (movies + episodes).sorted { lhs, rhs in
          let left = IPTVLibrary.shared.watchProgress(for: lhs.id, source: source)?.updated ?? .distantPast
          let right = IPTVLibrary.shared.watchProgress(for: rhs.id, source: source)?.updated ?? .distantPast
          return left > right
        }
      }
    case .favourites:
      let favs = catalogItems().filter { IPTVLibrary.shared.isFavourite($0, source: source) }
      switch railIndex {
      case 1: return favs.filter { $0.kind == .vod }
      case 2: return favs.filter { $0.kind == .series }
      case 3: return favs.filter { $0.kind == .live }
      default: return favs
      }
    case .search:
      let needle = IPTVText.normalize(query)
      guard !needle.isEmpty else { return [] }
      var items = catalogItems().filter { $0.kind == .vod || $0.kind == .series || $0.kind == .live }
      switch railIndex {
      case 1: items = items.filter { $0.kind == .vod }
      case 2: items = items.filter { $0.kind == .series }
      case 3: items = items.filter { $0.kind == .live }
      default: break
      }
      return items.filter { $0.matchesText(needle) }
    }
  }

  func seasonNumbers() -> [Int] {
    var ordered: [Int] = []
    var seen = Set<Int>()
    for episode in details?.episodes ?? [] where seen.insert(episode.season).inserted {
      ordered.append(episode.season)
    }
    return ordered
  }

  func seasonTitle(_ season: Int) -> String {
    season == 0 ? "Specials" : "Season \(season)"
  }

  func episodesInSeason() -> [IPTVEpisodeDetails] {
    let seasons = seasonNumbers()
    guard seasons.indices.contains(seasonIndex) else { return [] }
    let season = seasons[seasonIndex]
    return (details?.episodes ?? []).filter { $0.season == season }
  }

  func actions() -> [Action] {
    guard let item = detailItem else { return [] }
    var list: [Action] = []
    if item.kind == .series {
      list.append(.play)
      if resumableEpisode() != nil { list.append(.resume) }
      list.append(.episodes)
    } else {
      list.append(.play)
      if canResume(item) { list.append(.resume) }
    }
    if trailerLink() != nil { list.append(.trailer) }
    list.append(.favourite)
    return list
  }

  func actionTitle(_ action: Action) -> String {
    switch action {
    case .play:
      return "Play"
    case .resume:
      if detailItem?.kind == .series, let episode = resumableEpisode(), let source,
         let record = IPTVLibrary.shared.watchProgress(for: episode.item.id, source: source) {
        return "Resume \(Self.clock(record.position))"
      }
      if let item = detailItem, let source, let record = IPTVLibrary.shared.watchProgress(for: item.id, source: source) {
        return "Resume \(Self.clock(record.position))"
      }
      return "Resume"
    case .episodes:
      return "Episodes"
    case .trailer:
      return "Trailer"
    case .favourite:
      guard let item = detailItem, let source else { return "Favourite" }
      return IPTVLibrary.shared.isFavourite(item, source: source) ? "Favourited" : "Favourite"
    }
  }

  func watchMark(for itemID: String) -> WatchMark {
    guard let source, let record = IPTVLibrary.shared.watchProgress(for: itemID, source: source) else {
      return WatchMark(fraction: 0, label: nil)
    }
    let fraction = CGFloat(IPTVWatch.fraction(record))
    if IPTVWatch.resumeSeconds(record) != nil {
      return WatchMark(fraction: fraction, label: "Resume \(Self.clock(record.position))")
    }
    let finished = record.duration > 0 && (record.position >= record.duration - 30 || record.position / record.duration >= 0.95)
    if finished { return WatchMark(fraction: 1, label: "Watched") }
    if record.position >= 5 { return WatchMark(fraction: fraction, label: nil) }
    return WatchMark(fraction: 0, label: nil)
  }

  func image(for raw: String?) -> NSImage? {
    guard let raw, let url = URL(string: raw), let scheme = url.scheme, scheme == "http" || scheme == "https" else { return nil }
    if let cached = IPTVImageLoader.shared.cachedImage(for: url) { return cached }
    if imageRequests.insert(url.absoluteString).inserted {
      IPTVImageLoader.shared.load(url) { [weak self] _ in
        self?.redraw()
      }
    }
    return nil
  }

  func promptedEpisode() -> IPTVEpisodeDetails? { prompted?.episode }

  func makeLayout(_ bounds: NSRect) -> IPTVBrowseLayout {
    var layout = IPTVBrowseLayout(bounds: bounds)
    let width = max(bounds.width, 1)
    layout.scale = min(1, max(0.62, width / 1920))
    let reserve = GlassesEyeControls.shared.shown ? layout.s(88) : layout.s(18)
    let inset = layout.s(28)
    switch screen {
    case .hidden:
      break
    case .menu:
      let row = layout.s(84)
      layout.menuRowHeight = row
      let panelWidth = min(layout.s(820), bounds.width - layout.s(80))
      let panelHeight = layout.s(88) + row * CGFloat(Self.menuTitles.count) + layout.s(28)
      let x = max(inset, (bounds.width - panelWidth) / 2)
      let y = max(inset, (bounds.height - reserve - panelHeight) / 2)
      layout.panel = NSRect(x: x, y: y, width: max(0, panelWidth), height: max(0, panelHeight))
    case .next:
      let cardWidth = min(layout.s(860), bounds.width - layout.s(64))
      let cardHeight = layout.s(380)
      layout.nextCard = NSRect(
        x: max(inset, (bounds.width - cardWidth) / 2),
        y: max(inset, (bounds.height - reserve - cardHeight) / 2),
        width: max(0, cardWidth),
        height: max(0, cardHeight)
      )
      let buttonWidth = layout.s(220)
      let buttonHeight = layout.s(56)
      layout.nextPlay = NSRect(x: layout.nextCard.minX + layout.s(28), y: layout.nextCard.maxY - buttonHeight - layout.s(24), width: buttonWidth, height: buttonHeight)
      layout.nextCancel = NSRect(x: layout.nextPlay.maxX + layout.s(16), y: layout.nextPlay.minY, width: buttonWidth, height: buttonHeight)
    case .details:
      layout.panel = NSRect(x: inset, y: inset, width: max(0, bounds.width - inset * 2), height: max(0, bounds.height - inset - reserve))
      layout.poster = NSSize(width: layout.s(300), height: layout.s(450))
      let poster = NSRect(x: layout.panel.minX + layout.s(28), y: layout.panel.minY + layout.s(28), width: layout.poster.width, height: layout.poster.height)
      layout.detailPoster = poster
      let textX = poster.maxX + layout.s(32)
      let textWidth = max(0, layout.panel.maxX - textX - layout.s(28))
      layout.titleRect = NSRect(x: textX, y: layout.panel.minY + layout.s(24), width: textWidth, height: layout.s(52))
      layout.factRect = NSRect(x: textX, y: layout.titleRect.maxY + layout.s(4), width: textWidth, height: layout.s(32))
      layout.plotRect = NSRect(x: textX, y: layout.factRect.maxY + layout.s(12), width: textWidth, height: layout.s(180))
      layout.castRect = NSRect(x: textX, y: layout.plotRect.maxY + layout.s(8), width: textWidth, height: layout.s(72))
      var buttonX = textX
      let buttonHeight = layout.s(56)
      let buttonY = layout.panel.maxY - buttonHeight - layout.s(28)
      for action in actions() {
        let title = actionTitle(action)
        let buttonWidth = max(layout.s(168), CGFloat(title.count) * layout.s(14) + layout.s(48))
        layout.actionRects.append(NSRect(x: buttonX, y: buttonY, width: buttonWidth, height: buttonHeight))
        buttonX += buttonWidth + layout.s(14)
      }
    case .grid, .search, .episodes:
      layout.panel = NSRect(x: inset, y: inset, width: max(0, bounds.width - inset * 2), height: max(0, bounds.height - inset - reserve))
      layout.header = NSRect(x: layout.panel.minX + layout.s(8), y: layout.panel.minY + layout.s(6), width: max(0, layout.panel.width - layout.s(16)), height: layout.s(52))
      var contentTop = layout.header.maxY + layout.s(8)
      if screen == .search {
        layout.queryBar = NSRect(x: layout.header.minX, y: contentTop, width: layout.header.width, height: layout.s(52))
        contentTop = layout.queryBar.maxY + layout.s(8)
      }
      layout.hint = NSRect(x: layout.header.minX, y: layout.panel.maxY - layout.s(36), width: layout.header.width, height: layout.s(28))
      let columnWidth = min(layout.s(320), max(layout.s(220), layout.panel.width * 0.24))
      let column = NSRect(x: layout.panel.minX + layout.s(4), y: contentTop, width: columnWidth, height: max(0, layout.hint.minY - contentTop - layout.s(8)))
      let body = NSRect(x: column.maxX + layout.s(16), y: column.minY, width: max(0, layout.panel.maxX - column.maxX - layout.s(12)), height: column.height)
      layout.railRow = layout.s(58)
      layout.listRow = screen == .episodes ? layout.s(148) : layout.s(92)
      if screen == .episodes {
        layout.seasonRail = column
        layout.episodeBody = body
      } else {
        layout.rail = column
        layout.body = body
      }
      layout.posterGap = layout.s(18)
      layout.titleHeight = layout.s(48)
      let naturalW = layout.s(210)
      let naturalH = layout.s(315)
      let gap = layout.posterGap
      let columns = max(1, Int((body.width + gap) / (naturalW + gap)))
      layout.columns = columns
      let fitW = columns > 0 ? (body.width - gap * CGFloat(max(0, columns - 1))) / CGFloat(columns) : naturalW
      layout.poster = NSSize(width: min(naturalW, max(layout.s(120), fitW)), height: naturalH)
      let strideY = layout.poster.height + layout.titleHeight + gap
      layout.visiblePosterRows = max(1, Int((body.height + gap) / max(1, strideY)))
      layout.visibleRail = max(1, Int(column.height / max(1, layout.railRow)))
      layout.visibleRows = max(1, Int(body.height / max(1, layout.listRow)))
      layout.posters = screen != .episodes && section != .live
    }
    return layout
  }

  func redraw() {
    clampSelection()
    host.needsLayout = true
    host.needsDisplay = true
    for pane in host.panes where !pane.isHidden {
      pane.needsDisplay = true
    }
  }

  // MARK: - Navigation

  private func showMenu() {
    guard let found = contextSource() ?? source else { return }
    if source?.id != found.id {
      catalog = nil
      catalogSourceID = nil
      detailItem = nil
      details = nil
    }
    source = found
    lastSource = found
    installMonitor()
    ensureCatalog()
    cancelNextTimer()
    prompted = nil
    screen = .menu
    menuIndex = 0
    status = nil
    claimKey()
    attachIfNeeded()
  }

  private func openSection(_ next: Section) {
    section = next
    railIndex = 0
    railTop = 0
    bodyIndex = 0
    bodyTop = 0
    zone = .rail
    query = ""
    status = nil
    screen = next == .search ? .search : .grid
    ensureCatalog()
    redraw()
  }

  private func activate() {
    switch screen {
    case .hidden:
      break
    case .menu:
      activateMenu()
    case .grid, .search:
      if zone == .rail {
        zone = .body
        revealBody()
        redraw()
      } else {
        activateBody()
      }
    case .details:
      activateDetails()
    case .episodes:
      if zone == .rail {
        zone = .body
        revealEpisode()
        redraw()
      } else {
        playFocusedEpisode()
      }
    case .next:
      if nextAction == 0 { playPrompted() } else { goBack() }
    }
  }

  private func activateMenu() {
    switch menuIndex {
    case 0:
      if IPTVLiveOverlayController.shared.session != nil {
        dismissToVideo()
        IPTVLiveOverlayController.shared.showChannelList()
      } else {
        openSection(.live)
      }
    case 1: openSection(.movies)
    case 2: openSection(.series)
    case 3: openSection(.continueWatching)
    case 4: openSection(.favourites)
    case 5: openSection(.search)
    default: break
    }
  }

  private func activateBody() {
    let items = bodyItems()
    guard items.indices.contains(bodyIndex) else { return }
    let item = items[bodyIndex]
    if item.kind == .live {
      _ = playLive(item)
      return
    }
    if item.kind == .episode {
      openEpisode(item)
      return
    }
    openDetails(item)
  }

  private func openEpisode(_ item: IPTVItem) {
    guard let source else { return }
    if let identity = IPTVLibrary.shared.seriesIdentity(for: item.id, source: source),
       let series = catalogItems().first(where: { $0.id == identity.id && $0.kind == .series }) {
      pendingEpisodeID = item.id
      openDetails(series)
      return
    }
    openDetails(item)
  }

  private func openDetails(_ item: IPTVItem) {
    savedRail = railIndex
    savedBody = bodyIndex
    savedZone = zone
    returnToSearch = section == .search
    detailItem = item
    details = IPTVTitleParser.details(from: item)
    actionIndex = 0
    screen = .details
    status = "Loading details…"
    loadGeneration += 1
    let generation = loadGeneration
    let itemID = item.id
    redraw()
    guard let source else { return }
    IPTVLibrary.shared.loadTitleDetails(for: item, source: source) { [weak self] result in
      self?.onMain {
        guard let self, generation == self.loadGeneration, self.detailItem?.id == itemID else { return }
        switch result {
        case .failure(let error):
          self.status = error.localizedDescription
        case .success(let payload):
          self.details = payload.0
          self.status = payload.1
          if let pending = self.pendingEpisodeID, payload.0.episodes.contains(where: { $0.item.id == pending }) {
            self.pendingEpisodeID = nil
            self.showEpisode(pending)
          }
        }
        if self.actionIndex >= self.actions().count { self.actionIndex = 0 }
        self.redraw()
      }
    }
  }

  private func showEpisode(_ itemID: String) {
    let episodes = details?.episodes ?? []
    guard let index = episodes.firstIndex(where: { $0.item.id == itemID }) else {
      seasonIndex = 0
      episodeIndex = 0
      episodeTop = 0
      seasonTop = 0
      zone = .body
      screen = .episodes
      return
    }
    let season = episodes[index].season
    seasonIndex = seasonNumbers().firstIndex(of: season) ?? 0
    episodeIndex = episodesInSeason().firstIndex(where: { $0.item.id == itemID }) ?? 0
    episodeTop = 0
    seasonTop = 0
    zone = .body
    screen = .episodes
    revealEpisode()
  }

  private func activateDetails() {
    let list = actions()
    guard let item = detailItem, list.indices.contains(actionIndex) else { return }
    switch list[actionIndex] {
    case .play:
      if item.kind == .series {
        guard let first = details?.episodes.first else {
          status = "Episodes are still loading."
          redraw()
          return
        }
        _ = playItem(first.item, resume: false, series: item, episodes: details?.episodes ?? [])
      } else {
        _ = playItem(item, resume: false, series: nil, episodes: [])
      }
    case .resume:
      if item.kind == .series, let episode = resumableEpisode() {
        _ = playItem(episode.item, resume: true, series: item, episodes: details?.episodes ?? [])
      } else {
        _ = playItem(item, resume: true, series: nil, episodes: [])
      }
    case .episodes:
      if let episode = resumableEpisode() {
        showEpisode(episode.item.id)
      } else {
        seasonIndex = 0
        episodeIndex = 0
        episodeTop = 0
        seasonTop = 0
        zone = .body
        screen = .episodes
      }
      status = nil
      redraw()
    case .trailer:
      if let url = trailerLink() { NSWorkspace.shared.open(url) }
    case .favourite:
      guard let source else { return }
      IPTVLibrary.shared.toggleFavourite(item, source: source)
      redraw()
    }
  }

  private func playFocusedEpisode() {
    let rows = episodesInSeason()
    guard rows.indices.contains(episodeIndex) else { return }
    let episode = rows[episodeIndex]
    let resume = canResume(episode.item)
    _ = playItem(episode.item, resume: resume, series: detailItem?.kind == .series ? detailItem : playbackContext?.series, episodes: details?.episodes ?? playbackContext?.episodes ?? [])
  }

  @discardableResult
  private func playItem(_ item: IPTVItem, resume: Bool, series: IPTVItem?, episodes: [IPTVEpisodeDetails]) -> Bool {
    nextGeneration += 1
    guard let source else {
      status = "No IPTV source."
      redraw()
      return false
    }
    if item.kind == .live { return playLive(item) }
    let seconds = resume ? resumeSeconds(item) : nil
    guard let url = IPTVLibrary.shared.playbackURL(for: item, source: source) else {
      status = "No stream address for \(item.name). If this is an Xtream login, edit it and enter the password again."
      redraw()
      return false
    }
    if !resume {
      IPTVLibrary.shared.forgetProgress(itemID: item.id, source: source)
    }
    if item.kind == .episode {
      playbackContext = PlaybackContext(source: source, series: series, episodes: episodes, itemID: item.id)
    } else {
      playbackContext = nil
    }
    cancelNextTimer()
    prompted = nil
    IPTVLiveOverlayController.shared.end()
    IPTVLibrary.shared.registerPlayback(
      stream: url,
      source: source,
      item: item,
      title: item.name,
      resumeAt: seconds,
      seriesItemID: series?.id,
      seriesTitle: series?.name
    )
    let player = PlayerCore.playerCores.isEmpty ? PlayerCore.activeOrNew : PlayerCore.active
    player.openURL(url)
    dismissToVideo()
    return true
  }

  @discardableResult
  private func playLive(_ item: IPTVItem) -> Bool {
    guard let source else { return false }
    guard let url = IPTVLibrary.shared.playbackURL(for: item, source: source) else {
      status = "No stream address for \(item.name)."
      redraw()
      return false
    }
    let channels = catalogItems().filter { $0.kind == .live }
    let list = channels.isEmpty ? [item] : channels
    cancelNextTimer()
    prompted = nil
    playbackContext = nil
    dismissToVideo()
    IPTVLiveOverlayController.shared.begin(source: source, item: item, channels: list, guide: IPTVEPG(), catchup: nil)
    IPTVLibrary.shared.registerPlayback(stream: url, source: source, item: item, title: item.name)
    let player = PlayerCore.playerCores.isEmpty ? PlayerCore.activeOrNew : PlayerCore.active
    player.openURL(url)
    IPTVLiveOverlayController.shared.attachIfNeeded()
    return true
  }

  private func presentNext(_ episode: IPTVEpisodeDetails, series: IPTVItem?, episodes: [IPTVEpisodeDetails]) {
    prompted = NextPrompt(episode: episode, series: series, episodes: episodes)
    nextAction = 0
    nextSeconds = 10
    screen = .next
    status = nil
    installMonitor()
    claimKey()
    startNextTimer()
    attachIfNeeded()
  }

  private func playPrompted() {
    cancelNextTimer()
    guard let prompted else { return }
    let episode = prompted.episode
    let resume = canResume(episode.item)
    _ = playItem(episode.item, resume: resume, series: prompted.series, episodes: prompted.episodes)
  }

  private func goBack() {
    switch screen {
    case .hidden:
      break
    case .menu:
      dismissToVideo()
    case .grid, .search:
      screen = .menu
      status = nil
      redraw()
    case .details:
      loadGeneration += 1
      pendingEpisodeID = nil
      detailItem = nil
      details = nil
      status = nil
      railIndex = savedRail
      bodyIndex = savedBody
      zone = savedZone
      screen = returnToSearch ? .search : .grid
      revealBody()
      redraw()
    case .episodes:
      screen = .details
      status = nil
      redraw()
    case .next:
      nextGeneration += 1
      cancelNextTimer()
      prompted = nil
      dismissToVideo()
    }
  }

  private func dismissToVideo() {
    cancelNextTimer()
    screen = .hidden
    status = nil
    host.removeFromSuperview()
  }

  private func moveVertical(_ delta: Int) {
    guard delta != 0 else { return }
    switch screen {
    case .hidden:
      break
    case .menu:
      menuIndex = wrap(menuIndex + delta, Self.menuTitles.count)
      redraw()
    case .grid, .search:
      if section != .live && zone == .rail {
        moveRail(delta)
      } else if usesPosters() {
        movePoster(rows: delta, cols: 0)
      } else {
        moveList(delta)
      }
    case .details:
      moveAction(delta)
    case .episodes:
      if zone == .rail { moveSeason(delta) } else { moveEpisode(delta) }
    case .next:
      nextAction = delta > 0 ? 1 : 0
      redraw()
    }
  }

  private func moveHorizontal(_ delta: Int) {
    guard delta != 0 else { return }
    switch screen {
    case .hidden, .menu:
      break
    case .grid where section == .live:
      moveRail(delta)
    case .grid, .search:
      if zone == .rail {
        if delta > 0 {
          zone = .body
          revealBody()
          redraw()
        } else {
          moveRail(delta)
        }
      } else {
        let columns = max(1, currentLayout().columns)
        let col = bodyIndex % columns
        if delta < 0 && col == 0 {
          zone = .rail
          revealRail()
          redraw()
        } else {
          movePoster(rows: 0, cols: delta)
        }
      }
    case .details:
      moveAction(delta)
    case .episodes:
      if zone == .rail {
        if delta > 0 {
          zone = .body
          revealEpisode()
          redraw()
        } else {
          moveSeason(delta)
        }
      } else if delta < 0 {
        zone = .rail
        revealSeason()
        redraw()
      }
    case .next:
      nextAction = delta > 0 ? min(1, nextAction + 1) : max(0, nextAction - 1)
      redraw()
    }
  }

  private func moveRail(_ delta: Int) {
    let count = railTitles().count
    guard count > 0, delta == 0 || count > 1 else { return }
    railIndex = wrap(railIndex + delta, count)
    bodyIndex = 0
    bodyTop = 0
    if section == .live, let playing = IPTVLiveOverlayController.shared.session?.item.id,
       let index = bodyItems().firstIndex(where: { $0.id == playing }) {
      bodyIndex = index
    }
    revealRail()
    revealBody()
    redraw()
  }

  private func moveList(_ delta: Int) {
    let count = bodyItems().count
    guard count > 0 else { return }
    bodyIndex = wrap(bodyIndex + delta, count)
    revealList()
    redraw()
  }

  private func movePoster(rows: Int, cols: Int) {
    let items = bodyItems()
    let columns = max(1, currentLayout().columns)
    guard !items.isEmpty else { return }
    var index = min(bodyIndex, items.count - 1)
    if cols != 0 {
      let row = index / columns
      let col = index % columns
      let nextCol = col + cols
      guard nextCol >= 0 && nextCol < columns else { return }
      let next = row * columns + nextCol
      guard next < items.count else { return }
      index = next
    }
    if rows != 0 {
      let next = index + rows * columns
      if next < 0 {
        index = index % columns
      } else if next >= items.count {
        let col = index % columns
        let lastRow = ((items.count - 1) / columns) * columns
        index = min(items.count - 1, lastRow + col)
      } else {
        index = next
      }
    }
    bodyIndex = index
    revealBody()
    redraw()
  }

  private func moveAction(_ delta: Int) {
    let count = actions().count
    guard count > 0 else { return }
    actionIndex = wrap(actionIndex + delta, count)
    redraw()
  }

  private func moveSeason(_ delta: Int) {
    let count = seasonNumbers().count
    guard count > 0 else { return }
    seasonIndex = wrap(seasonIndex + delta, count)
    episodeIndex = 0
    episodeTop = 0
    revealSeason()
    redraw()
  }

  private func moveEpisode(_ delta: Int) {
    let count = episodesInSeason().count
    guard count > 0 else { return }
    episodeIndex = wrap(episodeIndex + delta, count)
    revealEpisode()
    redraw()
  }

  private func pageStep(up: Bool) -> Int {
    let layout = currentLayout()
    let magnitude: Int
    switch screen {
    case .grid, .search:
      if section != .live && zone == .rail {
        magnitude = layout.visibleRail
      } else if usesPosters() {
        magnitude = layout.visiblePosterRows
      } else {
        magnitude = layout.visibleRows
      }
    case .episodes:
      magnitude = zone == .rail ? layout.visibleRail : layout.visibleRows
    default:
      magnitude = 1
    }
    let step = max(1, magnitude)
    return up ? -step : step
  }

  private func revealRail() {
    let page = max(1, currentLayout().visibleRail)
    if railIndex < railTop { railTop = railIndex }
    if railIndex >= railTop + page { railTop = max(0, railIndex - page + 1) }
  }

  private func revealBody() {
    if usesPosters() {
      let columns = max(1, currentLayout().columns)
      let pageRows = max(1, currentLayout().visiblePosterRows)
      let rowStart = (bodyIndex / columns) * columns
      if bodyIndex < bodyTop { bodyTop = rowStart }
      if bodyIndex >= bodyTop + pageRows * columns {
        let row = bodyIndex / columns
        bodyTop = max(0, (row - pageRows + 1) * columns)
      }
    } else {
      revealList()
    }
  }

  private func revealList() {
    let page = max(1, currentLayout().visibleRows)
    if bodyIndex < bodyTop { bodyIndex = min(bodyIndex, max(0, bodyItems().count - 1)) }
    if bodyIndex < bodyTop { bodyTop = bodyIndex }
    if bodyIndex >= bodyTop + page { bodyTop = max(0, bodyIndex - page + 1) }
  }

  private func revealSeason() {
    let page = max(1, currentLayout().visibleRail)
    if seasonIndex < seasonTop { seasonTop = seasonIndex }
    if seasonIndex >= seasonTop + page { seasonTop = max(0, seasonIndex - page + 1) }
  }

  private func revealEpisode() {
    let page = max(1, currentLayout().visibleRows)
    if episodeIndex < episodeTop { episodeTop = episodeIndex }
    if episodeIndex >= episodeTop + page { episodeTop = max(0, episodeIndex - page + 1) }
  }

  private func clampSelection() {
    if screen == .grid || screen == .search {
      let rails = railTitles().count
      if rails == 0 { railIndex = 0 } else if railIndex >= rails { railIndex = rails - 1 }
      let count = bodyItems().count
      if count == 0 { bodyIndex = 0 } else if bodyIndex >= count { bodyIndex = count - 1 }
    }
    if screen == .episodes {
      let seasons = seasonNumbers().count
      if seasons == 0 { seasonIndex = 0 } else if seasonIndex >= seasons { seasonIndex = seasons - 1 }
      let count = episodesInSeason().count
      if count == 0 { episodeIndex = 0 } else if episodeIndex >= count { episodeIndex = count - 1 }
    }
    if screen == .details {
      let count = actions().count
      if count == 0 { actionIndex = 0 } else if actionIndex >= count { actionIndex = count - 1 }
    }
  }

  private func applyHover(_ hit: Hit) {
    switch hit {
    case .menu(let index):
      guard menuIndex != index else { return }
      menuIndex = index
    case .rail(let index):
      guard zone != .rail || railIndex != index else { return }
      zone = .rail
      railIndex = index
      bodyIndex = 0
      bodyTop = 0
      revealRail()
    case .body(let index):
      guard zone != .body || bodyIndex != index else { return }
      zone = .body
      bodyIndex = index
    case .action(let index):
      guard actionIndex != index else { return }
      actionIndex = index
    case .season(let index):
      guard zone != .rail || seasonIndex != index else { return }
      zone = .rail
      if seasonIndex != index {
        seasonIndex = index
        episodeIndex = 0
        episodeTop = 0
      }
      revealSeason()
    case .episode(let index):
      guard zone != .body || episodeIndex != index else { return }
      zone = .body
      episodeIndex = index
    case .nextPlay:
      guard nextAction != 0 else { return }
      nextAction = 0
    case .nextCancel:
      guard nextAction != 1 else { return }
      nextAction = 1
    case .none, .outside:
      return
    }
    redraw()
  }

  func hitTest(_ point: NSPoint, layout: IPTVBrowseLayout) -> Hit {
    switch screen {
    case .hidden:
      return .none
    case .menu:
      if !layout.panel.contains(point) { return .outside }
      for index in Self.menuTitles.indices where layout.menuRect(index).contains(point) {
        return .menu(index)
      }
      return .none
    case .next:
      if layout.nextPlay.contains(point) { return .nextPlay }
      if layout.nextCancel.contains(point) { return .nextCancel }
      if !layout.nextCard.contains(point) { return .outside }
      return .none
    case .details:
      for (index, rect) in layout.actionRects.enumerated() where rect.contains(point) {
        return .action(index)
      }
      return .none
    case .episodes:
      if let row = layout.rowIndex(at: point, top: seasonTop, rowHeight: layout.railRow, in: layout.seasonRail),
         seasonNumbers().indices.contains(row) {
        return .season(row)
      }
      if let row = layout.rowIndex(at: point, top: episodeTop, rowHeight: layout.listRow, in: layout.episodeBody),
         episodesInSeason().indices.contains(row) {
        return .episode(row)
      }
      return .none
    case .grid, .search:
      if let row = layout.rowIndex(at: point, top: railTop, rowHeight: layout.railRow, in: layout.rail),
         railTitles().indices.contains(row) {
        return .rail(row)
      }
      if usesPosters() {
        return posterHit(point, layout: layout)
      }
      if let row = layout.rowIndex(at: point, top: bodyTop, rowHeight: layout.listRow, in: layout.body),
         bodyItems().indices.contains(row) {
        return .body(row)
      }
      return .none
    }
  }

  private func posterHit(_ point: NSPoint, layout: IPTVBrowseLayout) -> Hit {
    guard layout.body.contains(point), layout.columns > 0 else { return .none }
    let strideX = layout.poster.width + layout.posterGap
    let strideY = layout.poster.height + layout.titleHeight + layout.posterGap
    guard strideX > 1, strideY > 1 else { return .none }
    let row = Int((point.y - layout.body.minY) / strideY)
    let col = Int((point.x - layout.body.minX) / strideX)
    guard row >= 0, col >= 0, col < layout.columns else { return .none }
    let index = bodyTop + row * layout.columns + col
    guard bodyItems().indices.contains(index) else { return .none }
    guard layout.posterRect(index, top: bodyTop).contains(point) else { return .none }
    return .body(index)
  }

  // MARK: - Data

  private func contextSource() -> IPTVSource? {
    if let session = IPTVLiveOverlayController.shared.session {
      lastSource = session.source
      return session.source
    }
    if let active = IPTVLibrary.shared.activePlayback(),
       let match = IPTVLibrary.shared.sources.first(where: { $0.id == active.sourceID }) {
      lastSource = match
      return match
    }
    if let lastSource, IPTVLibrary.shared.sources.contains(where: { $0.id == lastSource.id }) {
      return lastSource
    }
    self.lastSource = nil
    return nil
  }

  private func ensureCatalog() {
    guard let source else { return }
    if catalogSourceID == source.id, catalog != nil { return }
    if let cached = IPTVLibrary.shared.cache(for: source) {
      catalog = cached
      catalogSourceID = source.id
      return
    }
    catalog = nil
    catalogSourceID = source.id
    status = "Loading the catalog…"
    let sourceID = source.id
    IPTVLibrary.shared.loadCatalog(for: source) { [weak self] result in
      self?.onMain {
        guard let self, self.source?.id == sourceID else { return }
        switch result {
        case .success(let loaded):
          IPTVLibrary.shared.store(cache: loaded, for: source)
          self.catalog = loaded
          self.catalogSourceID = sourceID
          if self.status == "Loading the catalog…" { self.status = nil }
        case .failure(let error):
          self.status = error.localizedDescription
        }
        self.redraw()
      }
    }
  }

  private func catalogItems() -> [IPTVItem] {
    guard let source, catalogSourceID == source.id else { return [] }
    return catalog?.items ?? []
  }

  private func groupNames(_ kind: IPTVItemKind) -> [String] {
    var ordered: [String] = []
    var seen = Set<String>()
    for item in catalogItems() where item.kind == kind && seen.insert(item.group).inserted {
      ordered.append(item.group)
    }
    return ordered
  }

  private func grouped(_ items: [IPTVItem], kind: IPTVItemKind) -> [IPTVItem] {
    guard railIndex > 0 else { return items }
    let names = groupNames(kind)
    let index = railIndex - 1
    guard names.indices.contains(index) else { return items }
    let group = names[index]
    return items.filter { $0.group == group }
  }

  private func canResume(_ item: IPTVItem) -> Bool {
    resumeSeconds(item) != nil
  }

  private func resumeSeconds(_ item: IPTVItem) -> Double? {
    guard let source, let record = IPTVLibrary.shared.watchProgress(for: item.id, source: source) else { return nil }
    return IPTVWatch.resumeSeconds(record)
  }

  private func resumableEpisode() -> IPTVEpisodeDetails? {
    guard let source else { return nil }
    var best: (IPTVEpisodeDetails, Date)?
    for episode in details?.episodes ?? [] {
      guard let record = IPTVLibrary.shared.watchProgress(for: episode.item.id, source: source),
            IPTVWatch.resumeSeconds(record) != nil else { continue }
      if let current = best {
        if record.updated > current.1 { best = (episode, record.updated) }
      } else {
        best = (episode, record.updated)
      }
    }
    return best?.0
  }

  private func trailerLink() -> URL? {
    guard let raw = details?.trailerURL, let url = URL(string: raw) else { return nil }
    guard url.scheme == "http" || url.scheme == "https" else { return nil }
    return url
  }

  private func nextEpisode(after itemID: String, in episodes: [IPTVEpisodeDetails]) -> IPTVEpisodeDetails? {
    guard let index = episodes.firstIndex(where: { $0.item.id == itemID }) else { return nil }
    let next = index + 1
    guard episodes.indices.contains(next) else { return nil }
    return episodes[next]
  }

  private func startNextTimer() {
    cancelNextTimer()
    nextSeconds = 10
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
      guard let self, self.screen == .next else {
        timer.invalidate()
        return
      }
      self.nextSeconds -= 1
      if self.nextSeconds <= 0 {
        timer.invalidate()
        self.nextTimer = nil
        self.playPrompted()
      } else {
        self.redraw()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    nextTimer = timer
  }

  private func cancelNextTimer() {
    nextTimer?.invalidate()
    nextTimer = nil
  }

  private func claimKey() {
    guard !PlayerCore.playerCores.isEmpty, let main = PlayerCore.active.mainWindow else { return }
    guard let window = main.window else { return }
    if Immersive3DController.shared.glassesActive, let mainWindow = window as? MainWindow {
      mainWindow.forceKeyAndMain = true
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(window.contentView)
  }

  private func installMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.shouldTake(event) else { return event }
      let consumed = self.handleKeyDown(event)
      self.logKey(event, source: "browse-monitor", consumed: consumed)
      return consumed ? nil : event
    }
  }

  private func shouldTake(_ event: NSEvent) -> Bool {
    if !event.modifierFlags.intersection([.command, .option, .control]).isEmpty { return false }
    if event.window?.firstResponder is NSTextView { return false }
    if NSApp.keyWindow?.firstResponder is NSTextView { return false }
    let plain = event.charactersIgnoringModifiers ?? ""
    let wants = screen != .hidden || (isMenuChord(event.keyCode, plain) && contextSource() != nil)
    guard wants else { return false }
    guard !PlayerCore.playerCores.isEmpty, let main = PlayerCore.active.mainWindow else { return false }
    if event.window === main.window { return true }
    return Immersive3DController.shared.glassesActive
  }

  private func currentFirstResponderIsText() -> Bool {
    if !PlayerCore.playerCores.isEmpty, PlayerCore.active.mainWindow.window?.firstResponder is NSTextView {
      return true
    }
    return NSApp.keyWindow?.firstResponder is NSTextView
  }

  private func isMenuChord(_ code: UInt16, _ plain: String) -> Bool {
    if code == 115 { return true }
    return plain.count == 1 && plain.lowercased() == "m"
  }

  private func isTyping(_ plain: String) -> Bool {
    guard plain.count == 1, let scalar = plain.unicodeScalars.first else { return false }
    if scalar.value < 32 || scalar.value == 127 { return false }
    if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return false }
    return true
  }

  private func pane(containing event: NSEvent) -> IPTVBrowseOverlayPane? {
    host.panes.first { pane in
      guard !pane.isHidden, pane.window != nil else { return false }
      return pane.bounds.contains(pane.convert(event.locationInWindow, from: nil))
    }
  }

  private func currentLayout() -> IPTVBrowseLayout {
    let bounds = host.panes.first(where: { !$0.isHidden && $0.bounds.width > 32 })?.bounds
      ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    return makeLayout(bounds)
  }

  private func wrap(_ index: Int, _ count: Int) -> Int {
    guard count > 0 else { return 0 }
    return ((index % count) + count) % count
  }

  private func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
  }

  private static func groupTitle(_ raw: String) -> String {
    raw.isEmpty ? "Ungrouped" : raw
  }

  static func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
    return String(format: "%d:%02d", minutes, secs)
  }
}

struct IPTVBrowseLayout {
  var bounds: NSRect
  var scale: CGFloat = 1
  var panel = NSRect.zero
  var header = NSRect.zero
  var queryBar = NSRect.zero
  var hint = NSRect.zero
  var rail = NSRect.zero
  var body = NSRect.zero
  var seasonRail = NSRect.zero
  var episodeBody = NSRect.zero
  var poster = NSSize.zero
  var detailPoster = NSRect.zero
  var posterGap: CGFloat = 16
  var titleHeight: CGFloat = 44
  var columns = 1
  var railRow: CGFloat = 56
  var listRow: CGFloat = 88
  var menuRowHeight: CGFloat = 80
  var visibleRail = 1
  var visibleRows = 1
  var visiblePosterRows = 1
  var posters = false
  var titleRect = NSRect.zero
  var factRect = NSRect.zero
  var plotRect = NSRect.zero
  var castRect = NSRect.zero
  var actionRects: [NSRect] = []
  var nextCard = NSRect.zero
  var nextPlay = NSRect.zero
  var nextCancel = NSRect.zero

  func s(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }

  func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: max(13, s(size)), weight: weight)
  }

  func menuRect(_ index: Int) -> NSRect {
    NSRect(
      x: panel.minX + s(18),
      y: panel.minY + s(76) + CGFloat(index) * menuRowHeight,
      width: max(0, panel.width - s(36)),
      height: max(0, menuRowHeight - s(10))
    )
  }

  func posterRect(_ index: Int, top: Int) -> NSRect {
    let columns = max(1, self.columns)
    let local = index - top
    guard local >= 0 else { return .zero }
    let col = local % columns
    let row = local / columns
    let strideX = poster.width + posterGap
    let strideY = poster.height + titleHeight + posterGap
    return NSRect(x: body.minX + CGFloat(col) * strideX, y: body.minY + CGFloat(row) * strideY, width: poster.width, height: poster.height + titleHeight)
  }

  func rowIndex(at point: NSPoint, top: Int, rowHeight: CGFloat, in rect: NSRect) -> Int? {
    guard rowHeight > 1, rect.contains(point) else { return nil }
    let row = top + Int((point.y - rect.minY) / rowHeight)
    guard row >= top else { return nil }
    return row
  }
}

final class IPTVBrowseOverlayHost: NSView {
  let panes = [IPTVBrowseOverlayPane(), IPTVBrowseOverlayPane()]

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

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
    guard IPTVBrowseOverlayController.shared.capturesInput else { return nil }
    return super.hitTest(point)
  }
}

final class IPTVBrowseOverlayPane: NSView {
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
    IPTVBrowseOverlayController.shared.handleHover(event)
  }

  override func mouseDown(with event: NSEvent) {
    IPTVBrowseOverlayController.shared.handleClick(in: self, event: event)
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.setFill()
    dirtyRect.fill()
    let controller = IPTVBrowseOverlayController.shared
    guard controller.screen != .hidden else { return }
    let layout = controller.makeLayout(bounds)
    if controller.screen != .menu && controller.screen != .next {
      IPTVLiveDraw.fill(bounds, radius: 0, color: NSColor(calibratedWhite: 0, alpha: 0.55))
    } else {
      IPTVLiveDraw.fill(bounds, radius: 0, color: NSColor(calibratedWhite: 0, alpha: 0.28))
    }
    switch controller.screen {
    case .hidden:
      break
    case .menu:
      drawMenu(controller, layout)
    case .grid, .search:
      drawBrowser(controller, layout)
    case .details:
      drawDetails(controller, layout)
    case .episodes:
      drawEpisodes(controller, layout)
    case .next:
      drawNext(controller, layout)
    }
  }

  private func drawMenu(_ controller: IPTVBrowseOverlayController, _ layout: IPTVBrowseLayout) {
    IPTVLiveDraw.panel(layout.panel, radius: layout.s(18))
    let title = controller.source?.name ?? "Library"
    IPTVLiveDraw.text(title, in: NSRect(x: layout.panel.minX + layout.s(22), y: layout.panel.minY + layout.s(16), width: layout.panel.width - layout.s(44), height: layout.s(28)), font: layout.font(18, .semibold), color: NSColor(calibratedWhite: 1, alpha: 0.7))
    IPTVLiveDraw.text("Library", in: NSRect(x: layout.panel.minX + layout.s(22), y: layout.panel.minY + layout.s(40), width: layout.panel.width - layout.s(44), height: layout.s(32)), font: layout.font(28, .bold), color: .white)
    for (index, name) in IPTVBrowseOverlayController.menuTitles.enumerated() {
      let rect = layout.menuRect(index)
      if index == controller.menuIndex {
        IPTVLiveDraw.fill(rect, radius: layout.s(12), color: NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.90, alpha: 0.92))
      }
      IPTVLiveDraw.text(name, in: rect.insetBy(dx: layout.s(18), dy: layout.s(14)), font: layout.font(30, .semibold), color: .white)
    }
    drawHint(controller.hintText(), layout: layout, in: NSRect(x: layout.panel.minX + layout.s(22), y: layout.panel.maxY - layout.s(32), width: layout.panel.width - layout.s(44), height: layout.s(22)))
  }

  private func drawBrowser(_ controller: IPTVBrowseOverlayController, _ layout: IPTVBrowseLayout) {
    IPTVLiveDraw.panel(layout.panel, radius: layout.s(16))
    IPTVLiveDraw.text(controller.headerTitle(), in: NSRect(x: layout.header.minX, y: layout.header.minY, width: min(layout.header.width, layout.s(460)), height: layout.header.height), font: layout.font(32, .bold), color: .white)
    let detail = controller.headerDetail()
    IPTVLiveDraw.text(detail, in: NSRect(x: layout.header.minX + layout.s(480), y: layout.header.minY + layout.s(8), width: max(0, layout.header.width - layout.s(480)), height: layout.s(32)), font: layout.font(20, .medium), color: NSColor(calibratedWhite: 1, alpha: 0.75))
    if controller.screen == .search {
      IPTVLiveDraw.fill(layout.queryBar, radius: layout.s(10), color: NSColor(calibratedWhite: 1, alpha: 0.08))
      let typed = controller.query.isEmpty ? "Search" : controller.query
      let color = controller.query.isEmpty ? NSColor(calibratedWhite: 1, alpha: 0.4) : NSColor.white
      IPTVLiveDraw.text(typed, in: layout.queryBar.insetBy(dx: layout.s(16), dy: layout.s(8)), font: layout.font(24, .medium), color: color)
    }
    drawRail(controller.railTitles(), selected: controller.railIndex, top: controller.railTop, focused: controller.zone == .rail, in: layout.rail, layout: layout)
    if layout.posters {
      drawPosters(controller, layout)
    } else {
      drawChannelRows(controller, layout)
    }
    if let placeholder = controller.placeholder() {
      IPTVLiveDraw.text(placeholder, in: layout.body.insetBy(dx: layout.s(12), dy: layout.s(12)), font: layout.font(22, .medium), color: NSColor(calibratedWhite: 1, alpha: 0.8))
    }
    drawHint(controller.hintText(), layout: layout, in: layout.hint)
  }

  private func drawRail(_ titles: [String], selected: Int, top: Int, focused: Bool, in rect: NSRect, layout: IPTVBrowseLayout) {
    guard rect.width > 20, rect.height > 20 else { return }
    var index = top
    var y = rect.minY
    while index < titles.count && y + layout.railRow <= rect.maxY + 1 {
      let row = NSRect(x: rect.minX, y: y + layout.s(4), width: rect.width, height: layout.railRow - layout.s(8))
      if index == selected {
        let color = focused
          ? NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.90, alpha: 0.92)
          : NSColor(calibratedWhite: 1, alpha: 0.16)
        IPTVLiveDraw.fill(row, radius: layout.s(10), color: color)
      }
      IPTVLiveDraw.text(titles[index], in: row.insetBy(dx: layout.s(14), dy: layout.s(8)), font: layout.font(22, .semibold), color: .white)
      y += layout.railRow
      index += 1
    }
  }

  private func drawPosters(_ controller: IPTVBrowseOverlayController, _ layout: IPTVBrowseLayout) {
    let items = controller.bodyItems()
    guard layout.body.width > 40 else { return }
    let columns = max(1, layout.columns)
    let visible = layout.visiblePosterRows * columns + columns
    var index = controller.bodyTop
    let limit = min(items.count, controller.bodyTop + visible)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: layout.body).addClip()
    while index < limit {
      let item = items[index]
      let rect = layout.posterRect(index, top: controller.bodyTop)
      guard rect.maxY > layout.body.minY && rect.minY < layout.body.maxY else { break }
      let art = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: layout.poster.height)
      if index == controller.bodyIndex && controller.zone == .body {
        let ring = art.insetBy(dx: -layout.s(4), dy: -layout.s(4))
        IPTVLiveDraw.fill(ring, radius: layout.s(12), color: NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.90, alpha: 0.95))
      }
      let image = controller.image(for: item.logoURL) ?? controller.image(for: item.backdropURL)
      if let image {
        IPTVBrowseDraw.image(image, filling: art, radius: layout.s(8))
      } else {
        IPTVLiveDraw.logo(nil, in: art, title: item.name)
      }
      let mark = controller.watchMark(for: item.id)
      if mark.fraction > 0 {
        let bar = NSRect(x: art.minX + layout.s(8), y: art.maxY - layout.s(12), width: art.width - layout.s(16), height: layout.s(6))
        IPTVLiveDraw.progress(mark.fraction, in: bar)
      }
      if let source = controller.source, IPTVLibrary.shared.isFavourite(item, source: source) {
        IPTVLiveDraw.text("★", in: NSRect(x: art.maxX - layout.s(28), y: art.minY + layout.s(6), width: layout.s(22), height: layout.s(22)), font: layout.font(18, .bold), color: NSColor(calibratedRed: 1, green: 0.82, blue: 0.3, alpha: 1), align: .center)
      }
      let titleRect = NSRect(x: rect.minX, y: art.maxY + layout.s(4), width: rect.width, height: layout.titleHeight - layout.s(4))
      IPTVLiveDraw.text(item.name, in: titleRect, font: layout.font(16, .semibold), color: .white, wrap: true)
      index += 1
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  private func drawChannelRows(_ controller: IPTVBrowseOverlayController, _ layout: IPTVBrowseLayout) {
    let items = controller.bodyItems()
    var index = controller.bodyTop
    var y = layout.body.minY
    while index < items.count && y + layout.listRow <= layout.body.maxY + 1 {
      let item = items[index]
      let row = NSRect(x: layout.body.minX, y: y + layout.s(4), width: layout.body.width, height: layout.listRow - layout.s(8))
      if index == controller.bodyIndex {
        IPTVLiveDraw.fill(row, radius: layout.s(10), color: NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.90, alpha: 0.92))
      }
      let logo = NSRect(x: row.minX + layout.s(10), y: row.minY + layout.s(12), width: layout.s(64), height: layout.s(64))
      IPTVLiveDraw.logo(controller.image(for: item.logoURL), in: logo, title: item.name)
      IPTVLiveDraw.text(item.name, in: NSRect(x: logo.maxX + layout.s(14), y: row.minY + layout.s(14), width: row.width - logo.width - layout.s(36), height: layout.s(28)), font: layout.font(22, .semibold), color: .white)
      let group = item.group.isEmpty ? "Ungrouped" : item.group
      IPTVLiveDraw.text(group, in: NSRect(x: logo.maxX + layout.s(14), y: row.minY + layout.s(46), width: row.width - logo.width - layout.s(36), height: layout.s(22)), font: layout.font(16, .regular), color: NSColor(calibratedWhite: 1, alpha: 0.7))
      y += layout.listRow
      index += 1
    }
  }

  private func drawDetails(_ controller: IPTVBrowseOverlayController, _ layout: IPTVBrowseLayout) {
    let item = controller.detailItem
    let details = controller.details
    if let backdrop = controller.image(for: details?.backdropURL ?? item?.backdropURL) {
      IPTVBrowseDraw.image(backdrop, filling: bounds, radius: 0)
    }
    IPTVLiveDraw.fill(bounds, radius: 0, color: NSColor(calibratedWhite: 0, alpha: 0.62))
    IPTVLiveDraw.panel(layout.panel, radius: layout.s(16))
    let poster = layout.detailPoster
    let posterImage = controller.image(for: details?.posterURL ?? item?.logoURL)
    if let posterImage {
      IPTVBrowseDraw.image(posterImage, filling: poster, radius: layout.s(12))
    } else {
      IPTVLiveDraw.logo(nil, in: poster, title: item?.name ?? "")
    }
    let name = details?.name ?? item?.name ?? ""
    IPTVLiveDraw.text(name, in: layout.titleRect, font: layout.font(36, .bold), color: .white)
    let facts = details?.factLine ?? ""
    IPTVLiveDraw.text(facts, in: layout.factRect, font: layout.font(20, .medium), color: NSColor(calibratedWhite: 1, alpha: 0.85))
    let plot = details?.plot ?? item?.plot ?? ""
    IPTVLiveDraw.text(plot.isEmpty ? "No plot." : plot, in: layout.plotRect, font: layout.font(20, .regular), color: NSColor(calibratedWhite: 1, alpha: 0.92), wrap: true)
    var credit = ""
    if let cast = details?.cast ?? item?.cast, !cast.isEmpty { credit = "Cast  \(cast)" }
    if let director = details?.director ?? item?.director, !director.isEmpty {
      credit = credit.isEmpty ? "Director  \(director)" : "Director  \(director)\n\(credit)"
    }
    IPTVLiveDraw.text(credit, in: layout.castRect, font: layout.font(18, .regular), color: NSColor(calibratedWhite: 1, alpha: 0.8), wrap: true)
    for (index, action) in controller.actions().enumerated() {
      guard layout.actionRects.indices.contains(index) else { continue }
      let rect = layout.actionRects[index]
      let selected = index == controller.actionIndex
      let color = selected
        ? NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.90, alpha: 0.95)
        : NSColor(calibratedWhite: 1, alpha: 0.16)
      IPTVLiveDraw.fill(rect, radius: layout.s(12), color: color)
      IPTVLiveDraw.text(controller.actionTitle(action), in: rect.insetBy(dx: layout.s(8), dy: layout.s(12)), font: layout.font(20, .semibold), color: .white, align: .center)
    }
    drawHint(controller.hintText(), layout: layout, in: NSRect(x: layout.panel.minX + layout.s(20), y: layout.panel.maxY - layout.s(28), width: layout.panel.width - layout.s(40), height: layout.s(22)))
  }

  private func drawEpisodes(_ controller: IPTVBrowseOverlayController, _ layout: IPTVBrowseLayout) {
    IPTVLiveDraw.panel(layout.panel, radius: layout.s(16))
    let name = controller.details?.name ?? controller.detailItem?.name ?? "Episodes"
    IPTVLiveDraw.text(name, in: layout.header, font: layout.font(32, .bold), color: .white)
    let seasons = controller.seasonNumbers().map { controller.seasonTitle($0) }
    drawRail(seasons, selected: controller.seasonIndex, top: controller.seasonTop, focused: controller.zone == .rail, in: layout.seasonRail, layout: layout)
    let rows = controller.episodesInSeason()
    var index = controller.episodeTop
    var y = layout.episodeBody.minY
    while index < rows.count && y + layout.listRow <= layout.episodeBody.maxY + 1 {
      let episode = rows[index]
      let row = NSRect(x: layout.episodeBody.minX, y: y + layout.s(6), width: layout.episodeBody.width, height: layout.listRow - layout.s(10))
      if index == controller.episodeIndex && controller.zone == .body {
        IPTVLiveDraw.fill(row, radius: layout.s(12), color: NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.90, alpha: 0.92))
      } else if index == controller.episodeIndex {
        IPTVLiveDraw.fill(row, radius: layout.s(12), color: NSColor(calibratedWhite: 1, alpha: 0.12))
      }
      let thumb = NSRect(x: row.minX + layout.s(10), y: row.minY + layout.s(12), width: layout.s(200), height: layout.s(112))
      let still = controller.image(for: episode.thumbnailURL) ?? controller.image(for: episode.item.logoURL)
      if let still {
        IPTVBrowseDraw.image(still, filling: thumb, radius: layout.s(8))
      } else {
        IPTVLiveDraw.logo(nil, in: thumb, title: episode.item.name)
      }
      let mark = controller.watchMark(for: episode.item.id)
      if mark.fraction > 0 {
        IPTVLiveDraw.progress(mark.fraction, in: NSRect(x: thumb.minX, y: thumb.maxY - layout.s(6), width: thumb.width, height: layout.s(6)))
      }
      let textX = thumb.maxX + layout.s(16)
      let textW = max(0, row.maxX - textX - layout.s(12))
      let title = "S\(episode.season)  E\(episode.episode)   \(episode.item.name)"
      IPTVLiveDraw.text(title, in: NSRect(x: textX, y: row.minY + layout.s(8), width: textW, height: layout.s(28)), font: layout.font(22, .semibold), color: .white)
      let meta = [episode.durationText, mark.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
      IPTVLiveDraw.text(meta, in: NSRect(x: textX, y: row.minY + layout.s(38), width: textW, height: layout.s(22)), font: layout.font(16, .medium), color: NSColor(calibratedWhite: 1, alpha: 0.75))
      let plot = episode.plot ?? episode.item.plot ?? ""
      IPTVLiveDraw.text(plot, in: NSRect(x: textX, y: row.minY + layout.s(62), width: textW, height: layout.s(48)), font: layout.font(16, .regular), color: NSColor(calibratedWhite: 1, alpha: 0.88), wrap: true)
      y += layout.listRow
      index += 1
    }
    if let placeholder = controller.placeholder(), rows.isEmpty {
      IPTVLiveDraw.text(placeholder, in: layout.episodeBody.insetBy(dx: layout.s(12), dy: layout.s(12)), font: layout.font(22, .medium), color: .white)
    }
    drawHint(controller.hintText(), layout: layout, in: layout.hint)
  }

  private func drawNext(_ controller: IPTVBrowseOverlayController, _ layout: IPTVBrowseLayout) {
    IPTVLiveDraw.panel(layout.nextCard, radius: layout.s(18))
    guard let episode = controller.promptedEpisode() else { return }
    IPTVLiveDraw.text("Next episode", in: NSRect(x: layout.nextCard.minX + layout.s(28), y: layout.nextCard.minY + layout.s(22), width: layout.nextCard.width - layout.s(56), height: layout.s(28)), font: layout.font(18, .semibold), color: NSColor(calibratedWhite: 1, alpha: 0.7))
    let title = "S\(episode.season)  E\(episode.episode)   \(episode.item.name)"
    IPTVLiveDraw.text(title, in: NSRect(x: layout.nextCard.minX + layout.s(28), y: layout.nextCard.minY + layout.s(54), width: layout.nextCard.width - layout.s(240), height: layout.s(36)), font: layout.font(28, .bold), color: .white)
    let plot = episode.plot ?? episode.item.plot ?? ""
    IPTVLiveDraw.text(plot, in: NSRect(x: layout.nextCard.minX + layout.s(28), y: layout.nextCard.minY + layout.s(100), width: layout.nextCard.width - layout.s(240), height: layout.s(90)), font: layout.font(18, .regular), color: NSColor(calibratedWhite: 1, alpha: 0.9), wrap: true)
    let thumb = NSRect(x: layout.nextCard.maxX - layout.s(196), y: layout.nextCard.minY + layout.s(48), width: layout.s(168), height: layout.s(94))
    let still = controller.image(for: episode.thumbnailURL) ?? controller.image(for: episode.item.logoURL)
    if let still {
      IPTVBrowseDraw.image(still, filling: thumb, radius: layout.s(8))
    } else {
      IPTVLiveDraw.logo(nil, in: thumb, title: episode.item.name)
    }
    let playTitle = "Play \(controller.nextSeconds)s"
    drawChoice(playTitle, rect: layout.nextPlay, selected: controller.nextAction == 0, layout: layout)
    drawChoice("Cancel", rect: layout.nextCancel, selected: controller.nextAction == 1, layout: layout)
    drawHint(controller.hintText(), layout: layout, in: NSRect(x: layout.nextCard.minX + layout.s(28), y: layout.nextPlay.minY - layout.s(28), width: layout.nextCard.width - layout.s(56), height: layout.s(22)))
  }

  private func drawChoice(_ title: String, rect: NSRect, selected: Bool, layout: IPTVBrowseLayout) {
    let color = selected
      ? NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.90, alpha: 0.95)
      : NSColor(calibratedWhite: 1, alpha: 0.16)
    IPTVLiveDraw.fill(rect, radius: layout.s(12), color: color)
    IPTVLiveDraw.text(title, in: rect.insetBy(dx: layout.s(8), dy: layout.s(12)), font: layout.font(20, .semibold), color: .white, align: .center)
  }

  private func drawHint(_ text: String, layout: IPTVBrowseLayout, in rect: NSRect) {
    let color = text == IPTVBrowseOverlayController.shared.hintText() && IPTVBrowseOverlayController.shared.status != nil
      ? NSColor(calibratedRed: 1, green: 0.78, blue: 0.45, alpha: 1)
      : NSColor(calibratedWhite: 1, alpha: 0.7)
    IPTVLiveDraw.text(text, in: rect, font: layout.font(16, .medium), color: color)
  }
}

enum IPTVBrowseDraw {
  static func image(_ image: NSImage, filling rect: NSRect, radius: CGFloat) {
    guard rect.width > 1, rect.height > 1, image.size.width > 0, image.size.height > 0 else { return }
    let scale = max(rect.width / image.size.width, rect.height / image.size.height)
    let width = image.size.width * scale
    let height = image.size.height * scale
    let dest = NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
  }
}
