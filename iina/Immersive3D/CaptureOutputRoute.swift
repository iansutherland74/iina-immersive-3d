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
