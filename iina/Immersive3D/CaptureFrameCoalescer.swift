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

/// A drawable taken by `nextDrawable` or by AppKit displaying the layer belongs to
/// the current autorelease pool. Resizing in that same turn frees it, and the pool's
/// `objc_release` then crashes at 0x20. Quit is one of those turns: the Apple Event
/// pool is still alive when the window is put back.
struct CaptureDrawableGuard {
  var tookDrawable = false
  var presentCount = 0
  var resizePending = false
  private(set) var appliedOnThisTurn = false

  static func allowsResize(tookDrawable: Bool, presentCount: Int) -> Bool {
    presentCount == 0 && !tookDrawable
  }

  mutating func noteDrawable() {
    tookDrawable = true
    presentCount += 1
  }

  /// False means the size change is postponed until `nextTurn`.
  mutating func requestResize() -> Bool {
    if !Self.allowsResize(tookDrawable: tookDrawable, presentCount: presentCount) {
      resizePending = true
      appliedOnThisTurn = false
      return false
    }
    appliedOnThisTurn = true
    resizePending = false
    return true
  }

  /// The present returned in the turn that took the drawable. The pool still holds it.
  mutating func endSameTurn() {
    presentCount = max(0, presentCount - 1)
  }

  /// The next main-queue turn, after that pool has popped.
  mutating func nextTurn() -> Bool {
    guard presentCount == 0, resizePending else { return false }
    resizePending = false
    appliedOnThisTurn = true
    return true
  }
}

/// One slot is the blit still on the GPU, one is the newest frame waiting for
/// the main thread, and one is the stereo pass. A newer finished frame frees
/// the one that was waiting, so two busy slots do not skip every later frame.
struct CapturePresentSlots: Equatable {
  static let count = 3
  private(set) var pending: Int?

  /// Returns the slot that was waiting and must be released.
  mutating func offer(_ slot: Int) -> Int? {
    let replaced = pending
    pending = slot
    if replaced == slot {
      return nil
    }
    return replaced
  }
}

/// The three capture frame textures. A slot that is busy, queued, or being
/// presented is never handed out again. Reusing that texture while a blit still
/// reads it faults the GPU, and every later `submitFrame` then fails.
struct CaptureStagePool: Equatable {
  static let count = 3

  struct Claim: Equatable {
    var index: Int
    var generation: Int
  }

  private var busy: [Bool]
  private var generation: [Int]
  private var acquiredAt: [Double]
  private(set) var queued: Claim?
  private(set) var presenting: Claim?

  init(count: Int = CaptureStagePool.count) {
    busy = Array(repeating: false, count: count)
    generation = Array(repeating: 0, count: count)
    acquiredAt = Array(repeating: 0, count: count)
  }

  /// `now` is recorded and then ignored. Age is not a reason to reuse a texture.
  mutating func acquire(now: Double) -> Claim? {
    for index in busy.indices {
      if busy[index] || isHeld(index) { continue }
      generation[index] += 1
      busy[index] = true
      acquiredAt[index] = now
      return Claim(index: index, generation: generation[index])
    }
    return nil
  }

  /// The idle redraw presents the last texture again. A busy or held slot is left alone.
  mutating func claimExisting(index: Int, now: Double) -> Claim? {
    guard busy.indices.contains(index), !busy[index], !isHeld(index) else { return nil }
    generation[index] += 1
    busy[index] = true
    acquiredAt[index] = now
    return Claim(index: index, generation: generation[index])
  }

  func age(of index: Int, now: Double) -> Double {
    guard acquiredAt.indices.contains(index) else { return 0 }
    return now - acquiredAt[index]
  }

  func isHeld(_ index: Int) -> Bool {
    if let queued, queued.index == index { return true }
    if let presenting, presenting.index == index { return true }
    return false
  }

  /// The newest finished frame replaces the one still waiting. The caller releases the returned slot.
  mutating func enqueue(_ claim: Claim) -> Claim? {
    let replaced = queued
    queued = claim
    if let replaced, replaced.index == claim.index, replaced.generation == claim.generation {
      return nil
    }
    return replaced
  }

  /// The main thread took the waiting frame. It stays held until `release`.
  mutating func takeForPresent() -> Claim? {
    guard let waiting = queued else { return nil }
    queued = nil
    presenting = waiting
    return waiting
  }

  mutating func notePresenting(index: Int, generation: Int) {
    guard self.generation.indices.contains(index), self.generation[index] == generation else { return }
    presenting = Claim(index: index, generation: generation)
  }

  @discardableResult
  mutating func release(_ claim: Claim) -> Bool {
    guard generation.indices.contains(claim.index), generation[claim.index] == claim.generation else { return false }
    busy[claim.index] = false
    if queued == claim { queued = nil }
    if presenting == claim { presenting = nil }
    return true
  }
}

/// The sample callback copies and returns. A frame that is already late is not
/// presented when a newer copy is waiting, so one GPU stall does not become the picture.
enum CapturePresentBudget {
  static let staleSeconds = 0.080

  static func shouldPresent(age: Double, newerWaiting: Bool) -> Bool {
    guard age.isFinite, age >= 0 else { return false }
    if newerWaiting && age > staleSeconds { return false }
    return true
  }
}

/// The audio delay follows the usual capture latency. A 181–575 ms stall is ignored
/// so the sound does not jump half a second and back.
struct CaptureLatencySmooth: Equatable {
  private(set) var baseline = 0.0
  static let spikeMargin = 0.080

  mutating func observe(_ sample: Double) -> Double {
    guard sample.isFinite, sample >= 0 else { return baseline }
    if baseline > 0, sample > baseline + Self.spikeMargin {
      return baseline
    }
    let clamped = min(sample, 2)
    if baseline == 0 {
      baseline = min(clamped, Self.spikeMargin)
    } else {
      baseline = baseline * 0.85 + clamped * 0.15
    }
    return baseline
  }
}
