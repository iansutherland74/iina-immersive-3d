//
//  IPTVPosterView.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Poster grid and title details for Xtream movies and series.
//  This view was not opened on the machine that added it.

import Cocoa

final class IPTVPosterBrowser: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
  var onSelect: (IPTVItem) -> Void = { _ in }
  var progressFor: (IPTVItem) -> IPTVWatchRecord? = { _ in nil }

  private let scroll = NSScrollView()
  private let collection = NSCollectionView()
  private var sections: [(title: String, items: [IPTVItem])] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    let layout = NSCollectionViewFlowLayout()
    layout.itemSize = NSSize(width: 156, height: 268)
    layout.minimumInteritemSpacing = 16
    layout.minimumLineSpacing = 18
    layout.sectionInset = NSEdgeInsets(top: 4, left: 16, bottom: 20, right: 16)
    collection.collectionViewLayout = layout
    collection.dataSource = self
    collection.delegate = self
    collection.isSelectable = true
    collection.allowsMultipleSelection = false
    collection.backgroundColors = [.controlBackgroundColor]
    collection.register(IPTVPosterItem.self, forItemWithIdentifier: IPTVPosterItem.reuse)
    collection.register(IPTVPosterHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: IPTVPosterHeader.reuse)
    scroll.documentView = collection
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.topAnchor.constraint(equalTo: topAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(library: [IPTVItem], continueWatching: [IPTVItem], sectionTitle: String, showContinueRow: Bool) {
    var next: [(title: String, items: [IPTVItem])] = []
    if showContinueRow, !continueWatching.isEmpty {
      next.append(("Continue watching", continueWatching))
    }
    next.append((sectionTitle, library))
    sections = next
    collection.reloadData()
  }

  func refreshVisibleProgress() {
    for item in collection.visibleItems() {
      (item as? IPTVPosterItem)?.applyProgress(progressFor)
    }
  }

  func numberOfSections(in collectionView: NSCollectionView) -> Int {
    sections.count
  }

  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
    sections[section].items.count
  }

  func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
    let item = collectionView.makeItem(withIdentifier: IPTVPosterItem.reuse, for: indexPath)
    let model = sections[indexPath.section].items[indexPath.item]
    (item as? IPTVPosterItem)?.configure(model, progress: progressFor(model))
    return item
  }

  func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
    let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: IPTVPosterHeader.reuse, for: indexPath)
    (view as? IPTVPosterHeader)?.label.stringValue = sections[indexPath.section].title
    return view
  }

  func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> NSSize {
    NSSize(width: collectionView.bounds.width, height: 34)
  }

  func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
    guard let indexPath = indexPaths.first else { return }
    onSelect(sections[indexPath.section].items[indexPath.item])
    collectionView.deselectItems(at: indexPaths)
  }
}

final class IPTVPosterHeader: NSView, NSCollectionViewElement {
  static let reuse = NSUserInterfaceItemIdentifier("IPTVPosterHeader")
  let label = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.textColor = .labelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class IPTVPosterItem: NSCollectionViewItem {
  static let reuse = NSUserInterfaceItemIdentifier("IPTVPosterItem")
  private let poster = NSImageView()
  private let bar = NSView()
  private let barFill = NSView()
  private let titleField = NSTextField(wrappingLabelWithString: "")
  private let subtitleField = NSTextField(labelWithString: "")
  private var barWidth: NSLayoutConstraint?
  private var model: IPTVItem?
  private var token = 0

  override func loadView() {
    let root = NSView()
    poster.imageScaling = .scaleProportionallyUpOrDown
    poster.imageAlignment = .alignCenter
    poster.wantsLayer = true
    poster.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
    poster.layer?.cornerRadius = 6
    poster.translatesAutoresizingMaskIntoConstraints = false
    bar.wantsLayer = true
    bar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
    bar.translatesAutoresizingMaskIntoConstraints = false
    barFill.wantsLayer = true
    barFill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    barFill.translatesAutoresizingMaskIntoConstraints = false
    bar.addSubview(barFill)
    titleField.font = .systemFont(ofSize: 12, weight: .semibold)
    titleField.maximumNumberOfLines = 2
    titleField.lineBreakMode = .byTruncatingTail
    subtitleField.font = .systemFont(ofSize: 11)
    subtitleField.textColor = .secondaryLabelColor
    subtitleField.lineBreakMode = .byTruncatingTail
    let stack = NSStackView(views: [poster, titleField, subtitleField])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    poster.addSubview(bar)
    barWidth = barFill.widthAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      stack.topAnchor.constraint(equalTo: root.topAnchor),
      poster.widthAnchor.constraint(equalTo: stack.widthAnchor),
      poster.heightAnchor.constraint(equalToConstant: 210),
      titleField.widthAnchor.constraint(equalTo: stack.widthAnchor),
      subtitleField.widthAnchor.constraint(equalTo: stack.widthAnchor),
      bar.leadingAnchor.constraint(equalTo: poster.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: poster.trailingAnchor),
      bar.bottomAnchor.constraint(equalTo: poster.bottomAnchor),
      bar.heightAnchor.constraint(equalToConstant: 4),
      barFill.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
      barFill.topAnchor.constraint(equalTo: bar.topAnchor),
      barFill.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
      barWidth!
    ])
    view = root
  }

  func configure(_ item: IPTVItem, progress: IPTVWatchRecord?) {
    model = item
    titleField.stringValue = item.name
    let year = IPTVTitleParser.year(in: item.releaseDate) ?? IPTVTitleParser.splitTitleYear(item.name).year
    subtitleField.stringValue = year ?? item.group
    apply(progress)
    poster.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
    token += 1
    let current = token
    guard let raw = item.logoURL, let url = URL(string: raw) else { return }
    if let image = IPTVImageLoader.shared.cachedImage(for: url) {
      poster.image = image
      return
    }
    IPTVImageLoader.shared.load(url) { [weak self] image in
      guard let self, self.token == current, let image else { return }
      self.poster.image = image
    }
  }

  func applyProgress(_ lookup: (IPTVItem) -> IPTVWatchRecord?) {
    guard let model else { return }
    apply(lookup(model))
  }

  private func apply(_ progress: IPTVWatchRecord?) {
    let fraction = progress.map { IPTVWatch.fraction($0) } ?? 0
    let resumable = progress.flatMap { IPTVWatch.resumeSeconds($0) } != nil
    bar.isHidden = !resumable
    barWidth?.constant = resumable ? 156 * fraction : 0
    if resumable, let progress {
      let percent = Int((fraction * 100).rounded())
      subtitleField.stringValue = "Resume \(percent)%"
      subtitleField.textColor = .controlAccentColor
    } else if let model {
      let year = IPTVTitleParser.year(in: model.releaseDate) ?? IPTVTitleParser.splitTitleYear(model.name).year
      subtitleField.stringValue = year ?? model.group
      subtitleField.textColor = .secondaryLabelColor
    }
  }
}

final class IPTVDetailView: NSView {
  var onPlay: (IPTVItem, Bool) -> Void = { _, _ in }
  var onTrailer: (URL) -> Void = { _ in }
  var progressFor: (String) -> IPTVWatchRecord? = { _ in nil }

  private let scroll = NSScrollView()
  private let document = NSView()
  private let stack = NSStackView()
  private let backdrop = NSImageView()
  private let poster = NSImageView()
  private let titleField = NSTextField(wrappingLabelWithString: "")
  private let factsField = NSTextField(wrappingLabelWithString: "")
  private let noteField = NSTextField(wrappingLabelWithString: "")
  private let directorField = NSTextField(wrappingLabelWithString: "")
  private let castField = NSTextField(wrappingLabelWithString: "")
  private let plotField = NSTextField(wrappingLabelWithString: "")
  private let playButton = NSButton(title: "Play", target: nil, action: nil)
  private let resumeButton = NSButton(title: "Resume", target: nil, action: nil)
  private let trailerButton = NSButton(title: "Trailer", target: nil, action: nil)
  private let seasonPopup = NSPopUpButton()
  private let episodeStack = NSStackView()
  private var item: IPTVItem?
  private var details: IPTVTitleDetails?
  private var trailer: URL?
  private var headerPlayItem: IPTVItem?
  private var imageToken = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    document.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = document
    backdrop.imageScaling = .scaleProportionallyUpOrDown
    backdrop.wantsLayer = true
    backdrop.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.2).cgColor
    backdrop.translatesAutoresizingMaskIntoConstraints = false
    poster.imageScaling = .scaleProportionallyUpOrDown
    poster.wantsLayer = true
    poster.layer?.cornerRadius = 6
    poster.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
    poster.translatesAutoresizingMaskIntoConstraints = false
    titleField.font = .systemFont(ofSize: 26, weight: .bold)
    factsField.font = .systemFont(ofSize: 13)
    factsField.textColor = .secondaryLabelColor
    noteField.font = .systemFont(ofSize: 12)
    noteField.textColor = .secondaryLabelColor
    directorField.font = .systemFont(ofSize: 13)
    castField.font = .systemFont(ofSize: 13)
    castField.textColor = .secondaryLabelColor
    plotField.font = .systemFont(ofSize: 14)
    for button in [playButton, resumeButton, trailerButton] {
      button.bezelStyle = .rounded
      button.target = self
    }
    playButton.action = #selector(playFromStart(_:))
    resumeButton.action = #selector(resume(_:))
    trailerButton.action = #selector(openTrailer(_:))
    seasonPopup.target = self
    seasonPopup.action = #selector(seasonChanged(_:))
    episodeStack.orientation = .vertical
    episodeStack.alignment = .leading
    episodeStack.spacing = 10
    let buttons = NSStackView(views: [playButton, resumeButton, trailerButton])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    let meta = NSStackView(views: [titleField, factsField, noteField, buttons, directorField, castField])
    meta.orientation = .vertical
    meta.alignment = .leading
    meta.spacing = 8
    let header = NSStackView(views: [poster, meta])
    header.orientation = .horizontal
    header.alignment = .top
    header.spacing = 16
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 24, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(backdrop)
    stack.addArrangedSubview(header)
    stack.addArrangedSubview(plotField)
    stack.addArrangedSubview(seasonPopup)
    stack.addArrangedSubview(episodeStack)
    document.addSubview(stack)
    addSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.topAnchor.constraint(equalTo: topAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      backdrop.heightAnchor.constraint(equalToConstant: 220),
      backdrop.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      poster.widthAnchor.constraint(equalToConstant: 150),
      poster.heightAnchor.constraint(equalToConstant: 225),
      titleField.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -210),
      plotField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)
    ])
    meta.setContentHuggingPriority(.defaultLow, for: .horizontal)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    let width = max(240, bounds.width - 64)
    plotField.preferredMaxLayoutWidth = width
    castField.preferredMaxLayoutWidth = max(180, bounds.width - 230)
    titleField.preferredMaxLayoutWidth = max(180, bounds.width - 230)
    factsField.preferredMaxLayoutWidth = titleField.preferredMaxLayoutWidth
  }

  func showLoading(_ item: IPTVItem) {
    self.item = item
    details = nil
    titleField.stringValue = item.name
    factsField.stringValue = item.rating ?? item.group
    noteField.stringValue = "Loading details…"
    noteField.isHidden = false
    plotField.stringValue = item.plot ?? ""
    plotField.isHidden = (item.plot ?? "").isEmpty
    directorField.isHidden = true
    castField.isHidden = true
    seasonPopup.isHidden = true
    episodeStack.isHidden = true
    trailerButton.isHidden = true
    playButton.isHidden = item.kind == .series
    resumeButton.isHidden = true
    headerPlayItem = item.kind == .series ? nil : item
    loadImages(posterURL: item.logoURL, backdropURL: item.backdropURL)
  }

  func show(details: IPTVTitleDetails, item: IPTVItem, note: String?) {
    self.item = item
    self.details = details
    titleField.stringValue = details.name
    factsField.stringValue = details.factLine
    factsField.isHidden = details.factLine.isEmpty
    noteField.stringValue = note ?? ""
    noteField.isHidden = note?.isEmpty ?? true
    plotField.stringValue = details.plot ?? ""
    plotField.isHidden = (details.plot ?? "").isEmpty
    if let director = details.director, !director.isEmpty {
      directorField.stringValue = "Director  \(director)"
      directorField.isHidden = false
    } else {
      directorField.isHidden = true
    }
    if let cast = details.cast, !cast.isEmpty {
      castField.stringValue = "Cast  \(cast)"
      castField.isHidden = false
    } else {
      castField.isHidden = true
    }
    trailer = details.trailerURL.flatMap { URL(string: $0) }
    trailerButton.isHidden = trailer == nil
    configureHeaderPlay(details: details, item: item)
    configureEpisodes(details)
    loadImages(posterURL: details.posterURL ?? item.logoURL, backdropURL: details.backdropURL ?? item.backdropURL)
  }

  func showError(_ message: String, item: IPTVItem) {
    showLoading(item)
    noteField.stringValue = message
    noteField.isHidden = false
    if item.kind != .series {
      playButton.isHidden = false
      headerPlayItem = item
      refreshProgress()
    }
  }

  func refreshProgress() {
    if let details, let item {
      configureHeaderPlay(details: details, item: item)
      rebuildEpisodeRows()
    } else if let item, item.kind != .series {
      resumeButton.isHidden = progressFor(item.id).flatMap { IPTVWatch.resumeSeconds($0) } == nil
    }
  }

  private func configureHeaderPlay(details: IPTVTitleDetails, item: IPTVItem) {
    playButton.title = "Play"
    resumeButton.title = "Resume"
    if item.kind != .series {
      headerPlayItem = item
      playButton.isHidden = false
      resumeButton.isHidden = progressFor(item.id).flatMap { IPTVWatch.resumeSeconds($0) } == nil
      return
    }
    headerPlayItem = details.episodes.first?.item
    playButton.isHidden = details.episodes.isEmpty
    let resumable = details.episodes.contains { progressFor($0.item.id).flatMap { IPTVWatch.resumeSeconds($0) } != nil }
    resumeButton.isHidden = !resumable
  }

  private func configureEpisodes(_ details: IPTVTitleDetails) {
    let seasons = Array(Set(details.episodes.map(\.season))).sorted()
    seasonPopup.removeAllItems()
    seasonPopup.isHidden = details.episodes.isEmpty
    episodeStack.isHidden = details.episodes.isEmpty
    guard !seasons.isEmpty else { return }
    for season in seasons {
      let title = season > 0 ? "Season \(season)" : "Episodes"
      seasonPopup.addItem(withTitle: title)
      seasonPopup.lastItem?.tag = season
    }
    rebuildEpisodeRows()
  }

  private func rebuildEpisodeRows() {
    for view in episodeStack.arrangedSubviews {
      episodeStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    guard let details else { return }
    let season = seasonPopup.selectedItem?.tag ?? details.episodes.first?.season ?? 0
    let rows = details.episodes.filter { $0.season == season }
    for episode in rows {
      episodeStack.addArrangedSubview(episodeRow(episode))
    }
  }

  private func episodeRow(_ episode: IPTVEpisodeDetails) -> NSView {
    let thumb = NSImageView()
    thumb.imageScaling = .scaleProportionallyUpOrDown
    thumb.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
    thumb.wantsLayer = true
    thumb.layer?.cornerRadius = 4
    thumb.translatesAutoresizingMaskIntoConstraints = false
    thumb.widthAnchor.constraint(equalToConstant: 128).isActive = true
    thumb.heightAnchor.constraint(equalToConstant: 72).isActive = true
    if let raw = episode.thumbnailURL ?? episode.item.logoURL, let url = URL(string: raw) {
      IPTVImageLoader.shared.load(url) { image in
        if let image { thumb.image = image }
      }
    }
    let title = NSTextField(labelWithString: episode.item.name)
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    title.lineBreakMode = .byTruncatingTail
    let plot = NSTextField(wrappingLabelWithString: episode.plot ?? "")
    plot.font = .systemFont(ofSize: 12)
    plot.textColor = .secondaryLabelColor
    plot.maximumNumberOfLines = 2
    plot.isHidden = (episode.plot ?? "").isEmpty
    let meta = NSTextField(labelWithString: episode.durationText ?? "")
    meta.font = .systemFont(ofSize: 11)
    meta.textColor = .tertiaryLabelColor
    meta.isHidden = (episode.durationText ?? "").isEmpty
    let play = NSButton(title: "Play", target: self, action: #selector(playEpisode(_:)))
    play.bezelStyle = .rounded
    play.tag = tag(for: episode)
    let resume = NSButton(title: "Resume", target: self, action: #selector(resumeEpisode(_:)))
    resume.bezelStyle = .rounded
    resume.tag = play.tag
    resume.isHidden = progressFor(episode.item.id).flatMap { IPTVWatch.resumeSeconds($0) } == nil
    let buttons = NSStackView(views: [play, resume])
    buttons.orientation = .horizontal
    buttons.spacing = 6
    let text = NSStackView(views: [title, plot, meta, buttons])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 4
    let row = NSStackView(views: [thumb, text])
    row.orientation = .horizontal
    row.alignment = .top
    row.spacing = 10
    return row
  }

  private func tag(for episode: IPTVEpisodeDetails) -> Int {
    guard let details else { return 0 }
    return details.episodes.firstIndex { $0.item.id == episode.item.id } ?? 0
  }

  private func episode(tag: Int) -> IPTVEpisodeDetails? {
    guard let details, details.episodes.indices.contains(tag) else { return nil }
    return details.episodes[tag]
  }

  private func loadImages(posterURL: String?, backdropURL: String?) {
    imageToken += 1
    let current = imageToken
    poster.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
    backdrop.image = nil
    func assign(_ raw: String?, _ view: NSImageView) {
      guard let raw, let url = URL(string: raw) else { return }
      if let image = IPTVImageLoader.shared.cachedImage(for: url) {
        view.image = image
        return
      }
      IPTVImageLoader.shared.load(url) { [weak self] image in
        guard let self, self.imageToken == current, let image else { return }
        view.image = image
      }
    }
    assign(posterURL, poster)
    assign(backdropURL, backdrop)
  }

  @objc private func seasonChanged(_ sender: Any?) {
    rebuildEpisodeRows()
  }

  @objc private func playFromStart(_ sender: Any?) {
    guard let headerPlayItem else { return }
    onPlay(headerPlayItem, false)
  }

  @objc private func resume(_ sender: Any?) {
    guard let item else { return }
    if item.kind == .series, let details, let current = details.episodes.first(where: { progressFor($0.item.id).flatMap { IPTVWatch.resumeSeconds($0) } != nil }) {
      onPlay(current.item, true)
      return
    }
    onPlay(item, true)
  }

  @objc private func openTrailer(_ sender: Any?) {
    guard let trailer else { return }
    onTrailer(trailer)
  }

  @objc private func playEpisode(_ sender: NSButton) {
    guard let episode = episode(tag: sender.tag) else { return }
    onPlay(episode.item, false)
  }

  @objc private func resumeEpisode(_ sender: NSButton) {
    guard let episode = episode(tag: sender.tag) else { return }
    onPlay(episode.item, true)
  }
}
