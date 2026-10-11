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

@available(macOS 12.3, *)
final class BrowserCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
  static let shared = BrowserCaptureManager()

  static let protectedMessage = "This window is black because macOS is not sharing its picture. Protected video (DRM) stays black. IINA uses only the normal screen capture and does not try to bypass that. Choose a window whose picture is visible, or open the file in IINA."
  static let muteNeedsNewerOS = "Muting another app needs macOS 14.2. Until then the other app keeps playing, and IINA plays the capture too."

  private let queue = DispatchQueue(label: "com.colliderli.iina.browser-capture", qos: .userInteractive)
  private let audioQueue = DispatchQueue(label: "com.colliderli.iina.browser-capture-audio-in", qos: .userInteractive)
  private let audioPlayer = BrowserCaptureAudioPlayer()
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
  private(set) var sourcePID: pid_t?
  private(set) var audioActive = false

  /// Called on the capture queue with a pixel buffer this process owns.
  var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
  /// Called on the capture queue when the source did not send a new picture.
  var onIdle: (() -> Void)?
  var onStatus: ((String?) -> Void)?
  var onNote: ((String) -> Void)?
  var onMuteChanged: (() -> Void)?
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

  func setSourceMuted(_ on: Bool) {
    BrowserCaptureSettings.shared.setMuteSource(on)
    applyMute()
  }

  func notePresentedVideo(_ time: CMTime) {
    guard audioActive else { return }
    audioPlayer.notePresentedVideo(time)
  }

  func perform(_ block: @escaping () -> Void) {
    queue.async(execute: block)
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
      onIdle?()
      return
    }
    // A complete frame is copied into a buffer this process owns. An idle frame
    // usually has no image; that, and a stretch with no callback, redraws the last one.
    if status != .idle, let image, let owned = Self.ownedCopy(of: image) {
      lastComplete = CACurrentMediaTime()
      onFrame?(owned, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
      return
    }
    if image != nil && status != .idle {
      browserCaptureLog.error("frame copy failed status=\(Self.statusName(status), privacy: .public)")
    }
    onIdle?()
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    let text = error.localizedDescription
    browserCaptureLog.error("stream stopped: \(text, privacy: .public)")
    log3D("Browser capture stopped: \(text)", level: .error)
    // A stop we asked for has already dropped this stream. Restart only when the live stream dies, which is what OBS does after SCStreamError.
    guard shouldRun, !ignoreStop, stream === self.stream else { return }
    accepting = false
    running = false
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
    configuration.queueDepth = 8
    var captureAudio = false
    if #available(macOS 13.0, *) {
      captureAudio = BrowserCaptureSettings.shared.wantsAudio
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
    loggedFirstFrame = false
    framesInWindow = 0
    windowStarted = CACurrentMediaTime()
    lastComplete = CACurrentMediaTime()
    accepting = true
    do {
      try await start(stream)
    } catch {
      accepting = false
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
    if captureAudio {
      audioPlayer.start()
    }
    if BrowserCaptureSettings.shared.wantsMute {
      applyMute()
    }
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
    followTimer?.cancel()
    followTimer = nil
    redrawTimer?.cancel()
    redrawTimer = nil
    audioPlayer.setSourceMuteActive(false)
    audioPlayer.stop()
    if #available(macOS 14.2, *) {
      BrowserCaptureSourceMute.shared.stop()
    }
    if clearTarget {
      currentID = nil
      activeTarget = nil
      sourcePID = nil
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
        DispatchQueue.main.async {
          status?(message)
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

  /// Every half second, the same interval OBS uses in `find_window`. The current window id wins while it still exists, including on another Space. When full screen replaces that id, the next window with the same app and title is captured.
  private func followTrackedWindow(token: Int) async {
    guard beginSession() else { return }
    defer { endSession() }
    guard shouldRun, token == epoch, var target = activeTarget, target.kind == .window else { return }
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
    let windows = content.windows.filter { Self.isListableWindow($0, excluding: ids) }
    if windows.contains(where: { $0.windowID == target.id }) {
      let current = windows.first { $0.windowID == target.id }
      if let replacement = Self.replacement(for: target, current: current, in: windows), replacement.windowID != target.id {
        target.id = replacement.windowID
        target.title = replacement.title ?? target.title
        target.width = Int(replacement.frame.width.rounded())
        target.height = Int(replacement.frame.height.rounded())
        await retarget(target, window: replacement, token: token)
      }
      return
    }
    guard let found = Self.matchWindow(owner: target.owner, title: target.title, bundle: target.bundleID, in: windows) else {
      browserCaptureLog.info("tracked window \(target.id) is gone; no app+title match")
      return
    }
    target.id = found.windowID
    target.title = found.title ?? target.title
    target.width = Int(found.frame.width.rounded())
    target.height = Int(found.frame.height.rounded())
    await retarget(target, window: found, token: token)
  }

  private func retarget(_ target: BrowserCaptureTarget, window: SCWindow, token: Int) async {
    guard token == epoch, let stream else { return }
    browserCaptureLog.info("window id changed to \(window.windowID) app=\(target.owner, privacy: .public) title=\(target.title, privacy: .public)")
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let updated = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      stream.updateContentFilter(filter) { error in
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
      self.onIdle?()
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

  private func applyMute() {
    let wants = BrowserCaptureSettings.shared.wantsMute && running
    guard wants, let pid = sourcePID, pid > 0 else {
      if #available(macOS 14.2, *) {
        BrowserCaptureSourceMute.shared.stop()
      }
      audioPlayer.setSourceMuteActive(false)
      return
    }
    if #available(macOS 14.2, *) {
      if let message = BrowserCaptureSourceMute.shared.start(pid: pid) {
        BrowserCaptureSettings.shared.setMuteSource(false)
        audioPlayer.setSourceMuteActive(false)
        DispatchQueue.main.async { [weak self] in
          self?.onStatus?(message)
          self?.onMuteChanged?()
        }
        return
      }
      audioPlayer.setSourceMuteActive(true)
      DispatchQueue.main.async { [weak self] in
        self?.onNote?("Source app is muted. IINA plays its audio with the picture.")
      }
    } else {
      BrowserCaptureSettings.shared.setMuteSource(false)
      DispatchQueue.main.async { [weak self] in
        self?.onNote?(Self.muteNeedsNewerOS)
        self?.onMuteChanged?()
      }
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
