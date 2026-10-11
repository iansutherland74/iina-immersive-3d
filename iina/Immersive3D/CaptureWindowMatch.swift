//
//  CaptureWindowMatch.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Full-screen Chrome keeps the real window id and adds an untitled placeholder
//  on the full-screen Space. The real window often reports isOnScreen == false
//  because it lives on another Space. Switching on that flag flips the filter
//  every follow tick. Stay on the current id until it has been absent, and
//  never adopt an untitled or tiny window.

import CoreGraphics
import Foundation

struct CaptureWindowRecord: Equatable {
  var id: UInt32
  var title: String
  var owner: String
  var bundleID: String
  var width: Int
  var height: Int
  var onScreen: Bool
  var displayID: UInt32

  var area: Int { max(width, 0) * max(height, 0) }
}

struct CaptureTrack: Equatable {
  enum Kind: Equatable {
    case window
    case display
  }

  var kind: Kind
  var windowID: UInt32
  var title: String
  var owner: String
  var bundleID: String
  var displayID: UInt32
}

enum CaptureFollowDecision: Equatable {
  case keep
  case window(CaptureWindowRecord, reason: String)
  case display(id: UInt32, reason: String)
}

struct CaptureFollowClock: Equatable {
  /// When the tracked window id was first missing from the list. Nil while that id exists.
  var absentSince: TimeInterval?
  /// The id most recently left. A follow tick will not return to it inside `switchDelay`.
  var departedID: UInt32
  var departedAt: TimeInterval

  static let empty = CaptureFollowClock(absentSince: nil, departedID: 0, departedAt: 0)
  /// The current id must be missing for longer than this before the filter changes.
  static let switchDelay: TimeInterval = 1.5
}

struct CaptureFollowOutcome: Equatable {
  var decision: CaptureFollowDecision
  var clock: CaptureFollowClock
}

enum CaptureWindowMatch {
  /// A full-screen Space shadow has an empty title. A tiny window is not the video.
  /// Off-screen is not enough: the real window on another Space is off-screen too.
  static func isPlaceholder(_ window: CaptureWindowRecord) -> Bool {
    let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if title.isEmpty { return true }
    if window.width < 200 || window.height < 200 { return true }
    return false
  }

  /// Largest overlap of `frame` with a display. Zero when none overlap.
  static func displayID(covering frame: CGRect, displays: [(id: UInt32, frame: CGRect)]) -> UInt32 {
    var bestID: UInt32 = 0
    var bestArea: CGFloat = 0
    for display in displays {
      let area = frame.intersection(display.frame).integralArea
      if area > bestArea {
        bestArea = area
        bestID = display.id
      }
    }
    return bestID
  }

  static func decide(
    track: CaptureTrack,
    windows: [CaptureWindowRecord],
    displayIDs: [UInt32],
    now: TimeInterval,
    clock: CaptureFollowClock
  ) -> CaptureFollowOutcome {
    var clock = clock
    let real = windows.filter { matchesApp($0, track) && !isPlaceholder($0) }

    if track.kind == .display {
      guard !track.bundleID.isEmpty || !track.owner.isEmpty,
            let best = choose(real, title: track.title, avoiding: nil, now: now, clock: clock) else {
        return CaptureFollowOutcome(decision: .keep, clock: clock)
      }
      clock.absentSince = nil
      clock.departedID = 0
      clock.departedAt = now
      let app = appName(track)
      return CaptureFollowOutcome(
        decision: .window(best, reason: "\(app) window \(best.id) is back; leaving whole-display capture"),
        clock: clock
      )
    }

    if let current = windows.first(where: { $0.id == track.windowID }) {
      clock.absentSince = nil
      if !isPlaceholder(current) {
        return CaptureFollowOutcome(decision: .keep, clock: clock)
      }
      if let best = choose(real, title: track.title, avoiding: current.id, now: now, clock: clock) {
        clock.departedID = current.id
        clock.departedAt = now
        let app = appName(track)
        return CaptureFollowOutcome(
          decision: .window(best, reason: "leaving untitled \(app) window \(current.id); using \(best.id)"),
          clock: clock
        )
      }
      return CaptureFollowOutcome(decision: .keep, clock: clock)
    }

    let since = clock.absentSince ?? now
    clock.absentSince = since
    if now - since <= CaptureFollowClock.switchDelay {
      return CaptureFollowOutcome(decision: .keep, clock: clock)
    }

    if let best = choose(real, title: track.title, avoiding: nil, now: now, clock: clock) {
      clock.departedID = track.windowID
      clock.departedAt = now
      clock.absentSince = nil
      let app = appName(track)
      return CaptureFollowOutcome(
        decision: .window(best, reason: "window \(track.windowID) is gone; \(app) window \(best.id) \(best.title)"),
        clock: clock
      )
    }

    let display = track.displayID != 0 ? track.displayID : (displayIDs.first ?? 0)
    if display != 0 {
      clock.departedID = track.windowID
      clock.departedAt = now
      clock.absentSince = nil
      let app = appName(track)
      return CaptureFollowOutcome(
        decision: .display(id: display, reason: "window \(track.windowID) is gone; no \(app) window; capturing display \(display)"),
        clock: clock
      )
    }
    return CaptureFollowOutcome(decision: .keep, clock: clock)
  }

  private static func choose(
    _ windows: [CaptureWindowRecord],
    title: String,
    avoiding: UInt32?,
    now: TimeInterval,
    clock: CaptureFollowClock
  ) -> CaptureWindowRecord? {
    var pool = windows
    if let avoiding {
      pool = pool.filter { $0.id != avoiding }
    }
    if clock.departedID != 0, now - clock.departedAt <= CaptureFollowClock.switchDelay {
      let filtered = pool.filter { $0.id != clock.departedID }
      if !filtered.isEmpty {
        pool = filtered
      }
    }
    let titled = pool.filter { titlesMatch($0.title, title) }
    if let match = preferred(titled) {
      return match
    }
    return largest(pool)
  }

  private static func matchesApp(_ window: CaptureWindowRecord, _ track: CaptureTrack) -> Bool {
    if !track.bundleID.isEmpty, window.bundleID == track.bundleID { return true }
    if !track.owner.isEmpty, window.owner.caseInsensitiveCompare(track.owner) == .orderedSame { return true }
    return false
  }

  private static func largest(_ windows: [CaptureWindowRecord]) -> CaptureWindowRecord? {
    windows.max { lhs, rhs in
      if lhs.area != rhs.area { return lhs.area < rhs.area }
      if lhs.onScreen != rhs.onScreen { return rhs.onScreen }
      return lhs.id > rhs.id
    }
  }

  private static func preferred(_ windows: [CaptureWindowRecord]) -> CaptureWindowRecord? {
    windows.max { lhs, rhs in
      if lhs.onScreen != rhs.onScreen { return rhs.onScreen }
      return lhs.area < rhs.area
    }
  }

  private static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
    let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    if left.isEmpty || right.isEmpty { return false }
    if left.caseInsensitiveCompare(right) == .orderedSame { return true }
    let lowerLeft = left.lowercased()
    let lowerRight = right.lowercased()
    guard lowerLeft.count >= 4, lowerRight.count >= 4 else { return false }
    return lowerLeft.contains(lowerRight) || lowerRight.contains(lowerLeft)
  }

  private static func appName(_ track: CaptureTrack) -> String {
    if !track.bundleID.isEmpty { return track.bundleID }
    if !track.owner.isEmpty { return track.owner }
    return "app"
  }
}

private extension CGRect {
  var integralArea: CGFloat {
    guard !isNull, !isInfinite else { return 0 }
    return max(width, 0) * max(height, 0)
  }
}
