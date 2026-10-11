//
//  CaptureFrameCoalescer.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  The depth pass is slower than ScreenCaptureKit. Frames that arrive while a
//  draw is in flight replace each other, and the next draw is the newest one.

import Foundation

struct CaptureFrameCoalescer: Equatable {
  private(set) var drawing = false
  private(set) var pending: Int?
  private var newest = 0

  /// Records a frame. Returns its sequence, which replaces any frame not yet drawn.
  mutating func arrive() -> Int {
    newest += 1
    pending = newest
    return newest
  }

  /// The newest waiting frame, or nil when a draw is already running or nothing is waiting.
  mutating func takeForDraw() -> Int? {
    guard !drawing, let pending else { return nil }
    drawing = true
    self.pending = nil
    return pending
  }

  /// The draw finished. Returns a newer sequence when one arrived during the draw.
  mutating func finishDraw() -> Int? {
    drawing = false
    guard let pending else { return nil }
    let sequence = pending
    self.pending = nil
    drawing = true
    return sequence
  }
}

enum CaptureLatency {
  static func milliseconds(received: TimeInterval, presented: TimeInterval) -> Int {
    guard received.isFinite, presented.isFinite, presented >= received else { return 0 }
    return Int(((presented - received) * 1000).rounded())
  }
}
