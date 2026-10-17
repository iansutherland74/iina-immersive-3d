//
//  CaptureAVSync.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Temporary flash/beep measurement for browser capture. A luma jump on the
//  presented picture and an RMS jump on the loopback output are stamped with
//  the host clock. The difference is the latency the slider should cancel.

import Darwin
import Foundation

enum CaptureHostClock {
  static let secondsPerTick: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let denom = Double(max(info.denom, 1))
    return Double(info.numer) / denom / 1_000_000_000
  }()

  static func seconds(since ticks: UInt64) -> Double {
    Double(ticks) * secondsPerTick
  }

  static func now() -> Double {
    seconds(since: mach_absolute_time())
  }
}

/// Glasses output is 2D or side-by-side 3D. Full width is 3840×1080. Half
/// side-by-side stays 1920×1080 until the panel widens. A preview window is 2D.
enum CapturePictureMode: Equatable {
  case twoD
  case sideBySide

  var logToken: String {
    switch self {
    case .twoD: return "2D"
    case .sideBySide: return "3D SBS"
    }
  }

  static func resolve(onGlasses: Bool, outputWidth: Int, outputHeight: Int) -> CapturePictureMode {
    guard outputWidth > 0, outputHeight > 0 else { return .twoD }
    if outputWidth == 3840 && outputHeight == 1080 { return .sideBySide }
    if Double(outputWidth) / Double(outputHeight) >= 3.2 { return .sideBySide }
    if onGlasses && outputWidth == 1920 && outputHeight == 1080 { return .sideBySide }
    return .twoD
  }
}

/// One rising edge. The level has to fall back under `low` before the next edge.
struct CaptureLevelEdge: Equatable {
  var low: Float
  var high: Float
  var rise: Float
  private var level: Float = 0
  private var quiet = true
  private var haveLevel = false

  /// Explicit so callers outside this type can build an edge. The private
  /// samples make the synthesized memberwise initializer private.
  internal init(low: Float, high: Float, rise: Float) {
    self.low = low
    self.high = high
    self.rise = rise
  }

  mutating func observe(_ sample: Float) -> Bool {
    guard sample.isFinite else { return false }
    let previous = level
    let wasQuiet = quiet || !haveLevel
    haveLevel = true
    level = sample
    if sample <= low {
      quiet = true
      return false
    }
    if wasQuiet && sample >= high && sample - previous >= rise {
      quiet = false
      return true
    }
    return false
  }
}

struct CaptureAVSyncFlash: Equatable {
  var time: Double
  var captureWidth: Int
  var captureHeight: Int
  var outputWidth: Int
  var outputHeight: Int
  var mode: String
}

struct CaptureAVSyncMatch: Equatable {
  var deltaMs: Int
  var averageMs: Int
  var count: Int
  var captureWidth: Int
  var captureHeight: Int
  var outputWidth: Int
  var outputHeight: Int
  var mode: String
}

/// Pairs a flash with the beep nearest to it. The delta is beep time minus
/// flash time, so a positive value means the sound is behind the picture.
struct CaptureAVSyncTracker: Equatable {
  var window = 1.5
  var limit = 8
  private(set) var flashes: [CaptureAVSyncFlash] = []
  private(set) var beeps: [Double] = []
  private(set) var deltas: [Int] = []

  mutating func addFlash(_ flash: CaptureAVSyncFlash) -> CaptureAVSyncMatch? {
    flashes.append(flash)
    return pair()
  }

  mutating func addBeep(time: Double) -> CaptureAVSyncMatch? {
    guard time.isFinite else { return nil }
    beeps.append(time)
    return pair()
  }

  private mutating func pair() -> CaptureAVSyncMatch? {
    dropStale()
    guard let flash = flashes.first else { return nil }
    var best: (offset: Int, distance: Double)?
    for (offset, beep) in beeps.enumerated() {
      let distance = abs(beep - flash.time)
      if best == nil || distance < best!.distance {
        best = (offset, distance)
      }
    }
    guard let best, best.distance <= window else { return nil }
    let beep = beeps.remove(at: best.offset)
    flashes.removeFirst()
    let ms = Int(((beep - flash.time) * 1000).rounded())
    deltas.append(ms)
    if deltas.count > limit {
      deltas.removeFirst(deltas.count - limit)
    }
    let average = Int((Double(deltas.reduce(0, +)) / Double(deltas.count)).rounded())
    return CaptureAVSyncMatch(
      deltaMs: ms,
      averageMs: average,
      count: deltas.count,
      captureWidth: flash.captureWidth,
      captureHeight: flash.captureHeight,
      outputWidth: flash.outputWidth,
      outputHeight: flash.outputHeight,
      mode: flash.mode
    )
  }

  private mutating func dropStale() {
    if let newestBeep = beeps.max() {
      flashes.removeAll { flash in
        flash.time < newestBeep - window && beeps.allSatisfy { abs($0 - flash.time) > window }
      }
    }
    if let newestFlash = flashes.map(\.time).max() {
      beeps.removeAll { beep in
        beep < newestFlash - window && flashes.allSatisfy { abs($0.time - beep) > window }
      }
    }
    if flashes.count > limit {
      flashes.removeFirst(flashes.count - limit)
    }
    if beeps.count > limit {
      beeps.removeFirst(beeps.count - limit)
    }
  }
}

enum CaptureAVSyncLog {
  static func line(match: CaptureAVSyncMatch, currentOffsetMs: Int) -> String {
    let suggestion = CaptureSyncOffset.suggested(currentMs: currentOffsetMs, averageDeltaMs: match.averageMs)
    let shown = suggestion.ms
    let sign = shown > 0 ? "+" : ""
    var text = "av sync capture=\(match.captureWidth)x\(match.captureHeight) output=\(match.outputWidth)x\(match.outputHeight) mode=\(match.mode) delta=\(match.deltaMs) ms avg=\(match.averageMs) ms n=\(match.count) suggested=\(sign)\(shown) ms (\(CaptureSyncOffset.effectPhrase(ms: shown)))"
    if suggestion.raw != shown {
      let rawSign = suggestion.raw > 0 ? "+" : ""
      text += " clamped from \(rawSign)\(suggestion.raw)"
    }
    return text
  }
}

/// Frames wait until they are `hold` seconds old, then the newest due frame is
/// the one to draw. A hold of zero keeps only the newest frame.
struct CaptureVideoDelayQueue: Equatable {
  struct Ticket: Equatable {
    var id: Int
    var received: Double
  }

  var hold = 0.0
  var cap = 24
  private(set) var waiting: [Ticket] = []

  mutating func push(id: Int, received: Double) {
    if hold <= 0 {
      waiting = [Ticket(id: id, received: received)]
      return
    }
    waiting.append(Ticket(id: id, received: received))
    if waiting.count > cap {
      waiting.removeFirst(waiting.count - cap)
    }
  }

  mutating func popDue(now: Double) -> Ticket? {
    if hold <= 0 {
      guard let last = waiting.last else { return nil }
      waiting.removeAll()
      return last
    }
    var chosen: Ticket?
    var end = 0
    for (index, ticket) in waiting.enumerated() {
      if now + 0.0005 >= ticket.received + hold {
        chosen = ticket
        end = index + 1
      } else {
        break
      }
    }
    guard let chosen else { return nil }
    waiting.removeFirst(end)
    return chosen
  }

  func timeUntilDue(now: Double) -> Double? {
    guard hold > 0, let first = waiting.first else { return nil }
    return max(0.002, first.received + hold - now)
  }
}

/// Armed from the capture menu. Video calls `noteVideo` on the present path.
/// The loopback output calls `noteAudio` from its IO callback.
final class CaptureAVSyncTest {
  static let shared = CaptureAVSyncTest()
  static let pairGoal = 6

  var currentOffsetMs: () -> Int = { 0 }
  var onLine: ((String) -> Void)?

  private let lock = NSLock()
  private var running = false
  private var videoEdge = CaptureLevelEdge(low: 48, high: 110, rise: 45)
  private var audioEdge = CaptureLevelEdge(low: 0.008, high: 0.03, rise: 0.02)
  private var tracker = CaptureAVSyncTracker()
  private var lines: [String] = []
  private let logQueue = DispatchQueue(label: "com.colliderli.iina.av-sync-log")

  private init() {}

  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  func start() {
    lock.lock()
    running = true
    videoEdge = CaptureLevelEdge(low: 48, high: 110, rise: 45)
    audioEdge = CaptureLevelEdge(low: 0.008, high: 0.03, rise: 0.02)
    tracker = CaptureAVSyncTracker()
    lines = []
    lock.unlock()
    emit("av sync test started. Play a flash and beep. Positive audio sync offset delays video; negative delays audio.")
  }

  func stop() {
    lock.lock()
    let wasRunning = running
    running = false
    let saved = lines
    lock.unlock()
    guard wasRunning else { return }
    emit("av sync test stopped")
    writeSummary(saved)
  }

  func noteVideo(luma: Float, time: Double, captureWidth: Int, captureHeight: Int, outputWidth: Int, outputHeight: Int, mode: String) {
    var match: CaptureAVSyncMatch?
    var stopAfter = false
    lock.lock()
    guard running else {
      lock.unlock()
      return
    }
    if videoEdge.observe(luma) {
      match = tracker.addFlash(CaptureAVSyncFlash(
        time: time,
        captureWidth: captureWidth,
        captureHeight: captureHeight,
        outputWidth: outputWidth,
        outputHeight: outputHeight,
        mode: mode
      ))
      if let match, match.count >= Self.pairGoal {
        running = false
        stopAfter = true
      }
    }
    lock.unlock()
    publish(match, stopAfter: stopAfter)
  }

  func noteAudio(rms: Float, time: Double) {
    var match: CaptureAVSyncMatch?
    var stopAfter = false
    lock.lock()
    guard running else {
      lock.unlock()
      return
    }
    if audioEdge.observe(rms) {
      match = tracker.addBeep(time: time)
      if let match, match.count >= Self.pairGoal {
        running = false
        stopAfter = true
      }
    }
    lock.unlock()
    publish(match, stopAfter: stopAfter)
  }

  private func publish(_ match: CaptureAVSyncMatch?, stopAfter: Bool) {
    guard let match else { return }
    let line = CaptureAVSyncLog.line(match: match, currentOffsetMs: currentOffsetMs())
    lock.lock()
    lines.append(line)
    let saved = lines
    lock.unlock()
    emit(line)
    if stopAfter {
      emit("av sync test finished n=\(match.count) avg=\(match.averageMs) ms")
      writeSummary(saved)
    }
  }

  private func emit(_ line: String) {
    logQueue.async {
      CaptureAudioFileLog.append(line)
    }
    let notify = onLine
    if Thread.isMainThread {
      notify?(line)
    } else {
      DispatchQueue.main.async {
        notify?(line)
      }
    }
  }

  private func writeSummary(_ saved: [String]) {
    guard !saved.isEmpty else { return }
    logQueue.async {
      let file = CaptureAudioFileLog.fileURL(home: URL(fileURLWithPath: NSHomeDirectory()))
        .deletingLastPathComponent()
        .appendingPathComponent("capture-av-sync.txt")
      let directory = file.deletingLastPathComponent()
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let body = saved.joined(separator: "\n") + "\n"
      try? Data(body.utf8).write(to: file)
    }
  }
}
