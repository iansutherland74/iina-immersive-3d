//
//  BrowserCaptureCrop.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Crop insets for any captured window. Chrome detection looks for a flat bar
//  across the top. Video-area detection trims near-black borders. Neither one
//  inspects codecs or protection flags.

import Cocoa
import CoreVideo

struct BrowserCaptureInsets: Equatable {
  var top: Double
  var left: Double
  var bottom: Double
  var right: Double

  static let zero = BrowserCaptureInsets(top: 0, left: 0, bottom: 0, right: 0)

  func clamped() -> BrowserCaptureInsets {
    func unit(_ value: Double) -> Double { min(max(value, 0), 0.45) }
    var result = BrowserCaptureInsets(top: unit(top), left: unit(left), bottom: unit(bottom), right: unit(right))
    if result.top + result.bottom > 0.8 {
      let scale = 0.8 / (result.top + result.bottom)
      result.top *= scale
      result.bottom *= scale
    }
    if result.left + result.right > 0.8 {
      let scale = 0.8 / (result.left + result.right)
      result.left *= scale
      result.right *= scale
    }
    return result
  }

  func nearlyEquals(_ other: BrowserCaptureInsets) -> Bool {
    abs(top - other.top) < 0.008 &&
      abs(left - other.left) < 0.008 &&
      abs(bottom - other.bottom) < 0.008 &&
      abs(right - other.right) < 0.008
  }
}

enum BrowserCaptureCropMode: Int {
  case autoChrome = 0
  case videoArea = 1
  case manual = 2
}

/// Session settings for capture audio and crop. The renderer reads them on the capture queue.
final class BrowserCaptureSettings {
  static let shared = BrowserCaptureSettings()

  var onDetected: ((BrowserCaptureInsets) -> Void)?

  private let lock = NSLock()
  private var playAudio = true
  private var muteSource = false
  private var mode: BrowserCaptureCropMode = .autoChrome
  private var manual = BrowserCaptureInsets.zero
  private var detected = BrowserCaptureInsets.zero
  private var analysisRequested = false

  private init() {}

  func setPlayAudio(_ on: Bool) {
    lock.lock()
    playAudio = on
    lock.unlock()
  }

  func setMuteSource(_ on: Bool) {
    lock.lock()
    muteSource = on
    lock.unlock()
  }

  func setMode(_ mode: BrowserCaptureCropMode) {
    lock.lock()
    self.mode = mode
    if mode != .manual {
      analysisRequested = true
    }
    lock.unlock()
  }

  func setManual(_ insets: BrowserCaptureInsets) {
    lock.lock()
    mode = .manual
    manual = insets.clamped()
    lock.unlock()
  }

  var wantsAudio: Bool {
    lock.lock()
    defer { lock.unlock() }
    return playAudio
  }

  var wantsMute: Bool {
    lock.lock()
    defer { lock.unlock() }
    return muteSource
  }

  var cropMode: BrowserCaptureCropMode {
    lock.lock()
    defer { lock.unlock() }
    return mode
  }

  func appliedInsets() -> BrowserCaptureInsets {
    lock.lock()
    defer { lock.unlock() }
    switch mode {
    case .manual:
      return manual.clamped()
    case .autoChrome, .videoArea:
      return detected.clamped()
    }
  }

  func updateDetected(_ insets: BrowserCaptureInsets) {
    let clamped = insets.clamped()
    lock.lock()
    let ignored = mode == .manual
    let changed = !detected.nearlyEquals(clamped)
    if !ignored && changed {
      detected = clamped
    }
    lock.unlock()
    guard !ignored, changed else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.cropMode != .manual else { return }
      self.onDetected?(clamped)
    }
  }

  func requestAnalysis() {
    lock.lock()
    analysisRequested = true
    lock.unlock()
  }

  func takeAnalysisRequest() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let value = analysisRequested
    analysisRequested = false
    return value
  }
}

enum BrowserCaptureCropMath {
  static let columns = 96
  static let rows = 64

  static func detect(pixelBuffer: CVPixelBuffer, mode: BrowserCaptureCropMode) -> BrowserCaptureInsets? {
    guard mode != .manual else { return nil }
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
    guard let luma = sampleLuma(pixelBuffer) else { return nil }
    switch mode {
    case .autoChrome:
      return BrowserCaptureInsets(top: chromeTop(luma: luma, width: columns, height: rows), left: 0, bottom: 0, right: 0)
    case .videoArea:
      return videoArea(luma: luma, width: columns, height: rows)
    case .manual:
      return nil
    }
  }

  static func sampleLuma(_ pixelBuffer: CVPixelBuffer) -> [Float]? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard width > 1, height > 1, bytesPerRow >= width * 4 else { return nil }
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    var luma = [Float](repeating: 0, count: columns * rows)
    for row in 0..<rows {
      let y = min(height - 1, row * height / rows + height / (rows * 2))
      for column in 0..<columns {
        let x = min(width - 1, column * width / columns + width / (columns * 2))
        let offset = y * bytesPerRow + x * 4
        let blue = Float(pixels[offset])
        let green = Float(pixels[offset + 1])
        let red = Float(pixels[offset + 2])
        luma[row * columns + column] = 0.2126 * red + 0.7152 * green + 0.0722 * blue
      }
    }
    return luma
  }

  /// Fraction of the frame occupied by a flat bar across the top, or 0.
  static func chromeTop(luma: [Float], width: Int, height: Int) -> Double {
    guard width > 1, height > 4, luma.count >= width * height else { return 0 }
    let stats = rowStats(luma: luma, width: width, height: height)
    let start = max(Int((0.03 * Double(height)).rounded(.down)), 1)
    let end = min(Int((0.36 * Double(height)).rounded(.up)), height - 1)
    guard start < end else { return 0 }
    var best = 0
    var candidates: [(row: Int, score: Int)] = []
    for row in start..<end {
      let edge = medianEdge(luma: luma, width: width, row: row)
      let above = meanStd(stats, from: max(0, row - 5), to: row)
      let below = meanStd(stats, from: row, to: min(height, row + 5))
      if stats[row - 1].mean < 20 || stats[row - 1].std > 22 { continue }
      if above > 30 { continue }
      let lookback = max(0, row - 5)
      var flatRows = 0
      var darkRows = 0
      for index in lookback..<row {
        if stats[index].std < 22 && stats[index].mean >= 20 { flatRows += 1 }
        if stats[index].mean < 16 { darkRows += 1 }
      }
      if darkRows > 0 || flatRows < min(3, row - lookback) { continue }
      let contrast = max(0, below - above)
      if edge < 8 && contrast < 6 { continue }
      let score = edge + contrast
      if score > best { best = score }
      candidates.append((row, score))
    }
    guard best >= 10 else { return 0 }
    let chosen = candidates.filter { $0.score >= Int(Double(best) * 0.6) && $0.score >= 10 }.map { $0.row }.max()
    guard let chosen else { return 0 }
    let fraction = Double(chosen) / Double(height)
    if fraction < 0.03 || fraction > 0.36 { return 0 }
    return min(0.36, fraction + 0.5 / Double(height))
  }

  /// Trims edges that are uniformly near black. A dark picture with variation stays whole.
  static func videoArea(luma: [Float], width: Int, height: Int) -> BrowserCaptureInsets {
    guard width > 1, height > 1, luma.count >= width * height else { return .zero }
    let rows = rowStats(luma: luma, width: width, height: height)
    let columns = columnStats(luma: luma, width: width, height: height)
    let top = leadingBars(rows)
    let bottom = leadingBars(rows.reversed())
    let left = leadingBars(columns)
    let right = leadingBars(columns.reversed())
    if top + bottom >= height - 1 || left + right >= width - 1 { return .zero }
    let remainHeight = height - top - bottom
    let remainWidth = width - left - right
    if remainHeight * remainWidth * 10 < width * height * 3 { return .zero }
    func fraction(_ count: Int, _ total: Int) -> Double {
      let value = Double(count) / Double(total)
      if value < 0.02 { return 0 }
      return min(0.45, value)
    }
    return BrowserCaptureInsets(
      top: fraction(top, height),
      left: fraction(left, width),
      bottom: fraction(bottom, height),
      right: fraction(right, width)
    )
  }

  private struct Stat {
    var mean: Float
    var std: Float
  }

  private static func rowStats(luma: [Float], width: Int, height: Int) -> [Stat] {
    (0..<height).map { row in
      stat(luma, start: row * width, step: 1, count: width)
    }
  }

  private static func columnStats(luma: [Float], width: Int, height: Int) -> [Stat] {
    (0..<width).map { column in
      stat(luma, start: column, step: width, count: height)
    }
  }

  private static func stat(_ luma: [Float], start: Int, step: Int, count: Int) -> Stat {
    guard count > 0 else { return Stat(mean: 0, std: 0) }
    var sum: Float = 0
    for index in 0..<count {
      sum += luma[start + index * step]
    }
    let mean = sum / Float(count)
    var square: Float = 0
    for index in 0..<count {
      let delta = luma[start + index * step] - mean
      square += delta * delta
    }
    return Stat(mean: mean, std: sqrt(square / Float(count)))
  }

  private static func meanStd(_ stats: [Stat], from: Int, to: Int) -> Int {
    guard to > from else { return 0 }
    var sum: Float = 0
    for index in from..<to {
      sum += stats[index].std
    }
    return Int((sum / Float(to - from)).rounded())
  }

  private static func medianEdge(luma: [Float], width: Int, row: Int) -> Int {
    var diffs = [Float](repeating: 0, count: width)
    let upper = (row - 1) * width
    let lower = row * width
    for column in 0..<width {
      diffs[column] = abs(luma[lower + column] - luma[upper + column])
    }
    diffs.sort()
    return Int(diffs[width / 2].rounded())
  }

  private static func leadingBars<S: Sequence>(_ stats: S) -> Int where S.Element == Stat {
    var count = 0
    for stat in stats {
      if stat.mean < 12 && stat.std < 5 {
        count += 1
      } else {
        break
      }
    }
    return count
  }
}
