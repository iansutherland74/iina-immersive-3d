//
//  IPTVGuideView.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  TV guide: channel rows on the left (logo, name, now, next) and an XMLTV
//  time grid on the right. A channel row or the current listing plays live.
//  A past listing on an archive channel plays that programme from the start.
//  This view was not opened on the machine that added it.

import Cocoa

final class IPTVGuideBrowser: NSView {
  var onPlay: (IPTVItem, IPTVGuideAction) -> Void = { _, _ in }
  var onToggleFavourite: (IPTVItem) -> Void = { _ in }
  var isFavourite: (IPTVItem) -> Bool = { _ in false }

  private let corner = NSView()
  private let cornerLabel = NSTextField(labelWithString: "Channels")
  private let rulerScroll = NSScrollView()
  private let channelScroll = NSScrollView()
  private let gridScroll = NSScrollView()
  private let ruler = IPTVGuideRuler()
  private let column = IPTVGuideChannelColumn()
  private let canvas = IPTVGuideCanvas()
  private var syncingScroll = false
  private var didBindScroll = false
  private var pendingScrollToNow = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    install()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(items: [IPTVItem], guide: IPTVEPG, query: String, scrollToNow: Bool) {
    column.items = items
    column.guide = guide
    column.query = query
    column.isFavourite = isFavourite
    column.onToggleFavourite = onToggleFavourite
    column.onPlay = onPlay
    canvas.items = items
    canvas.guide = guide
    canvas.query = query
    canvas.onPlay = onPlay
    ruler.origin = IPTVGuideWindow.timelineStart()
    canvas.origin = ruler.origin
    let height = max(CGFloat(items.count) * IPTVGuideWindow.rowHeight, 1)
    let timelineWidth = CGFloat(IPTVGuideWindow.timelineLength / 3600) * IPTVGuideWindow.hourWidth
    // Leave the frame alone when the size is unchanged so typing in search does not jump the scroll position.
    let columnFrame = NSRect(x: 0, y: 0, width: IPTVGuideWindow.channelWidth, height: height)
    let canvasFrame = NSRect(x: 0, y: 0, width: timelineWidth, height: height)
    let rulerFrame = NSRect(x: 0, y: 0, width: timelineWidth, height: IPTVGuideWindow.headerHeight)
    if column.frame != columnFrame { column.frame = columnFrame }
    if canvas.frame != canvasFrame { canvas.frame = canvasFrame }
    if ruler.frame != rulerFrame { ruler.frame = rulerFrame }
    column.needsDisplay = true
    canvas.needsDisplay = true
    ruler.needsDisplay = true
    if scrollToNow {
      pendingScrollToNow = true
    }
  }

  /// Move the "now" marker without jumping the scroll position.
  func tick() {
    let start = IPTVGuideWindow.timelineStart()
    if start != ruler.origin {
      ruler.origin = start
      canvas.origin = start
    }
    column.needsDisplay = true
    canvas.needsDisplay = true
    ruler.needsDisplay = true
  }

  override func layout() {
    super.layout()
    guard pendingScrollToNow, bounds.width > 0 else { return }
    pendingScrollToNow = false
    syncingScroll = true
    let nowX = canvas.xPosition(of: Date()) - 48
    gridScroll.contentView.scroll(to: NSPoint(x: max(0, nowX), y: 0))
    syncRuler(to: max(0, nowX))
    channelScroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
    syncingScroll = false
  }

  private func install() {
    wantsLayer = true
    corner.wantsLayer = true
    corner.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    cornerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    cornerLabel.textColor = .secondaryLabelColor
    cornerLabel.alignment = .center
    cornerLabel.translatesAutoresizingMaskIntoConstraints = false
    corner.addSubview(cornerLabel)
    NSLayoutConstraint.activate([
      cornerLabel.leadingAnchor.constraint(equalTo: corner.leadingAnchor, constant: 8),
      cornerLabel.trailingAnchor.constraint(equalTo: corner.trailingAnchor, constant: -8),
      cornerLabel.centerYAnchor.constraint(equalTo: corner.centerYAnchor)
    ])

    configure(rulerScroll, horizontal: false, vertical: false)
    configure(channelScroll, horizontal: false, vertical: false)
    configure(gridScroll, horizontal: true, vertical: true)
    ruler.autoresizingMask = []
    column.autoresizingMask = []
    canvas.autoresizingMask = []
    rulerScroll.documentView = ruler
    channelScroll.documentView = column
    gridScroll.documentView = canvas
    rulerScroll.drawsBackground = true
    rulerScroll.backgroundColor = .windowBackgroundColor
    channelScroll.drawsBackground = true
    channelScroll.backgroundColor = .controlBackgroundColor
    gridScroll.drawsBackground = true
    gridScroll.backgroundColor = .controlBackgroundColor

    for view in [corner, rulerScroll, channelScroll, gridScroll] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    let channelW = IPTVGuideWindow.channelWidth
    let header = IPTVGuideWindow.headerHeight
    NSLayoutConstraint.activate([
      corner.leadingAnchor.constraint(equalTo: leadingAnchor),
      corner.topAnchor.constraint(equalTo: topAnchor),
      corner.widthAnchor.constraint(equalToConstant: channelW),
      corner.heightAnchor.constraint(equalToConstant: header),
      rulerScroll.leadingAnchor.constraint(equalTo: corner.trailingAnchor),
      rulerScroll.topAnchor.constraint(equalTo: topAnchor),
      rulerScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      rulerScroll.heightAnchor.constraint(equalToConstant: header),
      channelScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      channelScroll.topAnchor.constraint(equalTo: corner.bottomAnchor),
      channelScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      channelScroll.widthAnchor.constraint(equalToConstant: channelW),
      gridScroll.leadingAnchor.constraint(equalTo: channelScroll.trailingAnchor),
      gridScroll.topAnchor.constraint(equalTo: rulerScroll.bottomAnchor),
      gridScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      gridScroll.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Programme guide")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard !didBindScroll else { return }
    didBindScroll = true
    channelScroll.contentView.postsBoundsChangedNotifications = true
    gridScroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(gridBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: gridScroll.contentView)
    NotificationCenter.default.addObserver(self, selector: #selector(channelBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: channelScroll.contentView)
  }

  private func configure(_ scroll: NSScrollView, horizontal: Bool, vertical: Bool) {
    scroll.hasHorizontalScroller = horizontal
    scroll.hasVerticalScroller = vertical
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
  }

  @objc private func gridBoundsChanged(_ notification: Notification) {
    guard !syncingScroll else { return }
    syncingScroll = true
    let origin = gridScroll.contentView.bounds.origin
    channelScroll.contentView.scroll(to: NSPoint(x: 0, y: origin.y))
    syncRuler(to: origin.x)
    syncingScroll = false
  }

  @objc private func channelBoundsChanged(_ notification: Notification) {
    guard !syncingScroll else { return }
    syncingScroll = true
    let origin = channelScroll.contentView.bounds.origin
    let grid = gridScroll.contentView.bounds.origin
    gridScroll.contentView.scroll(to: NSPoint(x: grid.x, y: origin.y))
    syncingScroll = false
  }

  private func syncRuler(to x: CGFloat) {
    rulerScroll.contentView.scroll(to: NSPoint(x: x, y: 0))
  }
}

private final class IPTVGuideRuler: NSView {
  var origin: Date = IPTVGuideWindow.timelineStart()
  private let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMdj")
    return formatter
  }()

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
    let hours = Int(IPTVGuideWindow.timelineLength / 3600)
    let hourWidth = IPTVGuideWindow.hourWidth
    let labelAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .medium),
      .foregroundColor: NSColor.secondaryLabelColor
    ]
    for hour in 0...hours {
      let x = CGFloat(hour) * hourWidth
      guard dirtyRect.intersects(NSRect(x: x - 2, y: 0, width: hourWidth + 4, height: bounds.height)) else { continue }
      NSColor.separatorColor.setStroke()
      let tick = NSBezierPath()
      tick.move(to: NSPoint(x: x, y: bounds.height - 8))
      tick.line(to: NSPoint(x: x, y: bounds.height))
      tick.stroke()
      if hour < hours {
        let minor = NSBezierPath()
        minor.move(to: NSPoint(x: x + hourWidth / 2, y: bounds.height - 4))
        minor.line(to: NSPoint(x: x + hourWidth / 2, y: bounds.height))
        minor.stroke()
        let date = origin.addingTimeInterval(TimeInterval(hour) * 3600)
        (formatter.string(from: date) as NSString).draw(at: NSPoint(x: x + 6, y: 8), withAttributes: labelAttributes)
      }
    }
    let nowX = CGFloat(Date().timeIntervalSince(origin) / 3600) * hourWidth
    if nowX >= 0 && nowX <= bounds.width {
      NSColor.controlAccentColor.setFill()
      let marker = NSBezierPath()
      marker.move(to: NSPoint(x: nowX - 5, y: bounds.height))
      marker.line(to: NSPoint(x: nowX + 5, y: bounds.height))
      marker.line(to: NSPoint(x: nowX, y: bounds.height - 7))
      marker.close()
      marker.fill()
    }
    NSColor.separatorColor.setStroke()
    let underline = NSBezierPath()
    underline.move(to: NSPoint(x: dirtyRect.minX, y: bounds.height - 0.5))
    underline.line(to: NSPoint(x: dirtyRect.maxX, y: bounds.height - 0.5))
    underline.stroke()
  }
}

private final class IPTVGuideChannelColumn: NSView {
  var items: [IPTVItem] = []
  var guide = IPTVEPG()
  var query = ""
  var isFavourite: (IPTVItem) -> Bool = { _ in false }
  var onToggleFavourite: (IPTVItem) -> Void = { _ in }
  var onPlay: (IPTVItem, IPTVGuideAction) -> Void = { _, _ in }
  private var press: NSPoint?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    guard !items.isEmpty else { return }
    let rowHeight = IPTVGuideWindow.rowHeight
    let first = max(0, Int(dirtyRect.minY / rowHeight))
    let last = min(items.count - 1, Int(dirtyRect.maxY / rowHeight))
    guard first <= last else { return }
    let moment = Date()
    let nameAttributes = textAttributes(size: 13, weight: .semibold, color: .labelColor)
    let nowAttributes = textAttributes(size: 11, weight: .regular, color: .labelColor)
    let nextAttributes = textAttributes(size: 11, weight: .regular, color: .secondaryLabelColor)
    for row in first...last {
      let item = items[row]
      let rowRect = NSRect(x: 0, y: CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight)
      (row % 2 == 0 ? NSColor.controlBackgroundColor : NSColor.alternatingContentBackgroundColors.last ?? NSColor.windowBackgroundColor).setFill()
      rowRect.fill()
      let pair = guide.nowAndNext(for: item, at: moment)
      let archive = item.hasArchive
      let restart = pair.now.map { IPTVCatchup.canRestart(item, $0, now: moment) } ?? false
      let textWidth = bounds.width - 86 - (archive ? 22 : 0)
      let nameRect = NSRect(x: 78, y: rowRect.minY + 8, width: textWidth, height: 18)
      let nowRect = NSRect(x: 78, y: rowRect.minY + 28, width: textWidth, height: 16)
      let nextRect = NSRect(x: 78, y: rowRect.minY + 46, width: bounds.width - 86, height: 16)
      (item.name as NSString).draw(in: nameRect, withAttributes: nameAttributes)
      let nowText = pair.now.map { "Now  \($0.title)" } ?? "Now  —"
      let nextText = pair.next.map { "Next  \($0.title)" } ?? "Next  —"
      (nowText as NSString).draw(in: nowRect, withAttributes: nowAttributes)
      (nextText as NSString).draw(in: nextRect, withAttributes: nextAttributes)
      drawStar(on: isFavourite(item), in: starRect(for: row))
      drawLogo(item, in: NSRect(x: 30, y: rowRect.minY + 16, width: 40, height: 40))
      if archive {
        drawSymbol("clock.arrow.circlepath", tint: .systemBlue, in: badgeRect(for: row), description: "Catch-up")
      }
      if restart {
        drawSymbol("arrow.counterclockwise", tint: .systemBlue, in: restartRect(for: row), description: "Restart current programme")
      }
    }
    NSColor.separatorColor.setStroke()
    let divider = NSBezierPath()
    divider.move(to: NSPoint(x: bounds.width - 0.5, y: dirtyRect.minY))
    divider.line(to: NSPoint(x: bounds.width - 0.5, y: dirtyRect.maxY))
    divider.stroke()
  }

  override func mouseDown(with event: NSEvent) {
    press = convert(event.locationInWindow, from: nil)
  }

  override func mouseUp(with event: NSEvent) {
    guard let press else { return }
    let point = convert(event.locationInWindow, from: nil)
    self.press = nil
    guard hypot(point.x - press.x, point.y - press.y) < 6 else { return }
    let rowHeight = IPTVGuideWindow.rowHeight
    let row = Int(point.y / rowHeight)
    guard items.indices.contains(row) else { return }
    let item = items[row]
    if starRect(for: row).insetBy(dx: -4, dy: -4).contains(point) {
      onToggleFavourite(item)
      return
    }
    if let current = guide.nowAndNext(for: item, at: Date()).now, IPTVCatchup.canRestart(item, current, now: Date()), restartRect(for: row).insetBy(dx: -4, dy: -4).contains(point) {
      onPlay(item, .fromStart(current, restart: true))
      return
    }
    onPlay(item, .live)
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let row = Int(point.y / IPTVGuideWindow.rowHeight)
    guard items.indices.contains(row) else {
      toolTip = nil
      return
    }
    let item = items[row]
    if restartRect(for: row).insetBy(dx: -4, dy: -4).contains(point), item.hasArchive {
      toolTip = "Restart current programme"
    } else if badgeRect(for: row).insetBy(dx: -4, dy: -4).contains(point), item.hasArchive {
      let days = item.catchup?.days ?? 0
      toolTip = days == 1 ? "Catch-up for 1 day" : "Catch-up for \(days) days"
    } else {
      toolTip = nil
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach { removeTrackingArea($0) }
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  private func starRect(for row: Int) -> NSRect {
    let rowHeight = IPTVGuideWindow.rowHeight
    return NSRect(x: 8, y: CGFloat(row) * rowHeight + (rowHeight - 16) / 2, width: 16, height: 16)
  }

  private func badgeRect(for row: Int) -> NSRect {
    let rowHeight = IPTVGuideWindow.rowHeight
    return NSRect(x: bounds.width - 24, y: CGFloat(row) * rowHeight + 8, width: 16, height: 16)
  }

  private func restartRect(for row: Int) -> NSRect {
    let rowHeight = IPTVGuideWindow.rowHeight
    return NSRect(x: bounds.width - 24, y: CGFloat(row) * rowHeight + 28, width: 16, height: 16)
  }

  private func drawSymbol(_ name: String, tint: NSColor, in rect: NSRect, description: String) {
    guard var image = NSImage(systemSymbolName: name, accessibilityDescription: description) else { return }
    image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint])) ?? image
    image.draw(in: rect)
  }

  private func drawStar(on: Bool, in rect: NSRect) {
    let symbol = on ? "star.fill" : "star"
    guard var image = NSImage(systemSymbolName: symbol, accessibilityDescription: on ? "Favourite" : "Not a favourite") else { return }
    let tint = on ? NSColor.systemYellow : NSColor.secondaryLabelColor
    image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint])) ?? image
    image.draw(in: rect)
  }

  private func drawLogo(_ item: IPTVItem, in rect: NSRect) {
    let placeholder = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
    var drawn = placeholder
    if let raw = item.logoURL, let url = URL(string: raw) {
      if let image = IPTVImageLoader.shared.cachedImage(for: url) {
        drawn = image
      } else {
        IPTVImageLoader.shared.load(url) { [weak self] _ in
          self?.needsDisplay = true
        }
      }
    }
    drawn?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }

  private func textAttributes(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> [NSAttributedString.Key: Any] {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    return [
      .font: NSFont.systemFont(ofSize: size, weight: weight),
      .foregroundColor: color,
      .paragraphStyle: style
    ]
  }
}

private final class IPTVGuideCanvas: NSView {
  var items: [IPTVItem] = []
  var guide = IPTVEPG()
  var query = ""
  var origin: Date = IPTVGuideWindow.timelineStart()
  var onPlay: (IPTVItem, IPTVGuideAction) -> Void = { _, _ in }
  private var press: NSPoint?
  private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
  }()

  override var isFlipped: Bool { true }

  func xPosition(of date: Date) -> CGFloat {
    CGFloat(date.timeIntervalSince(origin) / 3600) * IPTVGuideWindow.hourWidth
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    dirtyRect.fill()
    guard !items.isEmpty else { return }
    let rowHeight = IPTVGuideWindow.rowHeight
    let first = max(0, Int(floor(dirtyRect.minY / rowHeight)))
    let last = min(items.count - 1, Int(floor(dirtyRect.maxY / rowHeight)))
    guard first <= last else { return }
    let moment = Date()
    let windowEnd = origin.addingTimeInterval(IPTVGuideWindow.timelineLength)
    let normalizedQuery = IPTVText.normalize(query)
    for row in first...last {
      let rowRect = NSRect(x: 0, y: CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight)
      if row % 2 == 1 {
        (NSColor.alternatingContentBackgroundColors.last ?? NSColor.windowBackgroundColor).setFill()
        rowRect.intersection(dirtyRect).fill()
      }
      let programmes = guide.programmes(for: items[row])
      var index = firstOverlapping(programmes, origin: origin)
      while index < programmes.count {
        let programme = programmes[index]
        if programme.start >= windowEnd { break }
        let rect = blockRect(programme, row: row, windowEnd: windowEnd)
        if rect.width > 1 && dirtyRect.intersects(rect) {
          let onAir = programme.start <= moment && programme.stop > moment
          let catchup = IPTVCatchup.canPlayFromStart(items[row], programme, now: moment)
          let past = programme.stop <= moment
          let hit = !normalizedQuery.isEmpty && IPTVText.normalize(programme.title).contains(normalizedQuery)
          drawBlock(programme, in: rect, onAir: onAir, catchup: catchup, past: past, highlighted: hit)
        }
        index += 1
      }
    }
    let nowX = xPosition(of: moment)
    if nowX >= dirtyRect.minX - 2 && nowX <= dirtyRect.maxX + 2 {
      NSColor.controlAccentColor.setStroke()
      let line = NSBezierPath()
      line.move(to: NSPoint(x: nowX, y: dirtyRect.minY))
      line.line(to: NSPoint(x: nowX, y: dirtyRect.maxY))
      line.lineWidth = 2
      line.stroke()
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach { removeTrackingArea($0) }
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    toolTip = tip(at: point)
  }

  override func mouseDown(with event: NSEvent) {
    press = convert(event.locationInWindow, from: nil)
  }

  override func mouseUp(with event: NSEvent) {
    guard let press else { return }
    let point = convert(event.locationInWindow, from: nil)
    self.press = nil
    guard hypot(point.x - press.x, point.y - press.y) < 6 else { return }
    let row = Int(point.y / IPTVGuideWindow.rowHeight)
    guard items.indices.contains(row) else { return }
    if let hit = programme(at: point) {
      onPlay(hit.item, action(for: hit.item, programme: hit.programme))
    } else if point.x < xPosition(of: Date()) {
      onPlay(items[row], .notice("No programme listed there."))
    } else {
      onPlay(items[row], .live)
    }
  }

  private func action(for item: IPTVItem, programme: IPTVProgramme) -> IPTVGuideAction {
    let moment = Date()
    if programme.start <= moment && programme.stop > moment { return .live }
    if programme.start > moment { return .live }
    if IPTVCatchup.canPlayFromStart(item, programme, now: moment) {
      return .fromStart(programme, restart: false)
    }
    if item.hasArchive, let days = item.catchup?.days {
      let earliest = moment.addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60)
      if programme.start < earliest {
        let noun = days == 1 ? "day" : "days"
        return .notice("Catch-up on \(item.name) only goes back \(days) \(noun).")
      }
    }
    let identifier = programme.catchupID?.lowercased() ?? ""
    let template = item.catchup?.template?.lowercased() ?? ""
    if identifier.hasPrefix("plugin://") || template.hasPrefix("plugin://") {
      return .notice("Catch-up plugin addresses are not supported.")
    }
    if template == "{catchup-id}" {
      return .notice("This listing has no catch-up address.")
    }
    if item.hasArchive {
      return .notice("No catch-up address for \(item.name).")
    }
    return .notice("\(item.name) has no catch-up for programmes that have already ended.")
  }

  private func tip(at point: NSPoint) -> String? {
    guard let hit = programme(at: point) else { return nil }
    let start = timeFormatter.string(from: hit.programme.start)
    let stop = timeFormatter.string(from: hit.programme.stop)
    let moment = Date()
    var text = "\(hit.programme.title)\n\(start) – \(stop)\n\(hit.item.name)"
    if IPTVCatchup.canPlayFromStart(hit.item, hit.programme, now: moment) {
      text += "\nCatch-up from the start"
    } else if hit.programme.start <= moment && hit.programme.stop > moment && IPTVCatchup.canRestart(hit.item, hit.programme, now: moment) {
      text += "\nOn now. Restart is on the channel row."
    } else if hit.programme.stop <= moment && !hit.item.hasArchive {
      text += "\nNo catch-up on this channel"
    } else if hit.programme.stop <= moment, let days = hit.item.catchup?.days, hit.programme.start < moment.addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60) {
      text += "\nOutside the catch-up window"
    } else if hit.programme.stop <= moment {
      text += "\nNo catch-up address for this listing"
    }
    return text
  }

  private func programme(at point: NSPoint) -> (item: IPTVItem, programme: IPTVProgramme)? {
    let rowHeight = IPTVGuideWindow.rowHeight
    let row = Int(point.y / rowHeight)
    guard items.indices.contains(row) else { return nil }
    let windowEnd = origin.addingTimeInterval(IPTVGuideWindow.timelineLength)
    let programmes = guide.programmes(for: items[row])
    var index = firstOverlapping(programmes, origin: origin)
    while index < programmes.count {
      let programme = programmes[index]
      if programme.start >= windowEnd { break }
      if blockRect(programme, row: row, windowEnd: windowEnd).contains(point) {
        return (items[row], programme)
      }
      index += 1
    }
    return nil
  }

  private func blockRect(_ programme: IPTVProgramme, row: Int, windowEnd: Date) -> NSRect {
    let start = max(programme.start, origin)
    let stop = min(programme.stop, windowEnd)
    let x = xPosition(of: start)
    let end = xPosition(of: stop)
    return NSRect(x: x + 2, y: CGFloat(row) * IPTVGuideWindow.rowHeight + 8, width: max(0, end - x - 4), height: IPTVGuideWindow.rowHeight - 16)
  }

  private func drawBlock(_ programme: IPTVProgramme, in rect: NSRect, onAir: Bool, catchup: Bool, past: Bool, highlighted: Bool) {
    let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
    let fill: NSColor
    let textColor: NSColor
    if highlighted {
      fill = NSColor.systemOrange.withAlphaComponent(0.9)
      textColor = .textBackgroundColor
    } else if onAir {
      fill = NSColor.controlAccentColor
      textColor = .alternateSelectedControlTextColor
    } else if catchup {
      fill = NSColor.systemBlue.withAlphaComponent(0.82)
      textColor = .white
    } else if past {
      fill = NSColor.quaternaryLabelColor.withAlphaComponent(0.16)
      textColor = .tertiaryLabelColor
    } else {
      fill = NSColor.quaternaryLabelColor.withAlphaComponent(0.35)
      textColor = .labelColor
    }
    fill.setFill()
    path.fill()
    NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
    path.lineWidth = 1
    path.stroke()
    let showRewind = catchup && rect.width > 36
    guard rect.width > 28 else { return }
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: onAir || catchup ? .semibold : .regular),
      .foregroundColor: textColor,
      .paragraphStyle: style
    ]
    var textRect = rect.insetBy(dx: 6, dy: 4)
    if showRewind {
      drawRewind(in: NSRect(x: rect.minX + 6, y: rect.midY - 7, width: 14, height: 14), tint: textColor)
      textRect.origin.x += 16
      textRect.size.width = max(0, textRect.width - 16)
    }
    guard textRect.width > 8 else { return }
    (programme.title as NSString).draw(in: textRect, withAttributes: attributes)
  }

  private func drawRewind(in rect: NSRect, tint: NSColor) {
    guard var image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Catch-up") else { return }
    image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint])) ?? image
    image.draw(in: rect)
  }

  private func firstOverlapping(_ programmes: [IPTVProgramme], origin: Date) -> Int {
    var low = 0
    var high = programmes.count
    while low < high {
      let mid = (low + high) / 2
      if programmes[mid].stop <= origin {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
  }
}
