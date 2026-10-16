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

/// Play on Glasses, the Immersive 3D toggle, and a glasses display-mode change
/// (the hardware 3D button switching the panel to side-by-side) do not move the
/// system output and do not pin or unpin mpv. The picture path repins a window.
/// The DisplayPort device restart is handled by the loopback output IO proc.
enum CaptureGlassesAudio {
  enum Action: Equatable {
    case playOnGlasses
    case exitGlasses
    case immersive3DToggle
    case screenParameters
  }

  static func routeEffects(for action: Action) -> [CaptureOutputRoute.Effect] {
    switch action {
    case .playOnGlasses, .exitGlasses, .immersive3DToggle, .screenParameters:
      return []
    }
  }
}

/// While a capture is routed, a device list change must not send mpv to auto.
/// The glasses 3D mode drops the DisplayPort device out of the list for a moment.
enum CapturePinnedDeviceHold {
  static func keepMPVDevice(routed: Bool, deviceStillListed: Bool) -> Bool {
    routed && !deviceStillListed
  }
}

/// What the loopback output does when Core Audio reports a device change.
/// A match means the IO proc we already opened still describes the device.
/// Default-device notifications never select a new UID.
enum CaptureOutputWatch {
  static let deviceIsRunning = "DeviceIsRunning"
  static let deviceIsAlive = "DeviceIsAlive"
  static let nominalSampleRate = "NominalSampleRate"
  static let streamFormat = "StreamFormat"
  static let devices = "Devices"
  static let defaultOutput = "DefaultOutputDevice"
  static let defaultSystemOutput = "DefaultSystemOutputDevice"

  struct Snapshot: Equatable {
    var deviceID: UInt32
    var alive: Bool
    var running: Bool
    var sampleRate: Double
    var channels: Int
    /// Sample format of the stream the IO proc was opened with. A glasses mode
    /// switch can keep the rate and channel count while changing these.
    var bits: Int = 0
    var isFloat: Bool = false
    var bytesPerFrame: Int = 0
    var nonInterleaved: Bool = false
  }

  enum Notice: Equatable {
    case running(Bool)
    case alive(Bool)
    case nominalSampleRate(Double)
    case streamFormat(sampleRate: Double, channels: Int)
    case devicesChanged
    case defaultOutputChanged
    case defaultSystemOutputChanged

    var name: String {
      switch self {
      case .running: return CaptureOutputWatch.deviceIsRunning
      case .alive: return CaptureOutputWatch.deviceIsAlive
      case .nominalSampleRate: return CaptureOutputWatch.nominalSampleRate
      case .streamFormat: return CaptureOutputWatch.streamFormat
      case .devicesChanged: return CaptureOutputWatch.devices
      case .defaultOutputChanged: return CaptureOutputWatch.defaultOutput
      case .defaultSystemOutputChanged: return CaptureOutputWatch.defaultSystemOutput
      }
    }
  }

  enum Step: Equatable {
    case keep
    case restart(String)
  }

  static func matches(_ applied: Snapshot, _ resolved: Snapshot) -> Bool {
    applied.deviceID == resolved.deviceID
      && applied.alive == resolved.alive
      && applied.running == resolved.running
      && applied.channels == resolved.channels
      && applied.bits == resolved.bits
      && applied.isFloat == resolved.isFloat
      && applied.bytesPerFrame == resolved.bytesPerFrame
      && applied.nonInterleaved == resolved.nonInterleaved
      && abs(applied.sampleRate - resolved.sampleRate) < 0.5
  }

  /// `rebuiltRecently` is true when this process just opened the IO proc.
  /// A default-device or device-list notification still rebuilds once, because
  /// the glasses can reset the stream without changing the id. A second copy of
  /// that notification, while the resolved device still matches, is the echo of
  /// that rebuild.
  static func step(notice: Notice, applied: Snapshot, resolved: Snapshot, rebuiltRecently: Bool) -> Step {
    if !matches(applied, resolved) {
      return .restart(notice.name)
    }
    switch notice {
    case .devicesChanged, .defaultOutputChanged, .defaultSystemOutputChanged:
      return rebuiltRecently ? .keep : .restart(notice.name)
    case .running, .alive, .nominalSampleRate, .streamFormat:
      return .keep
    }
  }

  static func routeEffects(for notice: Notice) -> [CaptureOutputRoute.Effect] {
    switch notice {
    case .running, .alive, .nominalSampleRate, .streamFormat, .devicesChanged, .defaultOutputChanged, .defaultSystemOutputChanged:
      return []
    }
  }
}

/// 48 kHz stereo from the loopback, rendered into the output device's rate and
/// channel layout. Linear interpolation. A missing source frame is silence and
/// counts as an underrun. Channel indexes are 0-based.
enum CaptureLoopbackMix {
  static let sourceRate = 48000.0

  struct Request: Equatable {
    var outputFrames: Int
    var deviceRate: Double
    var channels: Int
    var left: Int
    var right: Int
    var phase: Double
  }

  struct Result: Equatable {
    var samples: [Float]
    var consumed: Int
    var phase: Double
    var underrunFrames: Int
  }

  struct Tail: Equatable {
    var consumed: Int
    var phase: Double
    var underrunFrames: Int
  }

  /// `preferred` is the 1-based pair from kAudioDevicePropertyPreferredChannelsForStereo.
  /// An unusable pair falls back to the first one or two channels.
  static func stereoPair(preferred: [UInt32], channels: Int) -> (left: Int, right: Int) {
    let count = max(channels, 1)
    let fallbackRight = count > 1 ? 1 : 0
    guard preferred.count >= 2 else { return (0, fallbackRight) }
    let left = Int(preferred[0])
    let right = Int(preferred[1])
    guard left >= 1, right >= 1, left <= count, right <= count else {
      return (0, fallbackRight)
    }
    return (left - 1, right - 1)
  }

  static func render(source: [Float], request: Request) -> Result {
    let channels = max(request.channels, 1)
    let outputFrames = max(request.outputFrames, 0)
    var samples = [Float](repeating: 0, count: outputFrames * channels)
    guard outputFrames > 0 else {
      return Result(samples: samples, consumed: 0, phase: request.phase, underrunFrames: 0)
    }
    let sourceFrames = source.count / 2
    guard sourceFrames > 0 else {
      return Result(samples: samples, consumed: 0, phase: 0, underrunFrames: outputFrames)
    }
    let tail = source.withUnsafeBufferPointer { src -> Tail in
      guard let inBase = src.baseAddress else {
        return Tail(consumed: 0, phase: 0, underrunFrames: outputFrames)
      }
      return samples.withUnsafeMutableBufferPointer { destination -> Tail in
        guard let outBase = destination.baseAddress else {
          return Tail(consumed: 0, phase: 0, underrunFrames: outputFrames)
        }
        return render(
          source: inBase,
          sourceFrames: sourceFrames,
          output: outBase,
          outputFrames: outputFrames,
          deviceRate: request.deviceRate,
          channels: channels,
          left: request.left,
          right: request.right,
          phase: request.phase
        )
      }
    }
    return Result(samples: samples, consumed: tail.consumed, phase: tail.phase, underrunFrames: tail.underrunFrames)
  }

  static func render(
    source: UnsafePointer<Float>,
    sourceFrames: Int,
    output: UnsafeMutablePointer<Float>,
    outputFrames: Int,
    deviceRate: Double,
    channels: Int,
    left: Int,
    right: Int,
    phase: Double
  ) -> Tail {
    let channelCount = max(channels, 1)
    let frames = max(outputFrames, 0)
    let leftIndex = min(max(left, 0), channelCount - 1)
    let rightIndex = min(max(right, 0), channelCount - 1)
    for index in 0..<(frames * channelCount) {
      output[index] = 0
    }
    guard frames > 0 else {
      return Tail(consumed: 0, phase: phase, underrunFrames: 0)
    }
    guard sourceFrames > 0 else {
      return Tail(consumed: 0, phase: 0, underrunFrames: frames)
    }
    let rate = deviceRate > 0 ? deviceRate : sourceRate
    let step = sourceRate / rate
    var start = phase
    if !start.isFinite || start < 0 { start = 0 }
    var underrun = 0
    for frame in 0..<frames {
      let position = start + Double(frame) * step
      if position < 0 {
        underrun += 1
        continue
      }
      let index = Int(position)
      if index >= sourceFrames {
        underrun += 1
        continue
      }
      let fraction = Float(position - Double(index))
      let firstLeft = source[index * 2]
      let firstRight = source[index * 2 + 1]
      let secondLeft: Float
      let secondRight: Float
      if index + 1 < sourceFrames {
        secondLeft = source[(index + 1) * 2]
        secondRight = source[(index + 1) * 2 + 1]
      } else {
        secondLeft = firstLeft
        secondRight = firstRight
      }
      let mixedLeft = firstLeft + (secondLeft - firstLeft) * fraction
      let mixedRight = firstRight + (secondRight - firstRight) * fraction
      let base = frame * channelCount
      if leftIndex == rightIndex {
        output[base + leftIndex] = (mixedLeft + mixedRight) * 0.5
      } else {
        output[base + leftIndex] = mixedLeft
        output[base + rightIndex] = mixedRight
      }
    }
    let end = start + Double(frames) * step
    var consumed = end > 0 ? Int(end) : 0
    if consumed > sourceFrames { consumed = sourceFrames }
    if consumed < 0 { consumed = 0 }
    let next: Double
    if consumed >= sourceFrames {
      consumed = sourceFrames
      next = 0
    } else {
      next = end - Double(consumed)
    }
    return Tail(consumed: consumed, phase: next > 0 ? next : 0, underrunFrames: underrun)
  }
}
