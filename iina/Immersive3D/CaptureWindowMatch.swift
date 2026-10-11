//
//  CaptureWindowMatch.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Full-screen YouTube replaces the window id and the title. Follow the same
//  app by bundle id, then the largest window on any Space. If that app has no
//  window left, capture the display the window was on.

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

enum CaptureWindowMatch {
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

  static func decide(track: CaptureTrack, windows: [CaptureWindowRecord], displayIDs: [UInt32]) -> CaptureFollowDecision {
    let sameApp = windows.filter { sameApp($0, track) }
    if track.kind == .display {
      guard !track.bundleID.isEmpty || !track.owner.isEmpty, let best = largest(sameApp) else {
        return .keep
      }
      let app = appName(track)
      return .window(best, "\(app) window \(best.id) is back; leaving whole-display capture")
    }
    if let current = windows.first(where: { $0.id == track.windowID }) {
      if let replacement = titleReplacement(track: track, current: current, windows: windows) {
        return .window(replacement, "window \(track.windowID) replaced by \(replacement.id) (same title)")
      }
      if !current.onScreen, let best = largest(sameApp.filter { $0.id != current.id }) {
        let app = appName(track)
        return .window(best, "window \(track.windowID) left the screen; using largest \(app) window \(best.id)")
      }
      return .keep
    }
    if let best = largest(sameApp) {
      let app = appName(track)
      return .window(best, "window \(track.windowID) is gone; largest \(app) window \(best.id) \(best.width)x\(best.height)")
    }
    let display = track.displayID != 0 ? track.displayID : (displayIDs.first ?? 0)
    if display != 0 {
      let app = appName(track)
      return .display(id: display, reason: "window \(track.windowID) is gone; no \(app) window; capturing display \(display)")
    }
    return .keep
  }

  private static func titleReplacement(track: CaptureTrack, current: CaptureWindowRecord, windows: [CaptureWindowRecord]) -> CaptureWindowRecord? {
    let titled = windows.filter { window in
      window.id != track.windowID && sameApp(window, track) && titlesMatch(window.title, track.title)
    }
    guard let match = preferred(titled) else { return nil }
    if !current.onScreen && match.onScreen { return match }
    if current.area > 1 && match.area > Int(Double(current.area) * 1.3) { return match }
    return nil
  }

  private static func sameApp(_ window: CaptureWindowRecord, _ track: CaptureTrack) -> Bool {
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
    if lhs.isEmpty || rhs.isEmpty { return false }
    if lhs.caseInsensitiveCompare(rhs) == .orderedSame { return true }
    let left = lhs.lowercased()
    let right = rhs.lowercased()
    guard left.count >= 4, right.count >= 4 else { return false }
    return left.contains(right) || right.contains(left)
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
