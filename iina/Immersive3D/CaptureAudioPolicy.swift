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
  /// IINA plays captured audio only when the user asked and a virtual output
  /// device is installed for the browser to use. Mute is not an input: it would
  /// remove the same samples the capture needs.
  static func shouldCaptureAudio(userEnabled: Bool, virtualDevicePresent: Bool) -> Bool {
    userEnabled && virtualDevicePresent
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
      "background music"
    ]
    return markers.contains { haystack.contains($0) }
  }
}
