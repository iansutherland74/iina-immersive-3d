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
