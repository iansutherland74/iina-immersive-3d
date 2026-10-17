//
//  BrowserCaptureManager.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  One window, or a whole display, captured with the public ScreenCaptureKit
//  API. On macOS 13 and later the same stream can include that source's audio.
//  Protected video that macOS returns black is reported and left black.
//
//  Window listing, re-finding a window after it goes full screen, frame status,
//  and buffer lifetime follow OBS Studio's ScreenCaptureKit capture
//  (plugins/mac-capture/mac-sck-common.m, mac-sck-video-capture.m,
//  mac-sck-audio-capture.m, window-utils.m). OBS is GPLv2-or-later.

import Cocoa
import CoreMedia
import CoreVideo
import os
import ScreenCaptureKit

let browserCaptureLog = os.Logger(subsystem: "com.colliderli.iina", category: "BrowserCapture")

enum BrowserCaptureKind {
  case window
  case display
}

struct BrowserCaptureTarget {
  var kind: BrowserCaptureKind
  var id: CGWindowID
  var displayID: CGDirectDisplayID
  var title: String
  var owner: String
  var bundleID: String
  var width: Int
  var height: Int

  var key: String {
    switch kind {
    case .window: return "w\(id)"
    case .display: return "d\(displayID)"
    }
  }

  var label: String {
    switch kind {
    case .display:
      if owner.isEmpty { return "Capture whole display" }
      return "Capture whole display — \(owner)"
    case .window:
      let name = title.isEmpty ? "Window" : title
      return "\(owner) — \(name)  \(width)×\(height)"
    }
  }
}

private struct DelayedFrame {
  var buffer: CVPixelBuffer
  var time: CMTime
  var received: CFTimeInterval
}

@available(macOS 12.3, *)
final class BrowserCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
  static let shared = BrowserCaptureManager()

  static let protectedMessage = "This window is black because macOS is not sharing its picture. Protected video (DRM) stays black. IINA uses only the normal screen capture and does not try to bypass that. Choose a window whose picture is visible, or open the file in IINA."
  static let muteNeedsNewerOS = "Muting another app needs macOS 14.2. Until then the other app keeps playing, and IINA plays the capture too."

  private let queue = DispatchQueue(label: "com.colliderli.iina.browser-capture", qos: .userInteractive)
  private let audioQueue = DispatchQueue(label: "com.colliderli.iina.browser-capture-audio-in", qos: .userInteractive)
  private let audioPlayer = BrowserCaptureAudioPlayer()
  private let loopback = CaptureLoopbackReader()
  private var routedAudio = false
  private var latencySmooth = CaptureLatencySmooth()
  private let sessionLock = NSLock()
  private var stream: SCStream?
  private var configuration: SCStreamConfiguration?
  private var running = false
  private var accepting = false
  private var shouldRun = false
  private var sessionBusy = false
  private var ignoreStop = false
  private var epoch = 0
  private var restartAttempts = 0
  private var excludedIDs = Set<CGWindowID>()
  private var followTimer: DispatchSourceTimer?
  private var redrawTimer: DispatchSourceTimer?
  private var loggedFirstFrame = false
  private var framesInWindow = 0
  private var windowStarted = CACurrentMediaTime()
  private var lastComplete = CACurrentMediaTime()
  private(set) var currentID: CGWindowID?
  private(set) var activeTarget: BrowserCaptureTarget?
  private var trackedBundle = ""
  private var trackedOwner = ""
  private var trackedTitle = ""
  private var trackedDisplay: CGDirectDisplayID = 0
  private var followClock = CaptureFollowClock.empty
  private let frameLock = NSLock()
  private let drawQueue = DispatchQueue(label: "com.colliderli.iina.browser-capture-draw", qos: .userInteractive)
  private var latestOwned: CVPixelBuffer?
  private var latestTime = CMTime.invalid
  private var latestReceived: CFTimeInterval = 0
  private var drawBusy = false
  private var videoHold = 0.0
  private var delayQueue = CaptureVideoDelayQueue()
  private var delayBuffers: [Int: DelayedFrame] = [:]
  private var delaySerial = 0
  private var holdWake = 0
  private(set) var sourcePID: pid_t?
  private(set) var audioActive = false

  /// Called on the draw queue with a pixel buffer this process owns, and the time the copy was made.
  var onFrame: ((CVPixelBuffer, CMTime, CFTimeInterval, @escaping () -> Void) -> Void)?
  /// Called on the capture queue when the source did not send a new picture.
  var onIdle: (() -> Void)?
  var onStatus: ((String?) -> Void)?
  var onNote: ((String) -> Void)?
  var onMuteChanged: (() -> Void)?
  /// The stream gave up after an error. The glasses session drops the capture source.
  var onStopped: (() -> Void)?
  /// Read on the main thread. Window numbers are AppKit objects.
  var excludedWindowIDs: () -> Set<CGWindowID> = { [] }

  private override init() {
    super.init()
    audioPlayer.onNote = { [weak self] text in
      self?.onNote?(text)
    }
    audioPlayer.onStatus = { [weak self] text in
      self?.onStatus?(text)
    }
  }

  func permissionGranted() -> Bool {
    CGPreflightScreenCaptureAccess()
  }

  /// Shows the system Screen Recording prompt when it has not been decided.
  func requestPermission() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    return CGRequestScreenCaptureAccess()
  }

  func targets(excluding ids: Set<CGWindowID>) async throws -> [BrowserCaptureTarget] {
    let content = try await loadContent()
    var rows = Self.displayTargets(in: content)
    rows.append(contentsOf: Self.windowTargets(in: content, excluding: ids))
    return rows
  }

  func start(_ target: BrowserCaptureTarget, excluding ids: Set<CGWindowID>) async throws {
    await waitForSession()
    defer { endSession() }
    shouldRun = true
    restartAttempts = 0
    epoch += 1
    excludedIDs = ids
    do {
      try await openStream(target, excluding: ids, token: epoch)
    } catch {
      shouldRun = false
      ignoreStop = false
      throw error
    }
  }

  func stop() async {
    await waitForSession()
    defer { endSession() }
    shouldRun = false
    epoch += 1
    await tearDown(clearTarget: true)
  }

  var isRunning: Bool { running }

  func notePresentedVideo(_ time: CMTime) {
    guard audioActive, !routedAudio else { return }
    audioPlayer.notePresentedVideo(time)
  }

  func noteCaptureLatency(_ seconds: Double) {
    guard routedAudio else { return }
    audioPlayer.setHostDelay(latencySmooth.observe(seconds))
  }

  func noteSyncOffset(_ ms: Int) {
    audioPlayer.setSyncOffset(ms: ms)
  }

  /// Positive audio sync offset. Frames stay in the queue until they are this old.
  /// Buffers that leave the queue are released on the draw queue. Releasing an
  /// IOSurface-backed buffer on the main thread puts an Objective-C object in
  /// the event autorelease pool, and the pool's objc_release crashes at 0x20.
  func noteVideoHold(_ seconds: Double) {
    let clamped = min(max(seconds.isFinite ? seconds : 0, 0), 2)
    frameLock.lock()
    var dropped: [CVPixelBuffer] = []
    if !accepting {
      videoHold = clamped
      delayQueue.hold = clamped
      dropped = discardQueuedFramesLocked()
      frameLock.unlock()
      releaseOnDrawQueue(dropped)
      return
    }
    if clamped <= 0.0005 {
      holdWake += 1
      videoHold = 0
      if let newest = delayQueue.waiting.last, let frame = delayBuffers.removeValue(forKey: newest.id) {
        if let previous = latestOwned {
          dropped.append(previous)
        }
        latestOwned = frame.buffer
        latestTime = frame.time
        latestReceived = frame.received
      }
      delayQueue.flush()
      delayQueue.hold = 0
      dropped.append(contentsOf: takeDroppedBuffersLocked())
    } else {
      holdWake += 1
      videoHold = clamped
      delayQueue.hold = clamped
      if let buffer = latestOwned {
        delaySerial += 1
        let id = delaySerial
        delayBuffers[id] = DelayedFrame(buffer: buffer, time: latestTime, received: latestReceived)
        delayQueue.push(id: id, received: latestReceived)
        latestOwned = nil
      }
      dropped = takeDroppedBuffersLocked()
    }
    frameLock.unlock()
    releaseOnDrawQueue(dropped)
    scheduleDrain()
  }

  var hasPendingFrame: Bool {
    frameLock.lock()
    defer { frameLock.unlock() }
    return latestOwned != nil
  }

  @discardableResult
  func startRoutedAudio(realUID: String) -> Bool {
    loopback.onSamples = { [weak self] buffer, host in
      self?.audioPlayer.consumeHostClock(buffer, hostTime: host)
    }
    latencySmooth = CaptureLatencySmooth()
    audioPlayer.beginHostClock(pinnedUID: realUID)
    audioPlayer.setSyncOffset(ms: BrowserCaptureSettings.shared.syncOffsetMs)
    guard loopback.start() else {
      audioPlayer.stop()
      routedAudio = false
      browserCaptureLog.error("IINA Capture Audio did not start")
      return false
    }
    routedAudio = true
    return true
  }

  func stopRoutedAudio() {
    loopback.stop()
    audioPlayer.stop()
    routedAudio = false
  }

  /// The capture window moved onto the glasses. Keep reading the loopback and
  /// open the output again on the device saved before the switch.
  func reopenLoopbackOutput() {
    guard routedAudio else { return }
    audioPlayer.reopenOutput()
  }

  var routedAudioIsRunning: Bool { routedAudio }

  func perform(_ block: @escaping () -> Void) {
    queue.async(execute: block)
  }

  /// Depth and present run here, off the sample queue, so a slow frame does not pile up behind itself.
  func performDraw(_ block: @escaping () -> Void) {
    drawQueue.async(execute: block)
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    if #available(macOS 13.0, *), type == .audio {
      guard accepting else { return }
      // Copy inside the callback. ScreenCaptureKit reuses the sample buffer
      // after this returns; OBS reads the block buffer before returning.
      audioPlayer.consumeCapture(sampleBuffer)
      return
    }
    guard type == .screen else { return }
    let status = Self.frameStatus(of: sampleBuffer)
    let image = CMSampleBufferGetImageBuffer(sampleBuffer)
    noteFrame(status: status, hasImage: image != nil)
    guard accepting else { return }
    if status == .blank {
      DispatchQueue.main.async { [weak self] in
        self?.onStatus?(Self.protectedMessage)
      }
      deliverIdle()
      return
    }
    // Copy inside this callback, then return. The draw queue keeps only the newest
    // buffer so a slow depth pass does not play the frames that queued behind it.
    let received = CACurrentMediaTime()
    if status != .idle, let image, let owned = autoreleasepool(invoking: { Self.ownedCopy(of: image) }) {
      lastComplete = received
      publishFrame(owned, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), received: received)
      return
    }
    if image != nil && status != .idle {
      browserCaptureLog.error("frame copy failed status=\(Self.statusName(status), privacy: .public)")
    }
    deliverIdle()
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    let text = error.localizedDescription
    browserCaptureLog.error("stream stopped: \(text, privacy: .public)")
    log3D("Browser capture stopped: \(text)", level: .error)
    // A stop we asked for has already dropped this stream. Restart only when the live stream dies, which is what OBS does after SCStreamError.
    guard shouldRun, !ignoreStop, stream === self.stream else { return }
    accepting = false
    running = false
    closeFrameQueue(resetHold: false)
    let token = epoch
    Task { [weak self] in
      await self?.recover(from: text, token: token)
    }
  }

  private func openStream(_ target: BrowserCaptureTarget, excluding ids: Set<CGWindowID>, token: Int) async throws {
    await tearDown(clearTarget: false)
    guard token == epoch else { return }
    let content = try await loadContent()
    guard token == epoch else { return }
    let resolved = try Self.resolve(target, in: content, excluding: ids)
    let configuration = SCStreamConfiguration()
    configuration.width = resolved.pixelWidth
    configuration.height = resolved.pixelHeight
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = false
    // Three frames is enough for the capture to stay smooth. Eight frames sat
    // behind the depth pass and showed up as extra latency on the glasses.
    configuration.queueDepth = 3
    var captureAudio = false
    if #available(macOS 13.0, *) {
      // The loopback is the only played copy. ScreenCaptureKit audio would be
      // a second one, so it stays off while the route is on and while it is off.
      captureAudio = CaptureAudioPolicy.shouldCaptureAudio(
        userEnabled: BrowserCaptureSettings.shared.wantsAudio,
        virtualDevicePresent: CaptureSystemOutput.ourDeviceInstalled()
      )
      configuration.capturesAudio = captureAudio
      configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
      if captureAudio {
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
      }
    }
    if #available(macOS 14.2, *), resolved.target.kind == .window {
      configuration.includeChildWindows = true
    }
    let stream = SCStream(filter: resolved.filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    var audioProblem: String?
    if #available(macOS 13.0, *), captureAudio {
      do {
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
      } catch {
        captureAudio = false
        audioProblem = "Window audio did not start (\(error.localizedDescription)). The picture still captures, and sound stays in the other app."
        browserCaptureLog.error("audio output failed: \(error.localizedDescription, privacy: .public)")
      }
    }
    self.stream = stream
    self.configuration = configuration
    activeTarget = resolved.target
    currentID = resolved.target.kind == .window ? resolved.target.id : nil
    sourcePID = resolved.pid
    if resolved.target.kind == .window {
      trackedBundle = resolved.target.bundleID
      trackedOwner = resolved.target.owner
      trackedTitle = resolved.target.title
      let frame = content.windows.first { $0.windowID == resolved.target.id }?.frame ?? .zero
      trackedDisplay = Self.displayID(covering: frame, displays: content.displays)
    } else {
      trackedBundle = ""
      trackedOwner = ""
      trackedTitle = ""
      trackedDisplay = resolved.target.displayID
    }
    followClock = .empty
    loggedFirstFrame = false
    framesInWindow = 0
    windowStarted = CACurrentMediaTime()
    lastComplete = CACurrentMediaTime()
    accepting = true
    do {
      try await start(stream)
    } catch {
      accepting = false
      closeFrameQueue(resetHold: false)
      ignoreStop = false
      self.stream = nil
      self.configuration = nil
      currentID = nil
      activeTarget = nil
      sourcePID = nil
      browserCaptureLog.error("startCapture failed: \(error.localizedDescription, privacy: .public)")
      throw error
    }
    guard token == epoch else {
      await tearDown(clearTarget: true)
      return
    }
    running = true
    ignoreStop = false
    audioActive = captureAudio
    armFollow()
    armRedraw()
    if let audioProblem {
      let note = onNote
      DispatchQueue.main.async {
        note?(audioProblem)
      }
    }
    let kind = resolved.target.kind == .display ? "display" : "window"
    browserCaptureLog.info("startCapture completed \(kind, privacy: .public) \(resolved.pixelWidth)x\(resolved.pixelHeight) audio=\(captureAudio)")
    log3D("Browser capture started for \(kind) \(resolved.target.id) at \(resolved.pixelWidth)x\(resolved.pixelHeight) audio=\(captureAudio)", level: .debug)
  }

  private func tearDown(clearTarget: Bool) async {
    ignoreStop = true
    accepting = false
    running = false
    audioActive = false
    if clearTarget {
      CaptureAVSyncTest.shared.stop()
    }
    // Drop held frames before audio teardown. stop() calls noteVideoHold(0),
    // and that must not present a frame or release buffers on this thread.
    closeFrameQueue(resetHold: clearTarget)
    followTimer?.cancel()
    followTimer = nil
    redrawTimer?.cancel()
    redrawTimer = nil
    audioPlayer.setSourceMuteActive(false)
    if clearTarget {
      let restore = {
        CaptureAudioRouteController.end()
      }
      if Thread.isMainThread {
        restore()
      } else {
        DispatchQueue.main.sync(execute: restore)
      }
      stopRoutedAudio()
    }
    if #available(macOS 14.2, *) {
      BrowserCaptureSourceMute.shared.stop()
    }
    if clearTarget {
      currentID = nil
      activeTarget = nil
      sourcePID = nil
      trackedBundle = ""
      trackedOwner = ""
      trackedTitle = ""
      trackedDisplay = 0
      followClock = .empty
    }
    guard let stream else { return }
    self.stream = nil
    configuration = nil
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      stream.stopCapture { error in
        if let error {
          browserCaptureLog.error("stopCapture: \(error.localizedDescription, privacy: .public)")
        }
        continuation.resume()
      }
    }
  }

  /// OBS restarts a stream that stopped with an error (`reactivate_capture` in mac-sck-audio-capture.m). A few tries, then the status line.
  private func recover(from text: String, token: Int) async {
    await waitForSession()
    defer { endSession() }
    guard shouldRun, token == epoch, let target = activeTarget else { return }
    var message = text
    while shouldRun && token == epoch {
      restartAttempts += 1
      if restartAttempts > 3 {
        shouldRun = false
        await tearDown(clearTarget: true)
        let status = onStatus
        let stopped = onStopped
        DispatchQueue.main.async {
          status?(message)
          stopped?()
        }
        return
      }
      browserCaptureLog.info("restarting stream attempt \(self.restartAttempts) after \(message, privacy: .public)")
      let ids = await MainActor.run { self.excludedWindowIDs() }
      guard token == epoch else { return }
      excludedIDs = ids
      do {
        try await openStream(target, excluding: ids, token: token)
        return
      } catch {
        message = error.localizedDescription
        browserCaptureLog.error("restart failed: \(message, privacy: .public)")
      }
    }
  }

  /// Every half second, the same interval OBS uses in `find_window`. The current id stays selected while it exists, including when full screen moves it to another Space. An untitled placeholder is not a new target. A missing id waits 1.5 seconds before the filter changes, and the filter is not updated when the id did not change.
  private func followTrackedWindow(token: Int) async {
    guard beginSession() else { return }
    defer { endSession() }
    guard shouldRun, token == epoch, let target = activeTarget else { return }
    let followingWindow = target.kind == .window || !trackedBundle.isEmpty || !trackedOwner.isEmpty
    guard followingWindow else { return }
    let ids = await MainActor.run { self.excludedWindowIDs() }
    guard token == epoch else { return }
    excludedIDs = ids
    let content: SCShareableContent
    do {
      content = try await loadContent()
    } catch {
      browserCaptureLog.error("window follow failed: \(error.localizedDescription, privacy: .public)")
      return
    }
    guard token == epoch, shouldRun else { return }
    let windows = content.windows.filter { Self.isFollowableWindow($0, excluding: ids) }
    let records = windows.map { Self.record($0, displays: content.displays) }
    let track = CaptureTrack(
      kind: target.kind == .display ? .display : .window,
      windowID: target.kind == .window ? target.id : 0,
      title: trackedTitle,
      owner: trackedOwner,
      bundleID: trackedBundle,
      displayID: trackedDisplay
    )
    let outcome = CaptureWindowMatch.decide(
      track: track,
      windows: records,
      displayIDs: content.displays.map(\.displayID),
      now: CACurrentMediaTime(),
      clock: followClock
    )
    followClock = outcome.clock
    switch outcome.decision {
    case .keep:
      if let current = windows.first(where: { $0.windowID == target.id }), target.kind == .window {
        let display = Self.displayID(covering: current.frame, displays: content.displays)
        if display != 0 { trackedDisplay = display }
        let title = current.title ?? ""
        if !title.isEmpty { trackedTitle = title }
      }
    case .window(let found, let reason):
      if target.kind == .window && target.id == found.id {
        if !found.title.isEmpty { trackedTitle = found.title }
        return
      }
      guard let window = windows.first(where: { $0.windowID == found.id }) else { return }
      browserCaptureLog.info("\(reason, privacy: .public)")
      var updated = target
      updated.kind = .window
      updated.id = window.windowID
      let title = window.title ?? found.title
      updated.title = title.isEmpty ? trackedTitle : title
      updated.owner = window.owningApplication?.applicationName ?? found.owner
      updated.bundleID = window.owningApplication?.bundleIdentifier ?? found.bundleID
      updated.width = found.width
      updated.height = found.height
      if !title.isEmpty { trackedTitle = title }
      trackedOwner = updated.owner
      trackedBundle = updated.bundleID
      if found.displayID != 0 { trackedDisplay = found.displayID }
      await retarget(updated, window: window, holding: content, token: token)
    case .display(let displayID, let reason):
      if target.kind == .display && target.displayID == displayID { return }
      guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return }
      browserCaptureLog.info("\(reason, privacy: .public)")
      let skip = content.windows.filter { ids.contains($0.windowID) }
      await retargetDisplay(display, excluding: skip, holding: content, token: token)
    }
  }

  private func retargetDisplay(_ display: SCDisplay, excluding skip: [SCWindow], holding content: SCShareableContent, token: Int) async {
    guard token == epoch, let stream else { return }
    let filter = SCContentFilter(display: display, excludingWindows: skip)
    let updated = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      stream.updateContentFilter(filter) { error in
        // The filter and the shareable content stay alive until this callback
        // returns. Releasing them as the main pool pops, while ScreenCaptureKit
        // still has the same objects, is the objc_release crash.
        withExtendedLifetime(content) {}
        withExtendedLifetime(filter) {}
        withExtendedLifetime(skip) {}
        if let error {
          browserCaptureLog.error("updateContentFilter failed: \(error.localizedDescription, privacy: .public)")
          continuation.resume(returning: false)
        } else {
          continuation.resume(returning: true)
        }
      }
    }
    guard updated, token == epoch else { return }
    var target = activeTarget ?? BrowserCaptureTarget(
      kind: .display,
      id: 0,
      displayID: display.displayID,
      title: "Capture whole display",
      owner: "",
      bundleID: trackedBundle,
      width: Int(display.width),
      height: Int(display.height)
    )
    target.kind = .display
    target.id = 0
    target.displayID = display.displayID
    target.title = "Capture whole display"
    let size = Self.clampedPixels(Int(display.width), Int(display.height))
    target.width = size.width
    target.height = size.height
    activeTarget = target
    currentID = nil
    trackedDisplay = display.displayID
    configuration?.width = size.width
    configuration?.height = size.height
    if let configuration {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        stream.updateConfiguration(configuration) { error in
          if let error {
            browserCaptureLog.error("updateConfiguration failed: \(error.localizedDescription, privacy: .public)")
          }
          continuation.resume()
        }
      }
    }
    browserCaptureLog.info("capturing display \(display.displayID) \(size.width)x\(size.height)")
  }

  private func retarget(_ target: BrowserCaptureTarget, window: SCWindow, holding content: SCShareableContent, token: Int) async {
    guard token == epoch, let stream else { return }
    browserCaptureLog.info("window id changed to \(window.windowID) app=\(target.owner, privacy: .public) title=\(target.title, privacy: .public)")
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let updated = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      stream.updateContentFilter(filter) { error in
        withExtendedLifetime(content) {}
        withExtendedLifetime(filter) {}
        withExtendedLifetime(window) {}
        if let error {
          browserCaptureLog.error("updateContentFilter failed: \(error.localizedDescription, privacy: .public)")
          continuation.resume(returning: false)
        } else {
          continuation.resume(returning: true)
        }
      }
    }
    guard updated, token == epoch else { return }
    activeTarget = target
    currentID = window.windowID
    sourcePID = window.owningApplication?.processID
    let size = Self.pixelSize(for: window)
    configuration?.width = size.width
    configuration?.height = size.height
    if let configuration {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        stream.updateConfiguration(configuration) { error in
          if let error {
            browserCaptureLog.error("updateConfiguration failed: \(error.localizedDescription, privacy: .public)")
          }
          continuation.resume()
        }
      }
    }
  }

  /// Replaces any frame the draw queue has not started. One draw runs at a time; the next draw is the newest copy.
  /// A positive sync offset keeps frames until they are old enough, and draws the newest one that has waited.
  private func publishFrame(_ buffer: CVPixelBuffer, time: CMTime, received: CFTimeInterval) {
    frameLock.lock()
    guard accepting else {
      frameLock.unlock()
      releaseOnDrawQueue([buffer])
      return
    }
    var dropped: [CVPixelBuffer] = []
    if videoHold > 0.0005 {
      delaySerial += 1
      let id = delaySerial
      delayBuffers[id] = DelayedFrame(buffer: buffer, time: time, received: received)
      delayQueue.hold = videoHold
      delayQueue.push(id: id, received: received)
      dropped = takeDroppedBuffersLocked()
    } else {
      if let previous = latestOwned {
        dropped.append(previous)
      }
      latestOwned = buffer
      latestTime = time
      latestReceived = received
    }
    let start = !drawBusy
    if start { drawBusy = true }
    frameLock.unlock()
    releaseOnDrawQueue(dropped)
    if start {
      drawQueue.async { [weak self] in
        self?.drainFrames()
      }
    }
  }

  private func scheduleDrain() {
    drawQueue.async { [weak self] in
      guard let self else { return }
      self.frameLock.lock()
      guard self.accepting else {
        self.frameLock.unlock()
        return
      }
      let start = !self.drawBusy
      if start { self.drawBusy = true }
      self.frameLock.unlock()
      if start { self.drainFrames() }
    }
  }

  private func drainFrames() {
    frameLock.lock()
    if !accepting {
      let dropped = discardQueuedFramesLocked()
      drawBusy = false
      frameLock.unlock()
      releaseOnDrawQueue(dropped)
      return
    }
    if videoHold > 0.0005 {
      delayQueue.hold = videoHold
      let now = CACurrentMediaTime()
      guard let ticket = delayQueue.popDue(now: now), let frame = delayBuffers.removeValue(forKey: ticket.id) else {
        let wait = delayQueue.timeUntilDue(now: now)
        drawBusy = false
        frameLock.unlock()
        if let wait { scheduleHoldDrain(after: wait) }
        return
      }
      let dropped = takeDroppedBuffersLocked()
      frameLock.unlock()
      releaseOnDrawQueue(dropped)
      deliver(frame.buffer, time: frame.time, received: frame.received)
      return
    }
    guard let buffer = latestOwned else {
      drawBusy = false
      frameLock.unlock()
      return
    }
    let time = latestTime
    let received = latestReceived
    latestOwned = nil
    frameLock.unlock()
    deliver(buffer, time: time, received: received)
  }

  private func deliver(_ buffer: CVPixelBuffer, time: CMTime, received: CFTimeInterval) {
    let done: () -> Void = { [weak self] in
      guard let self else { return }
      self.drawQueue.async {
        self.drainFrames()
      }
    }
    frameLock.lock()
    let running = accepting
    frameLock.unlock()
    // Capture has stopped. Drop the buffer on this queue instead of presenting it.
    if running, let onFrame {
      onFrame(buffer, time, received, done)
    } else {
      done()
    }
  }

  private func scheduleHoldDrain(after seconds: Double) {
    frameLock.lock()
    holdWake += 1
    let token = holdWake
    frameLock.unlock()
    drawQueue.asyncAfter(deadline: .now() + seconds) { [weak self] in
      guard let self else { return }
      self.frameLock.lock()
      guard token == self.holdWake, self.accepting else {
        self.frameLock.unlock()
        return
      }
      let start = !self.drawBusy
      if start { self.drawBusy = true }
      self.frameLock.unlock()
      if start { self.drainFrames() }
    }
  }

  /// Cancels a pending hold timer and takes every queued buffer. Caller holds `frameLock`.
  private func discardQueuedFramesLocked() -> [CVPixelBuffer] {
    holdWake += 1
    delayQueue.flush()
    var dropped: [CVPixelBuffer] = []
    dropped.reserveCapacity(delayBuffers.count + 1)
    for frame in delayBuffers.values {
      dropped.append(frame.buffer)
    }
    delayBuffers.removeAll()
    if let latest = latestOwned {
      dropped.append(latest)
      latestOwned = nil
    }
    return dropped
  }

  /// Buffers whose tickets the delay queue already dropped. Caller holds `frameLock`.
  private func takeDroppedBuffersLocked() -> [CVPixelBuffer] {
    let live = Set(delayQueue.waiting.map(\.id))
    var dropped: [CVPixelBuffer] = []
    for (id, frame) in delayBuffers where !live.contains(id) {
      dropped.append(frame.buffer)
    }
    if !dropped.isEmpty {
      delayBuffers = delayBuffers.filter { live.contains($0.key) }
    }
    return dropped
  }

  /// `resetHold` is the full capture stop. A stream restart keeps the offset and only drops pictures.
  private func closeFrameQueue(resetHold: Bool) {
    frameLock.lock()
    accepting = false
    if resetHold {
      videoHold = 0
      delayQueue.hold = 0
    }
    let dropped = discardQueuedFramesLocked()
    frameLock.unlock()
    releaseOnDrawQueue(dropped)
  }

  /// The last retain is released on the draw queue, after any in-flight texture built from the buffer.
  private func releaseOnDrawQueue(_ buffers: [CVPixelBuffer]) {
    guard !buffers.isEmpty else { return }
    drawQueue.async {
      withExtendedLifetime(buffers) {}
    }
  }

  private func deliverIdle() {
    drawQueue.async { [weak self] in
      guard let self, self.accepting else { return }
      self.onIdle?()
    }
  }

  private func armFollow() {
    followTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    let token = epoch
    timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      Task { await self.followTrackedWindow(token: token) }
    }
    followTimer = timer
    timer.resume()
  }

  /// Static pictures often produce no ScreenCaptureKit callback. Redraw the last frame so the glasses do not freeze. The timer is the capture queue, not the main thread.
  private func armRedraw() {
    redrawTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 0.1, repeating: 1.0 / 30.0)
    timer.setEventHandler { [weak self] in
      guard let self, self.accepting else { return }
      if CACurrentMediaTime() - self.lastComplete < 0.05 { return }
      self.deliverIdle()
    }
    redrawTimer = timer
    timer.resume()
  }

  private func noteFrame(status: SCFrameStatus?, hasImage: Bool) {
    framesInWindow += 1
    if !loggedFirstFrame {
      loggedFirstFrame = true
      browserCaptureLog.info("first frame status=\(Self.statusName(status), privacy: .public) image=\(hasImage)")
    }
    let now = CACurrentMediaTime()
    if now - windowStarted >= 1 {
      let count = framesInWindow
      framesInWindow = 0
      windowStarted = now
      browserCaptureLog.info("frames \(count)/s status=\(Self.statusName(status), privacy: .public)")
    }
  }

  /// OBS lists windows with `getShareableContentExcludingDesktopWindows:YES`. `onScreenWindowsOnly:NO` keeps full-screen windows that live on another Space. The default OBS flag is the opposite unless "show hidden windows" is on; full-screen Chrome is on another Space, so it has to be off here.
  private func loadContent() async throws -> SCShareableContent {
    try await withCheckedThrowingContinuation { continuation in
      SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
        if let content {
          continuation.resume(returning: content)
        } else {
          let text = error?.localizedDescription ?? "Screen capture is not available."
          browserCaptureLog.error("shareable content failed: \(text, privacy: .public)")
          continuation.resume(throwing: error ?? CaptureFailure(text))
        }
      }
    }
  }

  private func start(_ stream: SCStream) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      stream.startCapture { error in
        if let error {
          browserCaptureLog.error("startCapture completion: \(error.localizedDescription, privacy: .public)")
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  /// `CMSampleBufferGetSampleAttachmentsArray` is not owned by the caller. OBS reads it with `CFArrayGetValueAtIndex` and does not bridge it to a Foundation array, which would release it again when the autorelease pool pops.
  private static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) else { return nil }
    guard CFArrayGetCount(attachments) > 0, let pointer = CFArrayGetValueAtIndex(attachments, 0) else { return nil }
    let dictionary = Unmanaged<CFDictionary>.fromOpaque(pointer).takeUnretainedValue()
    let key = SCStreamFrameInfo.status.rawValue as CFString
    guard let raw = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
    let number = Unmanaged<CFNumber>.fromOpaque(raw).takeUnretainedValue()
    var value: Int32 = 0
    guard CFNumberGetValue(number, .sInt32Type, &value) else { return nil }
    return SCFrameStatus(rawValue: Int(value))
  }

  static func statusName(_ status: SCFrameStatus?) -> String {
    switch status {
    case .complete: return "complete"
    case .idle: return "idle"
    case .blank: return "blank"
    case .suspended: return "suspended"
    case .started: return "started"
    case .stopped: return "stopped"
    default: return "unknown"
    }
  }

  /// A pixel buffer this process owns. The ScreenCaptureKit buffer is only valid inside the callback; copying it avoids releasing that IOSurface twice.
  private static func ownedCopy(of source: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    guard width > 1, height > 1, !CVPixelBufferIsPlanar(source) else { return nil }
    let format = CVPixelBufferGetPixelFormatType(source)
    var copy: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &copy) == kCVReturnSuccess, let copy else { return nil }
    guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferLockBaseAddress(copy, []) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(copy, []) }
    guard let sourceBase = CVPixelBufferGetBaseAddress(source), let copyBase = CVPixelBufferGetBaseAddress(copy) else { return nil }
    let sourceRow = CVPixelBufferGetBytesPerRow(source)
    let copyRow = CVPixelBufferGetBytesPerRow(copy)
    let rowBytes = min(sourceRow, copyRow)
    guard rowBytes >= width * 4 else { return nil }
    for row in 0..<height {
      memcpy(copyBase.advanced(by: row * copyRow), sourceBase.advanced(by: row * sourceRow), rowBytes)
    }
    return copy
  }

  private static func displayTargets(in content: SCShareableContent) -> [BrowserCaptureTarget] {
    let displays = content.displays.filter { $0.width > 1 && $0.height > 1 }
    return displays.map { display in
      let screen = NSScreen.screens.first { $0.displayId == display.displayID }
      let owner = displays.count > 1 ? (screen?.localizedName ?? "Display \(display.displayID)") : ""
      return BrowserCaptureTarget(
        kind: .display,
        id: 0,
        displayID: display.displayID,
        title: "Capture whole display",
        owner: owner,
        bundleID: "",
        width: Int(display.width),
        height: Int(display.height)
      )
    }
  }

  /// Layer 0 is a normal window. OBS drops empty titles unless "show empty names" is on (`build_window_list` in mac-sck-common.m). `isOnScreen` is not required: a full-screen window on another Space is off the current screen.
  private static func windowTargets(in content: SCShareableContent, excluding ids: Set<CGWindowID>) -> [BrowserCaptureTarget] {
    let ownBundle = Bundle.main.bundleIdentifier
    return content.windows.compactMap { window in
      guard isListableWindow(window, excluding: ids) else { return nil }
      let bundle = window.owningApplication?.bundleIdentifier
      let title = window.title ?? ""
      if bundle == ownBundle && (title == "Browser Capture" || title == "Choose Capture Window") { return nil }
      let owner = window.owningApplication?.applicationName ?? ""
      return BrowserCaptureTarget(
        kind: .window,
        id: window.windowID,
        displayID: 0,
        title: title,
        owner: owner,
        bundleID: bundle ?? "",
        width: Int(window.frame.width.rounded()),
        height: Int(window.frame.height.rounded())
      )
    }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
  }

  private static func record(_ window: SCWindow, displays: [SCDisplay]) -> CaptureWindowRecord {
    CaptureWindowRecord(
      id: window.windowID,
      title: window.title ?? "",
      owner: window.owningApplication?.applicationName ?? "",
      bundleID: window.owningApplication?.bundleIdentifier ?? "",
      width: Int(window.frame.width.rounded()),
      height: Int(window.frame.height.rounded()),
      onScreen: window.isOnScreen,
      displayID: displayID(covering: window.frame, displays: displays)
    )
  }

  private static func displayID(covering frame: CGRect, displays: [SCDisplay]) -> UInt32 {
    CaptureWindowMatch.displayID(
      covering: frame,
      displays: displays.map { (id: $0.displayID, frame: $0.frame) }
    )
  }

  /// Follow can see a full-screen window whose title was cleared. The chooser still requires a title.
  private static func isFollowableWindow(_ window: SCWindow, excluding ids: Set<CGWindowID>) -> Bool {
    if ids.contains(window.windowID) { return false }
    if window.windowLayer != 0 { return false }
    let owner = window.owningApplication?.applicationName ?? ""
    let bundle = window.owningApplication?.bundleIdentifier ?? ""
    if owner.isEmpty && bundle.isEmpty { return false }
    let width = Int(window.frame.width.rounded())
    let height = Int(window.frame.height.rounded())
    return width >= 80 && height >= 80
  }

  private static func isListableWindow(_ window: SCWindow, excluding ids: Set<CGWindowID>) -> Bool {
    if ids.contains(window.windowID) { return false }
    if window.windowLayer != 0 { return false }
    let title = window.title ?? ""
    let owner = window.owningApplication?.applicationName ?? ""
    if title.isEmpty || owner.isEmpty { return false }
    let width = Int(window.frame.width.rounded())
    let height = Int(window.frame.height.rounded())
    return width >= 80 && height >= 80
  }

  private struct ResolvedCapture {
    var target: BrowserCaptureTarget
    var filter: SCContentFilter
    var pixelWidth: Int
    var pixelHeight: Int
    var pid: pid_t?
  }

  private static func resolve(_ target: BrowserCaptureTarget, in content: SCShareableContent, excluding ids: Set<CGWindowID>) throws -> ResolvedCapture {
    switch target.kind {
    case .display:
      guard let display = content.displays.first(where: { $0.displayID == target.displayID }) ?? content.displays.first else {
        throw CaptureFailure("That display is no longer available.")
      }
      let excluded = content.windows.filter { ids.contains($0.windowID) }
      let filter = SCContentFilter(display: display, excludingWindows: excluded)
      let size = clampedPixels(Int(display.width), Int(display.height))
      return ResolvedCapture(target: target, filter: filter, pixelWidth: size.width, pixelHeight: size.height, pid: nil)
    case .window:
      let windows = content.windows.filter { isListableWindow($0, excluding: ids) }
      let window = windows.first { $0.windowID == target.id } ?? matchWindow(owner: target.owner, title: target.title, bundle: target.bundleID, in: windows)
      guard let window else {
        throw CaptureFailure("That window is no longer available.")
      }
      if window.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier && (window.title ?? "") == "Browser Capture" {
        throw CaptureFailure("That window is IINA's own output. Choose the browser window, not the glasses picture.")
      }
      var resolved = target
      resolved.id = window.windowID
      resolved.title = window.title ?? target.title
      resolved.owner = window.owningApplication?.applicationName ?? target.owner
      resolved.bundleID = window.owningApplication?.bundleIdentifier ?? target.bundleID
      let size = pixelSize(for: window)
      let filter = SCContentFilter(desktopIndependentWindow: window)
      return ResolvedCapture(target: resolved, filter: filter, pixelWidth: size.width, pixelHeight: size.height, pid: window.owningApplication?.processID)
    }
  }

  /// OBS `find_window` matches owner name and window title. A full-screen Chrome window often has a new id and a shorter title, so a title that contains the other still counts when the app matches.
  private static func matchWindow(owner: String, title: String, bundle: String, in windows: [SCWindow]) -> SCWindow? {
    let exact = windows.filter { window in
      let app = window.owningApplication?.applicationName ?? ""
      let name = window.title ?? ""
      return app.caseInsensitiveCompare(owner) == .orderedSame && name.caseInsensitiveCompare(title) == .orderedSame
    }
    if let best = preferred(exact) { return best }
    let loose = windows.filter { window in
      let app = window.owningApplication?.applicationName ?? ""
      let appBundle = window.owningApplication?.bundleIdentifier ?? ""
      let name = window.title ?? ""
      let sameApp = app.caseInsensitiveCompare(owner) == .orderedSame || (!bundle.isEmpty && appBundle == bundle)
      return sameApp && titlesMatch(name, title)
    }
    return preferred(loose)
  }

  private static func replacement(for target: BrowserCaptureTarget, current: SCWindow?, in windows: [SCWindow]) -> SCWindow? {
    guard let match = matchWindow(owner: target.owner, title: target.title, bundle: target.bundleID, in: windows) else { return nil }
    guard match.windowID != target.id else { return nil }
    if current == nil { return match }
    if current?.isOnScreen == false && match.isOnScreen { return match }
    let currentArea = (current?.frame.width ?? 0) * (current?.frame.height ?? 0)
    let matchArea = match.frame.width * match.frame.height
    if currentArea > 1 && matchArea > currentArea * 1.3 { return match }
    return nil
  }

  private static func preferred(_ windows: [SCWindow]) -> SCWindow? {
    windows.max { lhs, rhs in
      if lhs.isOnScreen != rhs.isOnScreen { return rhs.isOnScreen }
      return lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
    }
  }

  private static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
    if lhs.isEmpty || rhs.isEmpty { return false }
    if lhs.caseInsensitiveCompare(rhs) == .orderedSame { return true }
    let left = lhs.lowercased()
    let right = rhs.lowercased()
    guard left.count >= 4, right.count >= 4 else { return false }
    return left.contains(right) || right.contains(left)
  }

  private static func pixelSize(for window: SCWindow) -> (width: Int, height: Int) {
    let frame = window.frame
    var scale: CGFloat = 2
    if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
      scale = screen.backingScaleFactor
    }
    let width = Int((frame.width * scale).rounded())
    let height = Int((frame.height * scale).rounded())
    return clampedPixels(width, height)
  }

  private static func clampedPixels(_ width: Int, _ height: Int) -> (width: Int, height: Int) {
    var width = min(max(width, 2), 3840)
    var height = min(max(height, 2), 2160)
    if width % 2 != 0 { width -= 1 }
    if height % 2 != 0 { height -= 1 }
    return (max(width, 2), max(height, 2))
  }

  private func beginSession() -> Bool {
    sessionLock.lock()
    defer { sessionLock.unlock() }
    if sessionBusy { return false }
    sessionBusy = true
    return true
  }

  private func endSession() {
    sessionLock.lock()
    sessionBusy = false
    sessionLock.unlock()
  }

  private func waitForSession() async {
    while !beginSession() {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }
}

private struct CaptureFailure: LocalizedError {
  var errorDescription: String?
  init(_ text: String) { errorDescription = text }
}
