//
//  IPTVWindowController.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  IPTV browser. Live channels are an XMLTV grid (categories, logos, now/next,
//  times across). Clicking a channel or a programme plays through PlayerCore,
//  so Immersive 3D and Play on Glasses apply the same way as any other file.
//  This window was not opened or exercised on the machine that added it.

import Cocoa
import CryptoKit
import UniformTypeIdentifiers

final class IPTVWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
  static let shared = IPTVWindowController()
  private static var didInstallMenu = false

  private let library = IPTVLibrary.shared
  private let sourceTable = NSTableView()
  private let groupTable = NSTableView()
  private let channelTable = NSTableView()
  private let searchField = NSSearchField()
  private let sectionControl = NSSegmentedControl(labels: ["Live", "Movies", "Series"], trackingMode: .selectOne, target: nil, action: nil)
  private let backButton = NSButton(title: "Back", target: nil, action: nil)
  private let statusField = NSTextField(labelWithString: "")
  private let spinner = NSProgressIndicator()
  private let emptyField = NSTextField(wrappingLabelWithString: "Add an M3U playlist or an Xtream Codes login.")
  private let guideBrowser = IPTVGuideBrowser()
  private let posterBrowser = IPTVPosterBrowser()
  private let detailView = IPTVDetailView()
  private var channelScroll: NSScrollView?
  private var detailItem: IPTVItem?
  private var detailSeriesID: String?
  private var detailSeriesTitle: String?
  private var scrollGuideToNow = false

  private var groupRows: [GroupRow] = [.all, .favourites]
  private var rows: [IPTVItem] = []
  private var catalog: IPTVCatalog?
  private var guide = IPTVEPG()
  private var currentSourceID: UUID?
  private var groupFilter: GroupRow = .all
  private var drillSeries: IPTVItem?
  private var episodes: [IPTVItem] = []
  private var query = ""
  private var loadGeneration = 0
  private var suppressSelection = false
  private var guideTimer: Timer?

  private enum GroupRow: Equatable {
    case all
    case favourites
    case continueWatching
    case named(String)

    var title: String {
      switch self {
      case .all: return "All"
      case .favourites: return "Favourites"
      case .continueWatching: return "Continue watching"
      case .named(let name): return name
      }
    }
  }

  private enum Section: Int {
    case live
    case vod
    case series
  }

  static func installMenu(in menu: NSMenu?, after sibling: NSMenuItem?) {
    guard let menu, !didInstallMenu else { return }
    didInstallMenu = true
    let item = NSMenuItem(title: "IPTV…", action: #selector(showIPTV(_:)), keyEquivalent: "i")
    item.keyEquivalentModifierMask = [.command, .option]
    item.target = shared
    if let sibling {
      let index = menu.index(of: sibling)
      menu.insertItem(item, at: index == -1 ? menu.numberOfItems : index + 1)
    } else {
      menu.addItem(item)
    }
  }

  private init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "IPTV"
    window.minSize = NSSize(width: 920, height: 520)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    window.center()
    build()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc func showIPTV(_ sender: Any?) {
    showWindow(sender)
    window?.makeKeyAndOrderFront(sender)
    NSApp.activate(ignoringOtherApps: true)
    startGuideTimer()
    sourceTable.reloadData()
    if currentSourceID == nil, let first = library.sources.first {
      show(source: first, refresh: true)
    }
  }

  func windowWillClose(_ notification: Notification) {
    guideTimer?.invalidate()
    guideTimer = nil
  }

  // MARK: - Layout

  private func build() {
    guard let content = window?.contentView else { return }
    let add = button("Add Source", #selector(addSource(_:)))
    let edit = button("Edit", #selector(editSource(_:)))
    let remove = button("Remove", #selector(removeSource(_:)))
    let refresh = button("Refresh", #selector(refreshClicked(_:)))
    sectionControl.target = self
    sectionControl.action = #selector(sectionChanged(_:))
    sectionControl.selectedSegment = 0
    backButton.target = self
    backButton.action = #selector(backFromSeries(_:))
    backButton.isHidden = true
    searchField.placeholderString = "Search channels and programmes"
    searchField.target = self
    searchField.action = #selector(searchChanged(_:))
    searchField.sendsSearchStringImmediately = true
    searchField.sendsWholeSearchString = true
    searchField.widthAnchor.constraint(equalToConstant: 260).isActive = true

    let bar = NSStackView(views: [add, edit, remove, refresh, sectionControl, backButton, searchField])
    bar.orientation = .horizontal
    bar.alignment = .centerY
    bar.spacing = 8
    bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    bar.translatesAutoresizingMaskIntoConstraints = false
    searchField.setContentHuggingPriority(.required, for: .horizontal)

    configure(sourceTable, columns: [("name", "Sources", 180)])
    configure(groupTable, columns: [("name", "Categories", 170)])
    configure(channelTable, columns: [
      ("fav", "", 36),
      ("logo", "", 40),
      ("name", "Name", 240),
      ("now", "Now", 160),
      ("next", "Next", 160)
    ])
    channelTable.doubleAction = #selector(openSelection(_:))
    channelTable.target = self
    channelTable.rowHeight = 32
    if #available(macOS 11.0, *) {
      sourceTable.style = .sourceList
      groupTable.style = .sourceList
    }

    let channels = scroll(channelTable)
    channelScroll = channels
    channels.translatesAutoresizingMaskIntoConstraints = false
    guideBrowser.translatesAutoresizingMaskIntoConstraints = false
    guideBrowser.onPlay = { [weak self] item, action in
      self?.handleGuide(item, action: action)
    }
    guideBrowser.onToggleFavourite = { [weak self] item in
      self?.toggleFavourite(item)
    }
    guideBrowser.isFavourite = { [weak self] item in
      guard let self, let source = self.currentSource else { return false }
      return self.library.isFavourite(item, source: source)
    }
    posterBrowser.translatesAutoresizingMaskIntoConstraints = false
    posterBrowser.onSelect = { [weak self] item in
      self?.openDetail(item)
    }
    posterBrowser.progressFor = { [weak self] item in
      guard let self, let source = self.currentSource else { return nil }
      return self.library.watchProgress(for: item.id, source: source)
    }
    detailView.translatesAutoresizingMaskIntoConstraints = false
    detailView.progressFor = { [weak self] itemID in
      guard let self, let source = self.currentSource else { return nil }
      return self.library.watchProgress(for: itemID, source: source)
    }
    detailView.onPlay = { [weak self] item, resume in
      self?.playTitle(item, resume: resume)
    }
    detailView.onTrailer = { url in
      NSWorkspace.shared.open(url)
    }
    let detail = NSView()
    detail.addSubview(guideBrowser)
    detail.addSubview(posterBrowser)
    detail.addSubview(detailView)
    detail.addSubview(channels)
    NSLayoutConstraint.activate([
      guideBrowser.topAnchor.constraint(equalTo: detail.topAnchor),
      guideBrowser.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
      guideBrowser.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
      guideBrowser.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
      posterBrowser.topAnchor.constraint(equalTo: detail.topAnchor),
      posterBrowser.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
      posterBrowser.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
      posterBrowser.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
      detailView.topAnchor.constraint(equalTo: detail.topAnchor),
      detailView.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
      detailView.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
      detailView.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
      channels.topAnchor.constraint(equalTo: detail.topAnchor),
      channels.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
      channels.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
      channels.bottomAnchor.constraint(equalTo: detail.bottomAnchor)
    ])

    let split = NSSplitView()
    split.isVertical = true
    split.dividerStyle = .thin
    split.translatesAutoresizingMaskIntoConstraints = false
    split.addArrangedSubview(scroll(sourceTable))
    split.addArrangedSubview(scroll(groupTable))
    split.addArrangedSubview(detail)

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.isDisplayedWhenStopped = false
    statusField.font = .systemFont(ofSize: 12)
    statusField.textColor = .secondaryLabelColor
    statusField.translatesAutoresizingMaskIntoConstraints = false
    emptyField.font = .systemFont(ofSize: 13)
    emptyField.textColor = .secondaryLabelColor
    emptyField.alignment = .center
    emptyField.translatesAutoresizingMaskIntoConstraints = false
    emptyField.isHidden = false

    content.addSubview(bar)
    content.addSubview(split)
    content.addSubview(statusField)
    content.addSubview(spinner)
    content.addSubview(emptyField)

    let guide = content.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      bar.topAnchor.constraint(equalTo: guide.topAnchor),
      bar.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
      split.topAnchor.constraint(equalTo: bar.bottomAnchor),
      split.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      split.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
      statusField.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 6),
      statusField.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
      statusField.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
      spinner.centerYAnchor.constraint(equalTo: statusField.centerYAnchor),
      spinner.leadingAnchor.constraint(equalTo: statusField.trailingAnchor, constant: 8),
      emptyField.centerXAnchor.constraint(equalTo: content.centerXAnchor, constant: 90),
      emptyField.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      emptyField.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
    ])
    split.setPosition(200, ofDividerAt: 0)
    split.setPosition(380, ofDividerAt: 1)
    NotificationCenter.default.addObserver(self, selector: #selector(progressChanged(_:)), name: .iptvWatchProgressDidChange, object: nil)
    applyFilter()
  }

  @objc private func progressChanged(_ notification: Notification) {
    guard window?.isVisible == true else { return }
    posterBrowser.refreshVisibleProgress()
    if detailItem != nil {
      detailView.refreshProgress()
    }
  }

  private func startGuideTimer() {
    guard guideTimer == nil else { return }
    guideTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      guard let self, self.window?.isVisible == true else { return }
      self.channelTable.reloadData()
      self.guideBrowser.tick()
    }
  }

  private func button(_ title: String, _ action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    return button
  }

  private func scroll(_ table: NSTableView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = table
    return scroll
  }

  private func configure(_ table: NSTableView, columns: [(String, String, CGFloat)]) {
    table.dataSource = self
    table.delegate = self
    table.allowsEmptySelection = false
    table.usesAlternatingRowBackgroundColors = true
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    for (id, title, width) in columns {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.width = width
      column.minWidth = id == "name" ? 80 : width
      if id == "fav" || id == "logo" {
        column.resizingMask = []
      }
      table.addTableColumn(column)
    }
  }

  // MARK: - Sources

  private var currentSource: IPTVSource? {
    library.sources.first { $0.id == currentSourceID }
  }

  private func show(source: IPTVSource, refresh: Bool) {
    scrollGuideToNow = true
    currentSourceID = source.id
    drillSeries = nil
    episodes = []
    detailItem = nil
    detailSeriesID = nil
    detailSeriesTitle = nil
    guide = IPTVEPG()
    catalog = library.cache(for: source)
    sectionControl.isHidden = source.kind != .xtream
    backButton.isHidden = true
    if let row = library.sources.firstIndex(where: { $0.id == source.id }) {
      suppressSelection = true
      sourceTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      suppressSelection = false
    }
    applyFilter()
    if refresh || catalog == nil {
      refreshCatalog()
    } else {
      loadGuide(library.guideURL(for: source, catalog: catalog), generation: loadGeneration)
    }
  }

  @objc private func addSource(_ sender: Any?) {
    presentEditor(nil)
  }

  @objc private func editSource(_ sender: Any?) {
    guard let source = currentSource else { return }
    presentEditor(source)
  }

  @objc private func removeSource(_ sender: Any?) {
    guard let source = currentSource, let window else { return }
    let alert = NSAlert()
    alert.messageText = "Remove \(source.name)?"
    alert.informativeText = "The saved password is deleted from the Keychain. Downloaded channel lists, title details, and watch progress for this source are deleted too."
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      self.library.delete(source)
      self.currentSourceID = nil
      self.catalog = nil
      self.rows = []
      self.sourceTable.reloadData()
      self.applyFilter()
      if let first = self.library.sources.first {
        self.show(source: first, refresh: false)
      }
    }
  }

  @objc private func refreshClicked(_ sender: Any?) {
    refreshCatalog()
  }

  @objc private func sectionChanged(_ sender: Any?) {
    groupFilter = .all
    drillSeries = nil
    episodes = []
    detailItem = nil
    detailSeriesID = nil
    detailSeriesTitle = nil
    backButton.isHidden = true
    switch Section(rawValue: sectionControl.selectedSegment) ?? .live {
    case .live: searchField.placeholderString = "Search channels and programmes"
    case .vod: searchField.placeholderString = "Search movies"
    case .series: searchField.placeholderString = "Search series"
    }
    applyFilter()
  }

  @objc private func backFromSeries(_ sender: Any?) {
    drillSeries = nil
    episodes = []
    detailItem = nil
    detailSeriesID = nil
    detailSeriesTitle = nil
    backButton.isHidden = true
    sectionControl.isHidden = currentSource?.kind != .xtream
    applyFilter()
  }

  @objc private func searchChanged(_ sender: Any?) {
    query = IPTVText.normalize(searchField.stringValue)
    applyFilter()
  }

  private func refreshCatalog() {
    guard let source = currentSource else {
      setStatus("No source selected.")
      return
    }
    loadGeneration += 1
    let generation = loadGeneration
    setStatus("Loading \(source.name)…", busy: true)
    library.loadCatalog(for: source) { [weak self] result in
      guard let self, generation == self.loadGeneration else { return }
      switch result {
      case .failure(let error):
        self.setStatus(error.localizedDescription)
      case .success(let catalog):
        var stored = catalog
        if source.kind == .xtream && source.epgURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          stored.epgURL = nil
        }
        self.catalog = stored
        self.library.store(cache: stored, for: source)
        self.applyFilter()
        self.setStatus("\(stored.items.count) entries")
        self.loadGuide(self.library.guideURL(for: source, catalog: stored), generation: generation)
      }
    }
  }

  private func loadGuide(_ raw: String?, generation: Int) {
    guard let raw, !raw.isEmpty, let url = URL(string: raw) else { return }
    setStatus("Loading programme guide…", busy: true)
    library.loadEPG(url: url) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, generation == self.loadGeneration else { return }
        switch result {
        case .failure(let error):
          self.setStatus("Channels are ready. Programme guide failed: \(error.localizedDescription)")
        case .success(let epg):
          self.guide = epg
          self.scrollGuideToNow = true
          self.applyFilter()
          let listings = epg.programmeCount
          if listings == 0 {
            self.setStatus("\(self.statusCount()). The guide has no programmes in this time window.")
          } else {
            self.setStatus("\(self.statusCount()) · \(listings) programmes")
          }
        }
      }
    }
  }

  // MARK: - Filter

  private func applyFilter() {
    let source = currentSource
    let pool = drillSeries == nil ? (catalog?.items ?? []) : episodes
    let section = Section(rawValue: sectionControl.selectedSegment) ?? .live
    let limitKind = source?.kind == .xtream && drillSeries == nil
    var names = Set<String>()
    let inSection = pool.filter { item in
      if limitKind {
        switch section {
        case .live: if item.kind != .live { return false }
        case .vod: if item.kind != .vod { return false }
        case .series: if item.kind != .series { return false }
        }
      }
      names.insert(Self.groupName(item))
      return true
    }
    let watching = continueItems(in: section, source: source)
    var groups: [GroupRow] = [.all, .favourites]
    if !watching.isEmpty { groups.append(.continueWatching) }
    groups += names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { .named($0) }
    groupRows = groups
    if case .named(let name) = groupFilter, !names.contains(name) {
      groupFilter = .all
    }
    if groupFilter == .continueWatching && watching.isEmpty {
      groupFilter = .all
    }
    if groupFilter == .continueWatching {
      rows = watching.filter { query.isEmpty || $0.matchesText(query) }
    } else {
      rows = inSection.filter { item in
        switch groupFilter {
        case .all, .continueWatching:
          break
        case .favourites:
          guard let source, library.isFavourite(item, source: source) else { return false }
        case .named(let name):
          if Self.groupName(item) != name { return false }
        }
        if query.isEmpty { return true }
        if showsGuide { return guide.matches(item, query: query) }
        return item.matchesText(query)
      }
    }
    let jump = scrollGuideToNow
    scrollGuideToNow = false
    let showingDetail = detailItem != nil
    let posters = showsPosters && !rows.isEmpty && !showingDetail
    guideBrowser.isHidden = showingDetail || !(showsGuide && !rows.isEmpty)
    posterBrowser.isHidden = !posters
    detailView.isHidden = !showingDetail
    channelScroll?.isHidden = showingDetail || posters || showsGuide || rows.isEmpty
    guideBrowser.update(items: showsGuide && !showingDetail ? rows : [], guide: guide, query: query, scrollToNow: jump && showsGuide && !showingDetail)
    if posters {
      posterBrowser.update(
        library: rows,
        continueWatching: groupFilter == .all ? watching : [],
        sectionTitle: groupFilter.title,
        showContinueRow: groupFilter == .all
      )
    }
    suppressSelection = true
    groupTable.reloadData()
    if let index = groupRows.firstIndex(of: groupFilter) {
      groupTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
    suppressSelection = false
    channelTable.reloadData()
    if showingDetail {
      emptyField.isHidden = true
    } else if library.sources.isEmpty {
      emptyField.stringValue = "Add an M3U playlist or an Xtream Codes login."
      emptyField.isHidden = false
    } else if rows.isEmpty && !spinner.isAnimating {
      emptyField.stringValue = query.isEmpty ? "Nothing matches." : "Nothing matches that search."
      if query.isEmpty {
        emptyField.stringValue = showsPosters ? "No titles in this category." : "No channels in this category."
      }
      emptyField.isHidden = false
    } else {
      emptyField.isHidden = true
    }
    if !spinner.isAnimating {
      statusField.stringValue = statusCount()
    }
  }

  private var showsGuide: Bool {
    if drillSeries != nil || detailItem != nil || currentSource == nil { return false }
    if currentSource?.kind == .xtream {
      return (Section(rawValue: sectionControl.selectedSegment) ?? .live) == .live
    }
    return true
  }

  private var showsPosters: Bool {
    guard detailItem == nil, drillSeries == nil, currentSource?.kind == .xtream else { return false }
    let section = Section(rawValue: sectionControl.selectedSegment) ?? .live
    return section == .vod || section == .series
  }

  private func continueItems(in section: Section, source: IPTVSource?) -> [IPTVItem] {
    guard let source, source.kind == .xtream else { return [] }
    switch section {
    case .vod: return library.continueWatching(source: source, kind: .vod)
    case .series: return library.continueWatching(source: source, kind: .episode)
    case .live: return []
    }
  }

  private static func groupName(_ item: IPTVItem) -> String {
    item.group.isEmpty ? "Ungrouped" : item.group
  }

  private func statusCount() -> String {
    if drillSeries != nil { return "\(rows.count) episodes" }
    let section = Section(rawValue: sectionControl.selectedSegment) ?? .live
    if currentSource?.kind == .xtream {
      switch section {
      case .vod: return "\(rows.count) movies"
      case .series: return "\(rows.count) series"
      case .live: break
      }
    }
    return "\(rows.count) channels"
  }

  private func setStatus(_ text: String, busy: Bool = false) {
    statusField.stringValue = text
    if busy {
      spinner.startAnimation(nil)
    } else {
      spinner.stopAnimation(nil)
    }
    emptyField.isHidden = !rows.isEmpty || busy
  }

  // MARK: - Playback

  @objc private func openSelection(_ sender: Any?) {
    let row = channelTable.clickedRow
    guard rows.indices.contains(row) else { return }
    play(rows[row])
  }

  private func handleGuide(_ item: IPTVItem, action: IPTVGuideAction) {
    switch action {
    case .live:
      play(item)
    case .fromStart(let programme, let restart):
      playFromStart(item, programme: programme, restart: restart)
    case .notice(let message):
      setStatus(message)
    }
  }

  private func play(_ item: IPTVItem, programmeTitle: String? = nil) {
    guard let source = currentSource else { return }
    if item.kind == .series || item.kind == .vod {
      openDetail(item)
      return
    }
    guard let url = library.playbackURL(for: item, source: source) else {
      setStatus("No stream URL. If this is an Xtream login, edit it and enter the password again.")
      return
    }
    let status: String
    if let programmeTitle, !programmeTitle.isEmpty {
      status = "Playing \(item.name) — \(programmeTitle)"
    } else {
      status = "Playing \(item.name)"
    }
    openStream(url, item: item, source: source, historyTitle: item.name, status: status)
  }

  /// Timeshift from the programme start. The password stays in the Keychain; history still gets the iptv:// stand-in.
  private func playFromStart(_ item: IPTVItem, programme: IPTVProgramme, restart: Bool) {
    guard let source = currentSource else { return }
    guard let url = library.catchupURL(for: item, source: source, programme: programme) else {
      if item.catchup?.mode == "xtream", library.password(for: source) == nil {
        setStatus("No catch-up address. If this is an Xtream login, edit it and enter the password again.")
      } else if programme.catchupID?.lowercased().hasPrefix("plugin://") == true {
        setStatus("Catch-up plugin addresses are not supported.")
      } else {
        setStatus("No catch-up address for \(item.name).")
      }
      return
    }
    let label = "\(item.name) — \(programme.title)"
    let status = restart ? "Restarting \(label)" : "Playing \(label) from the start"
    openStream(url, item: item, source: source, historyTitle: label, status: status)
  }

  private func openStream(_ url: URL, item: IPTVItem, source: IPTVSource, historyTitle: String, status: String, resumeAt: Double? = nil, seriesItemID: String? = nil, seriesTitle: String? = nil) {
    library.registerPlayback(stream: url, source: source, item: item, title: historyTitle, resumeAt: resumeAt, seriesItemID: seriesItemID, seriesTitle: seriesTitle)
    let player = PlayerCore.activeOrNew
    player.openURL(url)
    player.mainWindow.window?.makeKeyAndOrderFront(nil)
    setStatus(status)
  }

  @objc private func toggleFavourite(_ sender: NSButton) {
    let row = sender.tag
    guard rows.indices.contains(row) else { return }
    toggleFavourite(rows[row])
  }

  private func toggleFavourite(_ item: IPTVItem) {
    guard let source = currentSource else { return }
    library.toggleFavourite(item, source: source)
    applyFilter()
  }

  // MARK: - Tables

  func numberOfRows(in tableView: NSTableView) -> Int {
    if tableView == sourceTable { return library.sources.count }
    if tableView == groupTable { return groupRows.count }
    return rows.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let tableColumn else { return nil }
    let id = tableColumn.identifier.rawValue
    if tableView == sourceTable {
      guard library.sources.indices.contains(row) else { return nil }
      return textCell(tableView, identifier: tableColumn.identifier, text: library.sources[row].name)
    }
    if tableView == groupTable {
      guard groupRows.indices.contains(row) else { return nil }
      return textCell(tableView, identifier: tableColumn.identifier, text: groupRows[row].title)
    }
    guard rows.indices.contains(row) else { return nil }
    let item = rows[row]
    switch id {
    case "fav":
      return favouriteCell(tableView, row: row, item: item)
    case "logo":
      return logoCell(tableView, item: item)
    case "now":
      return textCell(tableView, identifier: tableColumn.identifier, text: programmeTitle(item, next: false), secondary: true)
    case "next":
      return textCell(tableView, identifier: tableColumn.identifier, text: programmeTitle(item, next: true), secondary: true)
    default:
      return textCell(tableView, identifier: tableColumn.identifier, text: item.name)
    }
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !suppressSelection, let table = notification.object as? NSTableView else { return }
    if table == sourceTable {
      let row = sourceTable.selectedRow
      guard library.sources.indices.contains(row) else { return }
      let source = library.sources[row]
      if source.id != currentSourceID {
        show(source: source, refresh: false)
        if catalog == nil { refreshCatalog() }
      }
    } else if table == groupTable {
      let row = groupTable.selectedRow
      guard groupRows.indices.contains(row) else { return }
      groupFilter = groupRows[row]
      detailItem = nil
      detailSeriesID = nil
      detailSeriesTitle = nil
      backButton.isHidden = true
      applyFilter()
    }
  }

  private func openDetail(_ item: IPTVItem) {
    guard let source = currentSource else { return }
    var target = item
    detailSeriesID = nil
    detailSeriesTitle = nil
    if item.kind == .episode, let identity = library.seriesIdentity(for: item.id, source: source) {
      detailSeriesID = identity.id
      detailSeriesTitle = identity.title
      if let series = catalog?.items.first(where: { $0.id == identity.id }) {
        target = series
        detailSeriesID = series.id
        detailSeriesTitle = series.name
      }
    } else if item.kind == .series {
      detailSeriesID = item.id
      detailSeriesTitle = item.name
    }
    detailItem = target
    backButton.isHidden = false
    applyFilter()
    detailView.showLoading(target)
    loadGeneration += 1
    let generation = loadGeneration
    setStatus("Loading details for \(target.name)…", busy: true)
    library.loadTitleDetails(for: target, source: source) { [weak self] result in
      guard let self, generation == self.loadGeneration, self.detailItem?.id == target.id else { return }
      switch result {
      case .failure(let error):
        self.detailView.showError(error.localizedDescription, item: target)
        self.setStatus(error.localizedDescription)
      case .success(let payload):
        self.detailView.show(details: payload.0, item: target, note: payload.1)
        self.setStatus(target.name)
      }
    }
  }

  private func playTitle(_ item: IPTVItem, resume: Bool) {
    guard let source = currentSource else { return }
    if item.kind == .series {
      openDetail(item)
      return
    }
    let record = library.watchProgress(for: item.id, source: source)
    let seconds = resume ? record.flatMap { IPTVWatch.resumeSeconds($0) } : nil
    guard let url = library.playbackURL(for: item, source: source) else {
      setStatus("No stream URL. If this is an Xtream login, edit it and enter the password again.")
      return
    }
    if !resume {
      library.forgetProgress(itemID: item.id, source: source)
    }
    let seriesID = item.kind == .episode ? detailSeriesID : nil
    let seriesTitle = item.kind == .episode ? detailSeriesTitle : nil
    let status = resume ? "Resuming \(item.name)" : "Playing \(item.name)"
    openStream(url, item: item, source: source, historyTitle: item.name, status: status, resumeAt: seconds, seriesItemID: seriesID, seriesTitle: seriesTitle)
  }

  private func programmeTitle(_ item: IPTVItem, next: Bool) -> String {
    let pair = guide.nowAndNext(for: item, at: Date())
    return (next ? pair.next : pair.now)?.title ?? ""
  }

  private func textCell(_ table: NSTableView, identifier: NSUserInterfaceItemIdentifier, text: String, secondary: Bool = false) -> NSView {
    let cell: NSTableCellView
    if let existing = table.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
      cell = existing
    } else {
      cell = NSTableCellView()
      cell.identifier = identifier
      let field = NSTextField(labelWithString: "")
      field.lineBreakMode = .byTruncatingTail
      field.translatesAutoresizingMaskIntoConstraints = false
      field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      cell.addSubview(field)
      cell.textField = field
      NSLayoutConstraint.activate([
        field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
        field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
      ])
    }
    cell.textField?.stringValue = text
    cell.textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
    cell.textField?.font = .systemFont(ofSize: secondary ? 12 : 13)
    return cell
  }

  private func favouriteCell(_ table: NSTableView, row: Int, item: IPTVItem) -> NSView {
    let identifier = NSUserInterfaceItemIdentifier("fav")
    let button: NSButton
    if let existing = table.makeView(withIdentifier: identifier, owner: self) as? NSButton {
      button = existing
    } else {
      button = NSButton()
      button.identifier = identifier
      button.isBordered = false
      button.target = self
      button.action = #selector(toggleFavourite(_:))
    }
    let on = currentSource.map { library.isFavourite(item, source: $0) } ?? false
    button.tag = row
    button.image = NSImage(systemSymbolName: on ? "star.fill" : "star", accessibilityDescription: "Favourite")
    button.contentTintColor = on ? .systemYellow : .secondaryLabelColor
    return button
  }

  private func logoCell(_ table: NSTableView, item: IPTVItem) -> NSView {
    let identifier = NSUserInterfaceItemIdentifier("logo")
    let imageView: NSImageView
    if let existing = table.makeView(withIdentifier: identifier, owner: self) as? NSImageView {
      imageView = existing
    } else {
      imageView = NSImageView()
      imageView.identifier = identifier
      imageView.imageScaling = .scaleProportionallyUpOrDown
      imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    }
    let placeholder = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
    imageView.image = placeholder
    imageView.toolTip = nil
    if let raw = item.logoURL, let url = URL(string: raw) {
      imageView.toolTip = url.absoluteString
      IPTVImageLoader.shared.load(url) { [weak imageView] image in
        guard imageView?.toolTip == url.absoluteString else { return }
        imageView?.image = image ?? placeholder
      }
    }
    return imageView
  }

  // MARK: - Editor

  private func presentEditor(_ existing: IPTVSource?) {
    guard let window else { return }
    let sheet = IPTVSourceSheet(source: existing, passwordHint: existing?.kind == .xtream)
    window.beginSheet(sheet.window) { [weak self] response in
      guard response == .OK, let self, let drafted = sheet.result else { return }
      do {
        try self.library.upsert(drafted.source, password: drafted.password)
        self.sourceTable.reloadData()
        self.show(source: drafted.source, refresh: true)
      } catch {
        self.setStatus(error.localizedDescription)
      }
    }
  }
}

final class IPTVImageLoader {
  static let shared = IPTVImageLoader()
  private let cache = NSCache<NSURL, NSImage>()
  private var waiters: [String: [(NSImage?) -> Void]] = [:]
  private let lock = NSLock()
  private let session: URLSession

  private init() {
    cache.countLimit = 300
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 20
    config.httpAdditionalHeaders = ["User-Agent": "IINA IPTV"]
    session = URLSession(configuration: config)
  }

  func cachedImage(for url: URL) -> NSImage? {
    cache.object(forKey: url as NSURL)
  }

  func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
    let key = url as NSURL
    if let image = cache.object(forKey: key) {
      completion(image)
      return
    }
    let token = url.absoluteString
    lock.lock()
    if waiters[token] != nil {
      waiters[token]?.append(completion)
      lock.unlock()
      return
    }
    waiters[token] = [completion]
    lock.unlock()
    let file = Self.file(for: url)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      if let data = try? Data(contentsOf: file), !data.isEmpty {
        self?.finish(token, key: key, data: data, file: file, fromDisk: true)
        return
      }
      self?.fetch(url, token: token, key: key, file: file)
    }
  }

  private func fetch(_ url: URL, token: String, key: NSURL, file: URL) {
    session.dataTask(with: url) { [weak self] data, _, _ in
      self?.finish(token, key: key, data: data, file: file, fromDisk: false)
    }.resume()
  }

  /// NSImage is built on the main queue. A file is kept only when that image is valid.
  private func finish(_ token: String, key: NSURL, data: Data?, file: URL, fromDisk: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let image = data.flatMap { NSImage(data: $0) }
      if let image {
        if !fromDisk, let data, !data.isEmpty {
          try? data.write(to: file, options: .atomic)
        }
        self.cache.setObject(image, forKey: key)
        self.deliver(token, image)
        return
      }
      if fromDisk {
        try? FileManager.default.removeItem(at: file)
        self.fetch(key as URL, token: token, key: key, file: file)
        return
      }
      self.deliver(token, nil)
    }
  }

  private func deliver(_ token: String, _ image: NSImage?) {
    lock.lock()
    let callbacks = waiters.removeValue(forKey: token) ?? []
    lock.unlock()
    callbacks.forEach { $0(image) }
  }

  private static func file(for url: URL) -> URL {
    let folder = Utility.appSupportDirUrl.appendingPathComponent("IPTV/Artwork", isDirectory: true)
    Utility.createDirIfNotExist(url: folder)
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
    let name = digest.map { String(format: "%02x", $0) }.joined()
    return folder.appendingPathComponent(name + ".img")
  }
}

private final class IPTVSourceSheet: NSObject {
  let window: NSWindow
  private let nameField = NSTextField()
  private let kindPopup = NSPopUpButton()
  private let locationField = NSTextField()
  private let epgField = NSTextField()
  private let serverField = NSTextField()
  private let usernameField = NSTextField()
  private let passwordField = NSSecureTextField()
  private let m3uRows: [NSView]
  private let xtreamRows: [NSView]
  private let existing: IPTVSource?
  var result: (source: IPTVSource, password: String?)?

  init(source: IPTVSource?, passwordHint: Bool) {
    existing = source
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.title = source == nil ? "Add IPTV Source" : "Edit IPTV Source"
    let content = window.contentView!
    kindPopup.addItems(withTitles: ["M3U / M3U8 playlist", "Xtream Codes"])
    kindPopup.target = nil
    nameField.placeholderString = "Name"
    locationField.placeholderString = "https://example.com/playlist.m3u"
    epgField.placeholderString = "EPG URL (optional)"
    serverField.placeholderString = "http://host:port"
    usernameField.placeholderString = "Username"
    passwordField.placeholderString = passwordHint ? "Leave blank to keep the saved password" : "Password"
    if let source {
      nameField.stringValue = source.name
      kindPopup.selectItem(at: source.kind == .xtream ? 1 : 0)
      locationField.stringValue = source.location
      epgField.stringValue = source.epgURL
      serverField.stringValue = source.server
      usernameField.stringValue = source.username
    }
    let choose = NSButton(title: "Choose File…", target: nil, action: nil)
    choose.bezelStyle = .rounded
    let save = NSButton(title: "Save", target: nil, action: nil)
    save.bezelStyle = .rounded
    save.keyEquivalent = "\r"
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    cancel.bezelStyle = .rounded
    cancel.keyEquivalent = "\u{1b}"

    func row(_ label: String, _ field: NSView) -> NSStackView {
      let title = NSTextField(labelWithString: label)
      title.font = .systemFont(ofSize: 12)
      title.widthAnchor.constraint(equalToConstant: 92).isActive = true
      let stack = NSStackView(views: [title, field])
      stack.orientation = .horizontal
      stack.alignment = .centerY
      field.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
      return stack
    }
    let locationRow = row("Playlist", locationField)
    let fileRow = NSStackView(views: [choose])
    fileRow.orientation = .horizontal
    let epgRow = row("EPG", epgField)
    let serverRow = row("Server", serverField)
    let userRow = row("Username", usernameField)
    let passRow = row("Password", passwordField)
    m3uRows = [locationRow, fileRow]
    xtreamRows = [serverRow, userRow, passRow]
    let form = NSStackView(views: [row("Name", nameField), row("Type", kindPopup)] + m3uRows + xtreamRows + [epgRow])
    form.orientation = .vertical
    form.alignment = .leading
    form.spacing = 8
    form.translatesAutoresizingMaskIntoConstraints = false
    let buttons = NSStackView(views: [cancel, save])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    buttons.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(form)
    content.addSubview(buttons)
    NSLayoutConstraint.activate([
      form.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      form.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
    ])
    super.init()
    kindPopup.target = self
    kindPopup.action = #selector(kindChanged(_:))
    choose.target = self
    choose.action = #selector(chooseFile(_:))
    save.target = self
    save.action = #selector(save(_:))
    cancel.target = self
    cancel.action = #selector(cancel(_:))
    kindChanged(nil)
  }

  @objc private func kindChanged(_ sender: Any?) {
    let xtream = kindPopup.indexOfSelectedItem == 1
    for view in m3uRows { view.isHidden = xtream }
    for view in xtreamRows { view.isHidden = !xtream }
    epgField.placeholderString = xtream ? "EPG URL (optional, default is xmltv.php)" : "EPG URL (optional, overrides url-tvg)"
  }

  @objc private func chooseFile(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [
      UTType(filenameExtension: "m3u") ?? .plainText,
      UTType(filenameExtension: "m3u8") ?? .plainText
    ]
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.locationField.stringValue = url.path
    }
  }

  @objc private func cancel(_ sender: Any?) {
    window.sheetParent?.endSheet(window, returnCode: .cancel)
  }

  @objc private func save(_ sender: Any?) {
    let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      NSSound.beep()
      return
    }
    let xtream = kindPopup.indexOfSelectedItem == 1
    let source = IPTVSource(
      id: existing?.id ?? UUID(),
      name: name,
      kind: xtream ? .xtream : .m3u,
      location: locationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
      epgURL: epgField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
      server: serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
      username: usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    if xtream {
      if source.server.isEmpty || source.username.isEmpty {
        NSSound.beep()
        return
      }
      if existing == nil && passwordField.stringValue.isEmpty {
        NSSound.beep()
        return
      }
    } else if source.location.isEmpty {
      NSSound.beep()
      return
    }
    let typed = passwordField.stringValue
    result = (source, typed.isEmpty ? nil : typed)
    window.sheetParent?.endSheet(window, returnCode: .OK)
  }
}
