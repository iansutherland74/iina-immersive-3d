//
//  BrowserCaptureManager.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  One window, captured with the public ScreenCaptureKit API. Audio is not
//  captured. Protected video that macOS returns black is reported and left black.

import Cocoa
import CoreMedia
import ScreenCaptureKit

struct BrowserCaptureTarget {
  let id: CGWindowID
  let title: String
  let owner: String
  let width: Int
  let height: Int

  var label: String {
    let name = title.isEmpty ? "Window" : title
    return "\(owner) — \(name)  \(width)×\(height)"
  }
}

@available(macOS 12.3, *)
final class BrowserCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
  static let shared = BrowserCaptureManager()

  static let protectedMessage = "This window is black because macOS is not sharing its picture. Protected video (DRM) stays black. IINA uses only the normal screen capture and does not try to bypass that. Choose a window whose picture is visible, or open the file in IINA."

  private let queue = DispatchQueue(label: "com.colliderli.iina.browser-capture", qos: .userInteractive)
  private var stream: SCStream?
  private var running = false
  private var accepting = false
  private(set) var currentID: CGWindowID?

  var onFrame: ((CVPixelBuffer) -> Void)?
  var onStatus: ((String?) -> Void)?

  private override init() {
    super.init()
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
    let ownBundle = Bundle.main.bundleIdentifier
    return content.windows.compactMap { window in
      let id = window.windowID
      if ids.contains(id) { return nil }
      let owner = window.owningApplication?.applicationName ?? ""
      let bundle = window.owningApplication?.bundleIdentifier
      let title = window.title ?? ""
      if bundle == ownBundle && (ids.contains(id) || title == "Browser Capture") { return nil }
      let width = Int(window.frame.width.rounded())
      let height = Int(window.frame.height.rounded())
      guard width >= 80, height >= 80 else { return nil }
      guard window.isOnScreen else { return nil }
      if owner.isEmpty && title.isEmpty { return nil }
      return BrowserCaptureTarget(id: id, title: title, owner: owner.isEmpty ? "App" : owner, width: width, height: height)
    }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
  }

  func start(windowID: CGWindowID, excluding ids: Set<CGWindowID>) async throws {
    if ids.contains(windowID) {
      throw CaptureFailure("That window is IINA's own output. Choose the browser window, not the glasses picture.")
    }
    let content = try await loadContent()
    guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
      throw CaptureFailure("That window is no longer on screen.")
    }
    if window.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier && (window.title ?? "") == "Browser Capture" {
      throw CaptureFailure("That window is IINA's own output. Choose the browser window, not the glasses picture.")
    }
    await stop()
    let configuration = SCStreamConfiguration()
    let size = Self.pixelSize(for: window)
    configuration.width = size.width
    configuration.height = size.height
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = false
    configuration.queueDepth = 3
    if #available(macOS 13.0, *) {
      configuration.capturesAudio = false
      configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    self.stream = stream
    currentID = windowID
    accepting = true
    do {
      try await start(stream)
    } catch {
      accepting = false
      self.stream = nil
      currentID = nil
      throw error
    }
    running = true
    log3D("Browser capture started for window \(windowID) at \(size.width)x\(size.height)", level: .debug)
  }

  func stop() async {
    accepting = false
    running = false
    currentID = nil
    guard let stream else { return }
    self.stream = nil
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      stream.stopCapture { _ in
        continuation.resume()
      }
    }
  }

  var isRunning: Bool { running }

  func perform(_ block: @escaping () -> Void) {
    queue.async(execute: block)
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard accepting, type == .screen else { return }
    if frameStatus(of: sampleBuffer) == .blank {
      DispatchQueue.main.async { [weak self] in
        self?.onStatus?(Self.protectedMessage)
      }
      return
    }
    guard let buffer = sampleBuffer.imageBuffer else { return }
    onFrame?(buffer)
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    guard accepting else { return }
    accepting = false
    running = false
    let text = error.localizedDescription
    DispatchQueue.main.async { [weak self] in
      self?.onStatus?(text)
    }
    log3D("Browser capture stopped: \(text)", level: .error)
  }

  private func loadContent() async throws -> SCShareableContent {
    try await withCheckedThrowingContinuation { continuation in
      SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
        if let content {
          continuation.resume(returning: content)
        } else {
          continuation.resume(throwing: error ?? CaptureFailure("Screen capture is not available."))
        }
      }
    }
  }

  private func start(_ stream: SCStream) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      stream.startCapture { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
          let value = attachments.first?[.status] else { return nil }
    if let number = value as? NSNumber {
      return SCFrameStatus(rawValue: number.intValue)
    }
    if let raw = value as? Int {
      return SCFrameStatus(rawValue: raw)
    }
    return nil
  }

  private static func pixelSize(for window: SCWindow) -> (width: Int, height: Int) {
    let frame = window.frame
    var scale: CGFloat = 2
    if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
      scale = screen.backingScaleFactor
    }
    var width = Int((frame.width * scale).rounded())
    var height = Int((frame.height * scale).rounded())
    width = min(max(width, 2), 3840)
    height = min(max(height, 2), 2160)
    if width % 2 != 0 { width -= 1 }
    if height % 2 != 0 { height -= 1 }
    return (max(width, 2), max(height, 2))
  }
}

private struct CaptureFailure: LocalizedError {
  var errorDescription: String?
  init(_ text: String) { errorDescription = text }
}
