//
//  CaptureOutputRoute.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Decides the order of the loopback switch. The player is pinned to the real
//  output before the system default moves, and the real output is written down
//  before either change. Nothing here touches a device.

import Foundation

enum CaptureOutputRoute {
  static let virtualUID = "IINACaptureAudio_UID"
  static let virtualName = "IINA Capture Audio"
  static let toggleTitle = "Route browser sound through IINA (no echo, synced)"
  static let defaultsKey = "IINARouteBrowserSoundThroughIINA"

  struct Snapshot: Equatable {
    var outputUID: String
    var mpvDevice: String
  }

  enum Phase: Equatable {
    case idle
    case routed(saved: Snapshot, virtualUID: String)
  }

  struct State: Equatable {
    var phase: Phase = .idle
    var crashUID: String? = nil
  }

  enum Effect: Equatable {
    case writeCrashFile(String)
    case deleteCrashFile
    case setMPVDevice(String)
    case setSystemOutput(String)
  }

  enum Refusal: Equatable {
    case off
    case notCapturing
    case missingDevice
    case noRealDevice
  }

  enum BeginResult: Equatable {
    case routed
    case already
    case refused(Refusal)
  }

  struct Plan: Equatable {
    var state: State
    var effects: [Effect]
    var began: BeginResult
  }

  static func mpvName(forRealUID uid: String) -> String {
    "coreaudio/\(uid)"
  }

  static func isVirtualUID(_ uid: String) -> Bool {
    uid == virtualUID || CaptureAudioPolicy.looksVirtual(name: "", uid: uid)
  }

  /// The toggle and a running capture are both required. Otherwise the plan
  /// is empty, so ordinary playback never moves the system output.
  static func engage(
    state: State,
    capturing: Bool,
    enabled: Bool,
    installed: Bool,
    current: Snapshot,
    fallbackRealUID: String?
  ) -> Plan {
    guard capturing else {
      return Plan(state: state, effects: [], began: .refused(.notCapturing))
    }
    guard enabled else {
      return Plan(state: state, effects: [], began: .refused(.off))
    }
    guard installed else {
      return Plan(state: state, effects: [], began: .refused(.missingDevice))
    }
    if case .routed = state.phase {
      return Plan(state: state, effects: [], began: .already)
    }
    let real = realOutput(current: current, crashUID: state.crashUID, fallbackRealUID: fallbackRealUID)
    guard let real else {
      return Plan(state: state, effects: [], began: .refused(.noRealDevice))
    }
    var next = state
    next.phase = .routed(
      saved: Snapshot(outputUID: real, mpvDevice: current.mpvDevice),
      virtualUID: virtualUID
    )
    next.crashUID = real
    return Plan(
      state: next,
      effects: [
        .writeCrashFile(real),
        .setMPVDevice(mpvName(forRealUID: real)),
        .setSystemOutput(virtualUID)
      ],
      began: .routed
    )
  }

  static func end(state: State) -> Plan {
    guard case .routed(let saved, _) = state.phase else {
      return Plan(state: state, effects: [], began: .already)
    }
    var next = state
    next.phase = .idle
    next.crashUID = nil
    return Plan(
      state: next,
      effects: [
        .setSystemOutput(saved.outputUID),
        .setMPVDevice(saved.mpvDevice),
        .deleteCrashFile
      ],
      began: .routed
    )
  }

  /// Next launch after a crash. Restores the output that was current before
  /// the switch. It does not change the player's device; mpv has not opened yet.
  static func recover(state: State) -> Plan {
    guard let uid = state.crashUID, !uid.isEmpty, !isVirtualUID(uid) else {
      var next = state
      next.crashUID = nil
      let effects: [Effect] = state.crashUID == nil ? [] : [.deleteCrashFile]
      return Plan(state: next, effects: effects, began: .already)
    }
    return Plan(
      state: State(),
      effects: [.setSystemOutput(uid), .deleteCrashFile],
      began: .routed
    )
  }

  private static func realOutput(current: Snapshot, crashUID: String?, fallbackRealUID: String?) -> String? {
    if !current.outputUID.isEmpty && !isVirtualUID(current.outputUID) {
      return current.outputUID
    }
    if let crashUID, !crashUID.isEmpty, !isVirtualUID(crashUID) {
      return crashUID
    }
    if let fallbackRealUID, !fallbackRealUID.isEmpty, !isVirtualUID(fallbackRealUID) {
      return fallbackRealUID
    }
    return nil
  }
}

/// Saved on top of the measured picture delay. Negative plays earlier.
enum CaptureSyncOffset {
  static let defaultsKey = "IINACaptureAudioSyncOffsetMS"
  static let changedNotification = Notification.Name("IINACaptureAudioSyncOffsetChanged")
  static let routeChangedNotification = Notification.Name("IINACaptureAudioRouteChanged")
  static let minMs = -500
  static let maxMs = 500

  static func clamp(_ ms: Int) -> Int {
    min(max(ms, minMs), maxMs)
  }

  static func label(ms: Int) -> String {
    let value = clamp(ms)
    if value > 0 { return "Audio sync +\(value) ms" }
    return "Audio sync \(value) ms"
  }

  static func delay(automatic seconds: Double, offsetMs: Int) -> Double {
    let automatic = seconds.isFinite ? seconds : 0
    return automatic + Double(clamp(offsetMs)) / 1000
  }
}

/// Both system outputs have to move, and the read-back id has to match, or the
/// switch did not happen. Logging "restored" without that check was a false success.
enum CaptureDefaultOutput {
  static let propertyCount = 2

  struct Write: Equatable {
    var status: Int32
    var readBack: UInt32
  }

  static func accepted(deviceID: UInt32, writes: [Write]) -> Bool {
    guard deviceID != 0, writes.count == propertyCount else { return false }
    return writes.allSatisfy { $0.status == 0 && $0.readBack == deviceID }
  }

  static func statusText(_ status: Int32) -> String {
    if status == 0 { return "0" }
    let value = UInt32(bitPattern: status)
    let bytes = [
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff)
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let text = String(bytes: bytes, encoding: .ascii) {
      return "\(status) '\(text)'"
    }
    return "\(status)"
  }
}

enum CaptureLoopbackClock {
  static let lateWindow = 0.20
  static let lead = 0.050

  struct Chunk: Equatable {
    var hostTime: Double
    var duration: Double
  }

  enum Decision: Equatable {
    case wait
    case play
    case drop
  }

  /// Play a loopback chunk once the picture has caught up to it. Drop it when
  /// it is later than the picture by more than the late window.
  static func decide(chunk: Chunk, now: Double, delay: Double) -> Decision {
    let playAt = chunk.hostTime + delay
    if now > playAt + lateWindow {
      return .drop
    }
    if playAt > now + lead {
      return .wait
    }
    return .play
  }
}

/// The output IO proc plays on the device written to the restore file. That is
/// the glasses when they were the default output. The virtual device is never
/// a playback target: the system default is the loopback while a capture runs.
enum CapturePlaybackRoute {
  enum Encoding: Equatable {
    case float32Interleaved
    case float32Planar
    case int16Interleaved
    case unsupported
  }

  struct Plan: Equatable {
    var sampleRate: Double
    var channels: Int
    var encoding: Encoding
    var resample: Bool
  }

  static func uid(restore: String?, pinned: String?) -> String? {
    let saved = cleaned(restore)
    if let saved, !CaptureOutputRoute.isVirtualUID(saved) {
      return saved
    }
    let fallback = cleaned(pinned)
    if let fallback, !CaptureOutputRoute.isVirtualUID(fallback) {
      return fallback
    }
    return nil
  }

  /// Glasses are 2 ch at 48 kHz or 44.1 kHz. The loopback is always 48 kHz,
  /// so a 44.1 kHz device has to be resampled or the IO proc writes the wrong
  /// clock and the glasses stay silent.
  static func plan(sampleRate: Double, channels: Int, bits: Int, isFloat: Bool, interleaved: Bool) -> Plan {
    let rate = sampleRate > 0 ? sampleRate : 48000
    let count = channels > 0 ? channels : 2
    let encoding: Encoding
    if isFloat && bits == 32 && interleaved {
      encoding = .float32Interleaved
    } else if isFloat && bits == 32 && !interleaved {
      encoding = .float32Planar
    } else if !isFloat && bits == 16 && interleaved {
      encoding = .int16Interleaved
    } else {
      encoding = .unsupported
    }
    return Plan(sampleRate: rate, channels: count, encoding: encoding, resample: abs(rate - 48000) > 1)
  }

  private static func cleaned(_ uid: String?) -> String? {
    guard let uid else { return nil }
    let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// Linear resampler from the 48 kHz loopback to the output device rate.
enum CaptureRateConvert {
  struct Stream {
    var fromRate: Double
    var toRate: Double
    var channels: Int
    private var pending: [Float] = []
    private var phase = 0.0

    init(fromRate: Double, toRate: Double, channels: Int) {
      self.fromRate = fromRate > 0 ? fromRate : 48000
      self.toRate = toRate > 0 ? toRate : 48000
      self.channels = max(channels, 1)
    }

    mutating func reset(fromRate: Double, toRate: Double, channels: Int) {
      self = Stream(fromRate: fromRate, toRate: toRate, channels: channels)
    }

    mutating func process(_ interleaved: [Float]) -> [Float] {
      guard channels > 0, interleaved.count >= channels else { return [] }
      if abs(fromRate - toRate) <= 1 {
        return interleaved
      }
      pending.append(contentsOf: interleaved)
      let available = pending.count / channels
      guard available >= 2 else { return [] }
      let step = fromRate / toRate
      var produced: [Float] = []
      while phase + 1 < Double(available) {
        let index = Int(phase)
        let fraction = Float(phase - Double(index))
        for channel in 0..<channels {
          let a = pending[index * channels + channel]
          let b = pending[(index + 1) * channels + channel]
          produced.append(a + (b - a) * fraction)
        }
        phase += step
      }
      let drop = min(Int(phase), max(available - 1, 0))
      if drop > 0 {
        pending.removeFirst(drop * channels)
        phase -= Double(drop)
      }
      return produced
    }
  }

  static func convert(_ interleaved: [Float], channels: Int, fromRate: Double, toRate: Double) -> [Float] {
    var stream = Stream(fromRate: fromRate, toRate: toRate, channels: channels)
    return stream.process(interleaved)
  }

  static func int16(_ sample: Float) -> Int16 {
    guard sample.isFinite else { return 0 }
    let clamped = min(max(sample, -1), 1)
    return Int16((clamped * 32767).rounded())
  }
}

/// A volume of 0, or a mute, on IINA Capture Audio silences the read. The
/// device has no slider of its own until it becomes the default output, and
/// macOS can leave the scalar at 0.
enum CaptureDeviceGain {
  static func restoredScalar(_ scalar: Float) -> Float? {
    scalar <= 0.0001 ? 1 : nil
  }

  static func shouldClearMute(_ muted: Bool) -> Bool {
    muted
  }
}

/// Microphone TCC applies to the loopback input. The orange mic indicator
/// means the IO proc is running; without authorization, macOS still fills
/// every buffer with zeros. `NSAudioCaptureUsageDescription` does not cover
/// this prompt.
enum CaptureMicAuthorization: Equatable {
  case notDetermined
  case restricted
  case denied
  case authorized
}

enum CaptureMicAccess {
  static func usageDescriptionPresent(_ info: [String: Any]?) -> Bool {
    guard let text = info?["NSMicrophoneUsageDescription"] as? String else { return false }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The system prompt has to finish before `AudioDeviceStart`. Starting the
  /// input while the answer is still pending leaves the orange indicator on
  /// and the samples at zero for that IO proc.
  static func waitForDecision(_ status: CaptureMicAuthorization) -> Bool {
    status == .notDetermined
  }

  static func inputWillBeSilence(_ status: CaptureMicAuthorization) -> Bool {
    status != .authorized
  }

  static func logLine(status: CaptureMicAuthorization, usageDescriptionPresent: Bool) -> String {
    let name: String
    switch status {
    case .notDetermined: name = "notDetermined"
    case .restricted: name = "restricted"
    case .denied: name = "denied"
    case .authorized: name = "authorized"
    }
    let described = usageDescriptionPresent ? "present" : "missing"
    let input = inputWillBeSilence(status) ? "silence" : "live"
    var line = "loopback mic authorization \(name) usageDescription=\(described) input=\(input)"
    if status == .denied || status == .restricted {
      line += " enable Microphone for IINA in System Settings"
    }
    return line
  }
}

/// Pinning the capture on the glasses reopens the output after the display
/// mode settles. It does not stop the reader, or the browser's audio is gone
/// for the rest of the capture.
enum CaptureGlassesAudioHandoff {
  struct Result: Equatable {
    var stopReader: Bool
    var reopenOutput: Bool
  }

  static func afterPin(readerRunning: Bool) -> Result {
    Result(stopReader: false, reopenOutput: readerRunning)
  }
}

/// Unified logging redacts these lines on the machine that has the glasses.
/// The same text is appended here so it can be read from the home directory.
enum CaptureAudioFileLog {
  static let maxBytes = 200_000

  private static let lock = NSLock()
  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  static func fileURL(home: URL) -> URL {
    home
      .appendingPathComponent("Library/Logs/IINA", isDirectory: true)
      .appendingPathComponent("capture-audio.log")
  }

  static func append(_ line: String, home: URL = URL(fileURLWithPath: NSHomeDirectory()), maxBytes: Int = CaptureAudioFileLog.maxBytes) {
    let text = line.trimmingCharacters(in: .newlines)
    guard !text.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    let file = fileURL(home: home)
    let directory = file.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      return
    }
    rotateIfNeeded(file, maxBytes: maxBytes)
    let stamped = formatter.string(from: Date()) + " " + text + "\n"
    if FileManager.default.fileExists(atPath: file.path),
       let handle = try? FileHandle(forWritingTo: file) {
      _ = try? handle.seekToEnd()
      handle.write(Data(stamped.utf8))
      try? handle.close()
    } else {
      try? Data(stamped.utf8).write(to: file)
    }
  }

  private static func rotateIfNeeded(_ file: URL, maxBytes: Int) {
    guard maxBytes > 0,
          let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
          let size = attrs[.size] as? NSNumber,
          size.intValue > maxBytes else { return }
    let backup = URL(fileURLWithPath: file.path + ".1")
    try? FileManager.default.removeItem(at: backup)
    try? FileManager.default.moveItem(at: file, to: backup)
  }
}
