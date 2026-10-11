//
//  GlassesEyeControls.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Play on Glasses hides IINA's on-screen controller, and a single control bar
//  stretched across a side-by-side frame is split between the two eyes. While
//  the glasses are showing side-by-side 3D, pointer movement reveals one
//  control bar drawn at the same place in each eye, plus a cursor in each eye.
//  The system pointer stays hidden over that window.

import Cocoa

enum GlassesEyePress {
  case play
  case seek
  case mute
  case volume
  case stereo
  case channels
  case guide
}

struct GlassesEyeBar {
  var bar = NSRect.zero
  var play = NSRect.zero
  var currentTime = NSRect.zero
  var seek = NSRect.zero
  var seekHit = NSRect.zero
  var duration = NSRect.zero
  var mute = NSRect.zero
  var volume = NSRect.zero
  var volumeHit = NSRect.zero
  var stereo = NSRect.zero
  var channels = NSRect.zero
  var guide = NSRect.zero

  static func layout(in bounds: NSRect, showsIPTV: Bool) -> GlassesEyeBar {
    var chrome = GlassesEyeBar()
    let margin: CGFloat = 16
    let height: CGFloat = 56
    let y = bounds.height - height - 14
    chrome.bar = NSRect(x: margin, y: max(8, y), width: max(0, bounds.width - margin * 2), height: height)
    let inner = chrome.bar.insetBy(dx: 8, dy: 8)
    guard inner.width > 40, inner.height > 8 else { return chrome }

    func row(_ x: CGFloat, _ width: CGFloat) -> NSRect {
      NSRect(x: x, y: inner.minY, width: width, height: inner.height)
    }

    var right = inner.maxX
    func takeRight(_ width: CGFloat) -> NSRect {
      right -= width
      let rect = row(right, width)
      right -= 8
      return rect
    }

    if showsIPTV {
      chrome.guide = takeRight(44)
      chrome.channels = takeRight(44)
    }
    chrome.stereo = takeRight(44)
    chrome.volume = takeRight(78)
    chrome.mute = takeRight(32)
    chrome.duration = takeRight(56)
    chrome.play = row(inner.minX, 36)
    chrome.currentTime = row(inner.minX + 44, 56)
    let seekX = chrome.currentTime.maxX + 8
    let seekWidth = max(8, chrome.duration.minX - 8 - seekX)
    chrome.seek = NSRect(x: seekX, y: inner.midY - 3, width: seekWidth, height: 6)
    chrome.seekHit = NSRect(x: seekX, y: inner.minY, width: seekWidth, height: inner.height)
    chrome.volumeHit = chrome.volume.insetBy(dx: 0, dy: -4)
    let track = chrome.volume.insetBy(dx: 4, dy: 0)
    chrome.volume = NSRect(x: track.minX, y: inner.midY - 3, width: track.width, height: 6)
    return chrome
  }

  func control(at point: NSPoint) -> GlassesEyePress? {
    if play.contains(point) { return .play }
    if seekHit.contains(point) { return .seek }
    if mute.contains(point) { return .mute }
    if volumeHit.contains(point) { return .volume }
    if stereo.contains(point) { return .stereo }
    if channels.width > 1, channels.contains(point) { return .channels }
    if guide.width > 1, guide.contains(point) { return .guide }
    return nil
  }
}

/// Side-by-side player controls for the glasses window.
final class GlassesEyeControls {
  static let shared = GlassesEyeControls()

  private let host = GlassesEyeHost()
  private(set) var shown = false
  private(set) var drawCursor = false
  private(set) var cursor = NSPoint(x: -100, y: -100)
  private(set) var activePress: GlassesEyePress?
  private var seekHold: CGFloat?
  private var volumeHold: CGFloat?
  private var muteHold: Bool?
  private var hideTimer: Timer?
  private var refreshTimer: Timer?
  private var cursorHidden = false
  private var pointerInside = false

  private init() {
    let center = NotificationCenter.default
    center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.showSystemCursor()
    }
    center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self, Self.isSBS, self.pointerInsideWindow() else { return }
      self.pointerInside = true
      self.hideSystemCursor()
    }
  }

  /// Glasses are up and the picture is side-by-side, either converted or passed through.
  static var isSBS: Bool {
    let glasses = Immersive3DController.shared
    guard glasses.glassesActive else { return false }
    let snap = glasses.currentSnapshot()
    return snap.shouldProcess || snap.passThroughSBS
  }

  func sync() {
    if Self.isSBS {
      attachIfNeeded()
    } else {
      detach()
    }
  }

  func bringToFront() {
    guard host.superview != nil else { return }
    host.superview?.addSubview(host, positioned: .above, relativeTo: nil)
  }

  /// Pointer moved over the player window. Returns true when side-by-side glasses mode
  /// owns the event, so the normal full-width controller stays hidden.
  func handlePointer(_ event: NSEvent) -> Bool {
    guard Self.isSBS else {
      if host.superview != nil || cursorHidden { detach() }
      return false
    }
    guard !PlayerCore.playerCores.isEmpty,
          let window = PlayerCore.active.mainWindow.window,
          event.window === window else { return false }
    pointerInside = true
    attachIfNeeded()
    if let point = eyePoint(from: event) {
      cursor = point
    }
    drawCursor = true
    hideSystemCursor()
    reveal()
    return true
  }

  /// Pointer left the player window.
  func handlePointerExit() -> Bool {
    guard Self.isSBS || cursorHidden else { return false }
    pointerInside = false
    drawCursor = false
    if Preference.bool(for: .enableControlBarAutoHide) {
      conceal()
    } else {
      redisplay()
    }
    showSystemCursor()
    return Self.isSBS
  }

  /// Scroll over the bar changes volume or the playhead, and does not zap a channel.
  func handleScroll(_ event: NSEvent) -> Bool {
    guard Self.isSBS, shown, drawCursor else { return false }
    guard !PlayerCore.playerCores.isEmpty,
          let window = PlayerCore.active.mainWindow.window,
          event.window === window else { return false }
    guard let point = eyePoint(from: event) else { return false }
    let chrome = bar(in: eyeBounds())
    guard chrome.bar.contains(point) else { return false }
    if !event.momentumPhase.isEmpty { return true }
    let delta = event.scrollingDeltaY
    guard abs(delta) > 0.01 else { return true }
    if chrome.volumeHit.contains(point) || chrome.mute.contains(point) {
      nudgeVolume(delta, precise: event.hasPreciseScrollingDeltas)
    } else if chrome.seekHit.contains(point) {
      nudgeSeek(delta, precise: event.hasPreciseScrollingDeltas)
    }
    reveal()
    return true
  }

  func beginPress(at point: NSPoint, in bounds: NSRect) {
    let chrome = bar(in: bounds)
    activePress = chrome.control(at: point)
    switch activePress {
    case .seek:
      setSeek(fraction(point.x, in: chrome.seek))
    case .volume:
      setVolume(fraction(point.x, in: chrome.volume))
    default:
      break
    }
    hideTimer?.invalidate()
    hideTimer = nil
    redisplay()
  }

  func drag(to point: NSPoint, in bounds: NSRect) {
    let chrome = bar(in: bounds)
    switch activePress {
    case .seek:
      setSeek(fraction(point.x, in: chrome.seek))
    case .volume:
      setVolume(fraction(point.x, in: chrome.volume))
    default:
      break
    }
    redisplay()
  }

  func endPress(at point: NSPoint, in bounds: NSRect) {
    let chrome = bar(in: bounds)
    let hit = chrome.control(at: point)
    let press = activePress
    activePress = nil
    if hit == press {
      switch press {
      case .play:
        guard !PlayerCore.playerCores.isEmpty, PlayerCore.active.info.state.active else { break }
        PlayerCore.active.togglePause(nil)
      case .mute:
        toggleMute()
      case .stereo:
        Immersive3DController.shared.toggleEnabled(nil)
      case .channels:
        IPTVLiveOverlayController.shared.showChannelList()
      case .guide:
        IPTVLiveOverlayController.shared.showProgrammeGuide()
      default:
        break
      }
    }
    armHideTimer()
    redisplay()
  }

  func bar(in bounds: NSRect) -> GlassesEyeBar {
    GlassesEyeBar.layout(in: bounds, showsIPTV: IPTVLiveOverlayController.shared.session != nil)
  }

  // MARK: - Playback

  struct Playback {
    var playing = false
    var seekable = false
    var fraction: CGFloat = 0
    var volume: CGFloat = 0
    var muted = false
    var position = ""
    var duration = ""
    var stereoOn = false
  }

  func playback() -> Playback {
    var view = Playback()
    view.stereoOn = Preference.bool(for: .immersive3DEnabled)
    guard !PlayerCore.playerCores.isEmpty else { return view }
    let info = PlayerCore.active.info
    view.playing = info.state == .playing
    let duration = info.videoDuration?.second ?? 0
    let position = info.videoPosition?.second ?? 0
    let live = IPTVLiveOverlayController.shared.session != nil && IPTVLiveOverlayController.shared.session?.catchup == nil
    view.seekable = !live && duration.isFinite && duration > 1 && duration < 48 * 60 * 60
    if let seekHold, view.seekable {
      view.fraction = seekHold
    } else if view.seekable, duration > 0 {
      view.fraction = CGFloat(min(1, max(0, position / duration)))
    }
    view.position = view.seekable ? VideoTime(position).stringRepresentation : "LIVE"
    view.duration = view.seekable ? VideoTime(duration).stringRepresentation : ""
    let maxVolume = max(1, Preference.integer(for: .maxVolume))
    view.muted = muteHold ?? info.isMuted
    if let volumeHold {
      view.volume = volumeHold
    } else if view.muted {
      view.volume = 0
    } else {
      view.volume = CGFloat(min(1, max(0, info.volume / Double(maxVolume))))
    }
    return view
  }

  // MARK: - Private

  private func reveal() {
    attachIfNeeded()
    let becameVisible = !shown
    shown = true
    host.isHidden = false
    if becameVisible {
      startRefresh()
      if !PlayerCore.playerCores.isEmpty, PlayerCore.active.info.state.active {
        PlayerCore.active.syncUI(.time)
      }
      IPTVLiveOverlayController.shared.redraw()
    }
    armHideTimer()
    redisplay()
  }

  private func conceal() {
    guard shown || host.isHidden == false else { return }
    shown = false
    drawCursor = false
    activePress = nil
    seekHold = nil
    volumeHold = nil
    hideTimer?.invalidate()
    hideTimer = nil
    refreshTimer?.invalidate()
    refreshTimer = nil
    host.isHidden = true
    IPTVLiveOverlayController.shared.redraw()
  }

  private func detach() {
    conceal()
    showSystemCursor()
    pointerInside = false
    host.removeFromSuperview()
  }

  private func attachIfNeeded() {
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
    container.addSubview(host, positioned: .above, relativeTo: nil)
    if !shown { host.isHidden = true }
    host.layoutSubtreeIfNeeded()
  }

  private func armHideTimer() {
    hideTimer?.invalidate()
    hideTimer = nil
    guard shown, Preference.bool(for: .enableControlBarAutoHide) else { return }
    if activePress != nil { return }
    if bar(in: eyeBounds()).bar.contains(cursor) { return }
    let timeout = TimeInterval(Preference.float(for: .controlBarAutoHideTimeout))
    let interval = timeout > 0 ? timeout : 2.5
    let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
      self?.conceal()
    }
    hideTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func startRefresh() {
    refreshTimer?.invalidate()
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self, self.shown else { return }
      if !PlayerCore.playerCores.isEmpty, PlayerCore.active.info.state.active {
        PlayerCore.active.syncUI(.time)
      }
      if let muteHold = self.muteHold, !PlayerCore.playerCores.isEmpty, PlayerCore.active.info.isMuted == muteHold {
        self.muteHold = nil
      }
      if self.activePress != .seek { self.seekHold = nil }
      if self.activePress != .volume { self.volumeHold = nil }
      self.redisplay()
    }
    refreshTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func redisplay() {
    host.needsDisplay = true
    for pane in host.panes { pane.needsDisplay = true }
  }

  private func eyeBounds() -> NSRect {
    let width = host.bounds.width / 2
    return NSRect(x: 0, y: 0, width: max(0, width), height: host.bounds.height)
  }

  private func eyePoint(from event: NSEvent) -> NSPoint? {
    guard host.superview != nil else { return nil }
    let point = host.convert(event.locationInWindow, from: nil)
    let bounds = host.bounds
    let half = bounds.width / 2
    guard half > 1, bounds.height > 1 else { return nil }
    var x = point.x
    if x >= half { x -= half }
    if x < 0 { x = 0 }
    if x > half - 1 { x = half - 1 }
    let y = min(max(0, point.y), bounds.height - 1)
    return NSPoint(x: x, y: y)
  }

  private func pointerInsideWindow() -> Bool {
    guard !PlayerCore.playerCores.isEmpty, let window = PlayerCore.active.mainWindow.window else { return false }
    return window.frame.contains(NSEvent.mouseLocation)
  }

  private func fraction(_ x: CGFloat, in track: NSRect) -> CGFloat {
    guard track.width > 1 else { return 0 }
    return min(0.999, max(0, (x - track.minX) / track.width))
  }

  private func setSeek(_ fraction: CGFloat) {
    guard !PlayerCore.playerCores.isEmpty, PlayerCore.active.info.state.active else { return }
    let info = PlayerCore.active.info
    let duration = info.videoDuration?.second ?? 0
    let live = IPTVLiveOverlayController.shared.session != nil && IPTVLiveOverlayController.shared.session?.catchup == nil
    guard !live, duration.isFinite, duration > 1 else { return }
    seekHold = fraction
    PlayerCore.active.seek(percent: Double(fraction) * 100)
  }

  private func setVolume(_ fraction: CGFloat) {
    guard !PlayerCore.playerCores.isEmpty, PlayerCore.active.info.state.active else { return }
    volumeHold = fraction
    muteHold = false
    let maxVolume = Double(max(1, Preference.integer(for: .maxVolume)))
    PlayerCore.active.setVolume(Double(fraction) * maxVolume)
    if PlayerCore.active.info.isMuted {
      PlayerCore.active.toggleMute(false)
    }
  }

  private func nudgeVolume(_ delta: CGFloat, precise: Bool) {
    let current = volumeHold ?? playback().volume
    let step: CGFloat = precise ? delta * 0.004 : delta * 0.02
    setVolume(min(1, max(0, current + step)))
  }

  private func nudgeSeek(_ delta: CGFloat, precise: Bool) {
    guard !PlayerCore.playerCores.isEmpty, PlayerCore.active.info.state.active else { return }
    let live = IPTVLiveOverlayController.shared.session != nil && IPTVLiveOverlayController.shared.session?.catchup == nil
    let duration = PlayerCore.active.info.videoDuration?.second ?? 0
    guard !live, duration.isFinite, duration > 1 else { return }
    let seconds = precise ? Double(delta) * 0.15 : Double(delta < 0 ? -5 : 5)
    PlayerCore.active.seek(relativeSecond: seconds, option: .relative)
    seekHold = nil
  }

  private func toggleMute() {
    guard !PlayerCore.playerCores.isEmpty, PlayerCore.active.info.state.active else { return }
    let next = !(muteHold ?? PlayerCore.active.info.isMuted)
    muteHold = next
    PlayerCore.active.toggleMute(next)
  }

  private func hideSystemCursor() {
    guard !cursorHidden else { return }
    NSCursor.hide()
    cursorHidden = true
  }

  private func showSystemCursor() {
    guard cursorHidden else { return }
    NSCursor.unhide()
    cursorHidden = false
  }
}

final class GlassesEyeHost: NSView {
  let panes = [GlassesEyePane(), GlassesEyePane()]

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
    let duplicate = GlassesEyeControls.isSBS && bounds.width >= 640
    let slots = duplicate ? 2 : 1
    let width = bounds.width / CGFloat(slots)
    for (index, pane) in panes.enumerated() {
      let visible = index < slots && width >= 32 && bounds.height >= 32
      pane.isHidden = !visible
      if visible {
        pane.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
      }
    }
    if let scale = window?.backingScaleFactor, scale > 0 {
      layer?.contentsScale = scale
      panes.forEach { $0.layer?.contentsScale = scale }
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let controls = GlassesEyeControls.shared
    guard controls.shown, !isHidden else { return nil }
    let local = convert(point, from: superview)
    for pane in panes where !pane.isHidden && pane.frame.contains(local) {
      let panePoint = pane.convert(local, from: self)
      if controls.bar(in: pane.bounds).bar.contains(panePoint) {
        return pane
      }
    }
    return nil
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach { removeTrackingArea($0) }
    // Mouse-moved only. Entered/exited would fire again when this area is rebuilt
    // and hide the bar in the same turn it appeared. The window controller already
    // reports the pointer leaving the player window.
    addTrackingArea(NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseMoved, .inVisibleRect, .enabledDuringMouseDrag],
      owner: self,
      userInfo: nil
    ))
  }

  override func mouseMoved(with event: NSEvent) {
    _ = GlassesEyeControls.shared.handlePointer(event)
  }
}

final class GlassesEyePane: NSView {
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.masksToBounds = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    GlassesEyeControls.shared.beginPress(at: point, in: bounds)
  }

  override func mouseDragged(with event: NSEvent) {
    _ = GlassesEyeControls.shared.handlePointer(event)
    GlassesEyeControls.shared.drag(to: convert(event.locationInWindow, from: nil), in: bounds)
  }

  override func mouseUp(with event: NSEvent) {
    _ = GlassesEyeControls.shared.handlePointer(event)
    GlassesEyeControls.shared.endPress(at: convert(event.locationInWindow, from: nil), in: bounds)
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.setFill()
    dirtyRect.fill()
    let controls = GlassesEyeControls.shared
    guard controls.shown else { return }
    let chrome = controls.bar(in: bounds)
    let playback = controls.playback()
    drawBar(chrome, playback: playback, pressed: controls.activePress)
    if controls.drawCursor, bounds.contains(controls.cursor) {
      GlassesEyeDraw.cursor(at: controls.cursor)
    }
  }

  private func drawBar(_ chrome: GlassesEyeBar, playback: GlassesEyeControls.Playback, pressed: GlassesEyePress?) {
    guard chrome.bar.width > 40 else { return }
    IPTVLiveDraw.panel(chrome.bar, radius: 12)
    drawButton(chrome.play, title: nil, on: false, pressed: pressed == .play)
    GlassesEyeDraw.transport(in: chrome.play, playing: playback.playing)
    IPTVLiveDraw.text(playback.position, in: chrome.currentTime, font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: .white, align: .center)
    IPTVLiveDraw.progress(playback.seekable ? playback.fraction : 0, in: chrome.seek)
    if playback.seekable {
      let knobX = chrome.seek.minX + chrome.seek.width * playback.fraction
      GlassesEyeDraw.knob(at: NSPoint(x: knobX, y: chrome.seek.midY))
    }
    IPTVLiveDraw.text(playback.duration, in: chrome.duration, font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: NSColor(calibratedWhite: 1, alpha: 0.8), align: .center)
    drawButton(chrome.mute, title: nil, on: false, pressed: pressed == .mute)
    GlassesEyeDraw.speaker(in: chrome.mute, muted: playback.muted)
    IPTVLiveDraw.progress(playback.volume, in: chrome.volume)
    let volumeKnob = chrome.volume.minX + chrome.volume.width * playback.volume
    GlassesEyeDraw.knob(at: NSPoint(x: volumeKnob, y: chrome.volume.midY))
    drawButton(chrome.stereo, title: "3D", on: playback.stereoOn, pressed: pressed == .stereo)
    if chrome.channels.width > 1 {
      drawButton(chrome.channels, title: "Ch", on: false, pressed: pressed == .channels)
    }
    if chrome.guide.width > 1 {
      drawButton(chrome.guide, title: "EPG", on: false, pressed: pressed == .guide)
    }
  }

  private func drawButton(_ rect: NSRect, title: String?, on: Bool, pressed: Bool) {
    guard rect.width > 8 else { return }
    let color: NSColor
    if on {
      color = NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.90, alpha: pressed ? 1 : 0.9)
    } else {
      color = NSColor(calibratedWhite: 1, alpha: pressed ? 0.32 : 0.16)
    }
    IPTVLiveDraw.fill(rect, radius: 6, color: color)
    if let title {
      IPTVLiveDraw.text(title, in: rect.insetBy(dx: 2, dy: 4), font: .systemFont(ofSize: 12, weight: .semibold), color: .white, align: .center)
    }
  }
}

private enum GlassesEyeDraw {
  static func knob(at point: NSPoint) {
    let rect = NSRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: rect).fill()
  }

  static func transport(in rect: NSRect, playing: Bool) {
    NSColor.white.setFill()
    let inset = rect.insetBy(dx: rect.width * 0.30, dy: rect.height * 0.28)
    if playing {
      let width = inset.width * 0.34
      NSRect(x: inset.minX, y: inset.minY, width: width, height: inset.height).fill()
      NSRect(x: inset.maxX - width, y: inset.minY, width: width, height: inset.height).fill()
    } else {
      let path = NSBezierPath()
      path.move(to: NSPoint(x: inset.minX, y: inset.minY))
      path.line(to: NSPoint(x: inset.maxX, y: inset.midY))
      path.line(to: NSPoint(x: inset.minX, y: inset.maxY))
      path.close()
      path.fill()
    }
  }

  static func speaker(in rect: NSRect, muted: Bool) {
    let color = muted ? NSColor(calibratedWhite: 1, alpha: 0.45) : NSColor.white
    color.setFill()
    color.setStroke()
    let body = rect.insetBy(dx: rect.width * 0.28, dy: rect.height * 0.32)
    NSRect(x: body.minX, y: body.minY + body.height * 0.25, width: body.width * 0.35, height: body.height * 0.5).fill()
    let cone = NSBezierPath()
    cone.move(to: NSPoint(x: body.minX + body.width * 0.35, y: body.minY + body.height * 0.25))
    cone.line(to: NSPoint(x: body.minX + body.width * 0.72, y: body.minY))
    cone.line(to: NSPoint(x: body.minX + body.width * 0.72, y: body.maxY))
    cone.line(to: NSPoint(x: body.minX + body.width * 0.35, y: body.minY + body.height * 0.75))
    cone.close()
    cone.fill()
    if muted {
      let slash = NSBezierPath()
      slash.move(to: NSPoint(x: body.minX, y: body.minY))
      slash.line(to: NSPoint(x: body.maxX, y: body.maxY))
      slash.lineWidth = 1.4
      slash.stroke()
    }
  }

  static func cursor(at tip: NSPoint) {
    let path = NSBezierPath()
    path.move(to: tip)
    path.line(to: NSPoint(x: tip.x, y: tip.y + 16))
    path.line(to: NSPoint(x: tip.x + 4.5, y: tip.y + 12.5))
    path.line(to: NSPoint(x: tip.x + 7.2, y: tip.y + 18))
    path.line(to: NSPoint(x: tip.x + 9.8, y: tip.y + 16.8))
    path.line(to: NSPoint(x: tip.x + 7, y: tip.y + 11.2))
    path.line(to: NSPoint(x: tip.x + 12, y: tip.y + 11))
    path.close()
    NSColor.white.setFill()
    path.fill()
    NSColor.black.setStroke()
    path.lineWidth = 1.1
    path.stroke()
  }
}
