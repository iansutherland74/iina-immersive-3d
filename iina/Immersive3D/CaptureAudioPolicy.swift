//
//  CaptureAudioPolicy.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Muting Chrome silences the audio ScreenCaptureKit can read. macOS 13 cannot
//  capture another app's audio and also silence that app's speakers without a
//  virtual device. The default is to leave the sound in the source app.

import Foundation

enum CaptureAudioPolicy {
  /// ScreenCaptureKit hears the same mix the speakers play. Playing it in IINA
  /// while the browser still plays is an echo, and muting the browser silences
  /// that capture. The bundled loopback is the copy that gets played, so this
  /// stays off even when the user asked for sound.
  static func shouldCaptureAudio(userEnabled: Bool, virtualDevicePresent: Bool) -> Bool {
    _ = userEnabled
    _ = virtualDevicePresent
    return false
  }

  static func shouldRouteLoopback(userEnabled: Bool, deviceInstalled: Bool) -> Bool {
    userEnabled && deviceInstalled
  }

  /// Why the loopback was or was not started. Logged when a capture starts and
  /// when the toggle changes. The chooser closes as soon as capture starts, so
  /// this is the record of a toggle that was never shown.
  enum Offer: Equatable {
    case needsMacOS13
    case toggleOff
    case deviceMissing
    case previousOutputNotSaved
    case notCapturing
    case started

    var logLine: String {
      switch self {
      case .needsMacOS13:
        return "routing not started: needs macOS 13. Sound stays in the other app."
      case .toggleOff:
        return "routing not started: the toggle is off. Sound stays in the other app."
      case .deviceMissing:
        return "routing not started: IINA Capture Audio was not found. Sound stays in the other app."
      case .previousOutputNotSaved:
        return "routing not started: the previous output could not be saved. Sound stays in the other app."
      case .notCapturing:
        return "routing not started: a capture is not running. Sound stays in the other app."
      case .started:
        return "routing started: IINA Capture Audio is installed and the toggle is on."
      }
    }
  }

  static func deviceLine(installed: Bool) -> String {
    if installed {
      return "IINA Capture Audio: found (IINACaptureAudio_UID)."
    }
    return "IINA Capture Audio: not found. Turning the toggle on asks to install it."
  }

  /// The sentence under the toggle. Routing off leaves the browser's own sound playing.
  static func statusLine(systemSupportsRouting: Bool, userEnabled: Bool, deviceInstalled: Bool, capturing: Bool) -> String {
    let device = deviceLine(installed: deviceInstalled)
    if !systemSupportsRouting {
      return device + " Sound stays in the other app. Routing needs macOS 13."
    }
    if !userEnabled {
      return device + " Sound stays in the other app."
    }
    if !deviceInstalled {
      return device + " Sound stays in the other app."
    }
    if !capturing {
      return device + " The toggle is on. Sound moves when a capture is running."
    }
    return device + " Browser sound is playing through IINA, in time with the picture."
  }

  static func looksVirtual(name: String, uid: String) -> Bool {
    let haystack = (name + " " + uid).lowercased()
    let markers = [
      "blackhole",
      "soundflower",
      "loopback",
      "vb-audio",
      "vb-cable",
      "vbcable",
      "zoom audio",
      "background music",
      "iina capture audio",
      "iinacaptureaudio"
    ]
    return markers.contains { haystack.contains($0) }
  }
}
