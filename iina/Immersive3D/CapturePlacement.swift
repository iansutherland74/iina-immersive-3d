//
//  CapturePlacement.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Full-screen Chrome on macOS can move its Space onto the glasses display.
//  ScreenCaptureKit then delivers one black frame for the window that was left
//  on the built-in display and idle after that, because that surface is no
//  longer changing. Pinning IINA's picture on the same display covers the game
//  or films IINA itself. This decides when to follow the display the window is
//  actually on, and when the glasses picture has to move back to the Mac.

import CoreGraphics
import Foundation

struct CaptureDisplay: Equatable {
  var id: UInt32
  var frame: CGRect
  var name: String
  /// SmartGlasses, NXTWEAR, or another 3840×1080 / 1920×1080 output screen.
  var isGlasses: Bool
}

struct CaptureHostState: Equatable {
  var glasses: [CaptureDisplay]
  /// Non-zero while IINA's picture window is pinned on that display.
  var pinnedDisplayID: UInt32

  static let empty = CaptureHostState(glasses: [], pinnedDisplayID: 0)
}

struct CapturePlacementRequest: Equatable {
  var kind: CaptureTrack.Kind
  var windowID: UInt32
  var title: String
  var owner: String
  var bundleID: String
  var windows: [CaptureWindowRecord]
  var displays: [CaptureDisplay]
  /// Display the stream is aimed at. For a window, the display that window covers. 0 if unknown.
  var capturingDisplayID: UInt32
  var pinnedDisplayID: UInt32
}

enum CapturePlacementNext: Equatable {
  /// The filter is already aimed at the right surface.
  case unchanged
  case window(CaptureWindowRecord)
  case display(UInt32)

  var stableKey: String {
    switch self {
    case .unchanged: return "same"
    case .window(let window): return "w\(window.id)"
    case .display(let id): return "d\(id)"
    }
  }
}

enum CapturePlacementDecision: Equatable {
  case keep
  /// The live picture is on another display, and that display is not the glasses output.
  case retarget(CapturePlacementNext, reason: String)
  /// The live picture is on the glasses, or IINA is pinned on the display it is capturing.
  /// Move the picture off that display before showing it there. `next` is what to capture
  /// once IINA's own window is out of the way, so the stream cannot see itself.
  case moveOutput(message: String, next: CapturePlacementNext, reason: String)

  var isKeep: Bool {
    if case .keep = self { return true }
    return false
  }

  var stableKey: String {
    switch self {
    case .keep:
      return "keep"
    case .retarget(let next, _):
      return "retarget-\(next.stableKey)"
    case .moveOutput(_, let next, _):
      return "move-\(next.stableKey)"
    }
  }

  var next: CapturePlacementNext? {
    switch self {
    case .keep:
      return nil
    case .retarget(let next, _):
      return next
    case .moveOutput(_, let next, _):
      return next
    }
  }
}

enum CapturePlacement {
  /// Full-screen coverage. A notch or menu bar can shorten the window, so the height test is looser than the width test.
  static func covers(_ window: CaptureWindowRecord, _ display: CaptureDisplay) -> Bool {
    guard window.displayID == display.id, display.frame.width > 1, display.frame.height > 1 else { return false }
    let widthRatio = CGFloat(max(window.width, 0)) / display.frame.width
    let heightRatio = CGFloat(max(window.height, 0)) / display.frame.height
    return widthRatio >= 0.80 && heightRatio >= 0.75
  }

  static func message(app: String, displayName: String) -> String {
    let who = app.isEmpty ? "The full screen window" : app
    let screen = displayName.isEmpty ? "the glasses" : displayName
    return "\(who) is full screen on \(screen). That is the screen IINA uses for the 3D picture, so IINA is showing the preview on the Mac instead of covering the game. Press and hold Esc to leave full screen, move the window onto the Mac display, then choose Send Capture to Glasses."
  }

  static func sameDisplayMessage(displayName: String) -> String {
    let screen = displayName.isEmpty ? "the glasses" : displayName
    return "IINA's picture was on \(screen), which is the display being captured. That films IINA's own output, so the preview moved back to the Mac. Send Capture to Glasses only after the game window is on the Mac display."
  }

  static func decide(_ request: CapturePlacementRequest) -> CapturePlacementDecision {
    if request.kind == .display {
      return decideDisplay(request)
    }
    return decideWindow(request)
  }

  /// SCDisplay frames merged with the glasses screens the app already knows.
  static func merging(_ displays: [(id: UInt32, frame: CGRect)], host: CaptureHostState) -> [CaptureDisplay] {
    var merged = displays.map { item in
      let known = host.glasses.first { $0.id == item.id }
      return CaptureDisplay(
        id: item.id,
        frame: item.frame,
        name: known?.name ?? "Display \(item.id)",
        isGlasses: known != nil
      )
    }
    for glasses in host.glasses where !merged.contains(where: { $0.id == glasses.id }) {
      merged.append(glasses)
    }
    return merged
  }

  private static func decideWindow(_ request: CapturePlacementRequest) -> CapturePlacementDecision {
    guard let tracked = request.windows.first(where: { $0.id == request.windowID }) else {
      return .keep
    }
    if let moved = otherDisplayFullscreen(of: request, tracked: tracked) {
      return moved
    }
    if let display = outputDisplay(coveredBy: tracked, request: request) {
      let app = appName(tracked.owner, bundle: tracked.bundleID, fallback: request.owner)
      return .moveOutput(
        message: message(app: app, displayName: display.name),
        next: .unchanged,
        reason: "window \(tracked.id) covers \(display.name) (\(display.id)); the glasses picture cannot stay there"
      )
    }
    return .keep
  }

  private static func decideDisplay(_ request: CapturePlacementRequest) -> CapturePlacementDecision {
    if let glasses = glassesFullscreen(request) {
      let display = glasses.display
      let app = appName(glasses.window.owner, bundle: glasses.window.bundleID, fallback: "")
      if request.capturingDisplayID != display.id {
        return .moveOutput(
          message: message(app: app, displayName: display.name),
          next: .display(display.id),
          reason: "full screen \(app) is on \(display.name) (\(display.id)); capture was aimed at display \(request.capturingDisplayID)"
        )
      }
      return .moveOutput(
        message: message(app: app, displayName: display.name),
        next: .unchanged,
        reason: "full screen \(app) covers \(display.name) (\(display.id)); leaving IINA's picture on the Mac"
      )
    }
    if request.pinnedDisplayID != 0, request.capturingDisplayID == request.pinnedDisplayID {
      let name = request.displays.first { $0.id == request.pinnedDisplayID }?.name ?? ""
      return .moveOutput(
        message: sameDisplayMessage(displayName: name),
        next: .unchanged,
        reason: "capture and IINA's picture are both on display \(request.pinnedDisplayID)"
      )
    }
    return .keep
  }

  /// A same-app full-screen window on a different display from the one being followed.
  /// An untitled placeholder on the same display is ignored: that is Chrome's full-screen shadow, and switching to it flips the filter.
  /// The glasses display wins over the built-in display, because that is where IINA would also put its picture.
  /// A full-screen window that is already on-screen on its own display stays put when the other display is not the glasses.
  private static func otherDisplayFullscreen(of request: CapturePlacementRequest, tracked: CaptureWindowRecord) -> CapturePlacementDecision? {
    let others = request.displays.filter { $0.id != tracked.displayID && $0.id != 0 }
    var found: (CaptureDisplay, CaptureWindowRecord)?
    for display in others {
      let covering = request.windows.filter {
        $0.id != tracked.id && sameApp($0, request) && covers($0, display) && visible($0, on: display, pinnedID: request.pinnedDisplayID)
      }
      guard let best = preferred(covering) else { continue }
      found = better(best, on: display, than: found)
    }
    guard let (display, window) = found else { return nil }
    let trackedDisplay = request.displays.first { $0.id == tracked.displayID }
    let trackedIsLiveFullscreen = tracked.onScreen && trackedDisplay.map { covers(tracked, $0) } == true
    if trackedIsLiveFullscreen && !display.isGlasses && display.id != request.pinnedDisplayID {
      return nil
    }
    let next: CapturePlacementNext
    let how: String
    if CaptureWindowMatch.isPlaceholder(window) {
      next = .display(display.id)
      how = "untitled full screen window \(window.id) on \(display.name); capturing that display"
    } else {
      next = .window(window)
      how = "window \(window.id) on \(display.name)"
    }
    let reason = "window \(tracked.id) is on display \(tracked.displayID); full screen is \(how)"
    if display.isGlasses || display.id == request.pinnedDisplayID {
      let app = appName(window.owner, bundle: window.bundleID, fallback: request.owner)
      return .moveOutput(message: message(app: app, displayName: display.name), next: next, reason: reason)
    }
    return .retarget(next, reason: reason)
  }

  private static func better(_ window: CaptureWindowRecord, on display: CaptureDisplay, than current: (CaptureDisplay, CaptureWindowRecord)?) -> (CaptureDisplay, CaptureWindowRecord) {
    guard let current else { return (display, window) }
    let currentPlaceholder = CaptureWindowMatch.isPlaceholder(current.1)
    let nextPlaceholder = CaptureWindowMatch.isPlaceholder(window)
    if currentPlaceholder && !nextPlaceholder { return (display, window) }
    if !currentPlaceholder && nextPlaceholder { return current }
    if !current.0.isGlasses && display.isGlasses { return (display, window) }
    return current
  }

  private static func glassesFullscreen(_ request: CapturePlacementRequest) -> (display: CaptureDisplay, window: CaptureWindowRecord)? {
    for display in request.displays where display.isGlasses {
      let covering = request.windows.filter { covers($0, display) && visible($0, on: display, pinnedID: request.pinnedDisplayID) }
      if let best = preferred(covering) {
        return (display, best)
      }
    }
    return nil
  }

  private static func outputDisplay(coveredBy window: CaptureWindowRecord, request: CapturePlacementRequest) -> CaptureDisplay? {
    request.displays.first { display in
      (display.isGlasses || display.id == request.pinnedDisplayID) && covers(window, display)
    }
  }

  /// Full-screen Chrome on another Space often reports `isOnScreen == false` even while that Space is showing.
  /// A window that covers the glasses still counts. Anywhere else, it has to be on screen so an idle window cannot steal the capture.
  private static func visible(_ window: CaptureWindowRecord, on display: CaptureDisplay, pinnedID: UInt32) -> Bool {
    if window.onScreen { return true }
    return display.isGlasses || display.id == pinnedID
  }

  /// A titled window beats an untitled full-screen placeholder. On-screen beats off-screen.
  private static func preferred(_ windows: [CaptureWindowRecord]) -> CaptureWindowRecord? {
    windows.max { lhs, rhs in
      let lhsPlaceholder = CaptureWindowMatch.isPlaceholder(lhs)
      let rhsPlaceholder = CaptureWindowMatch.isPlaceholder(rhs)
      if lhsPlaceholder != rhsPlaceholder { return lhsPlaceholder }
      if lhs.onScreen != rhs.onScreen { return rhs.onScreen }
      if lhs.area != rhs.area { return lhs.area < rhs.area }
      return lhs.id > rhs.id
    }
  }

  private static func sameApp(_ window: CaptureWindowRecord, _ request: CapturePlacementRequest) -> Bool {
    if !request.bundleID.isEmpty, window.bundleID == request.bundleID { return true }
    if !request.owner.isEmpty, window.owner.caseInsensitiveCompare(request.owner) == .orderedSame { return true }
    return false
  }

  private static func appName(_ owner: String, bundle: String, fallback: String) -> String {
    if !owner.isEmpty { return owner }
    if !fallback.isEmpty { return fallback }
    if !bundle.isEmpty { return bundle }
    return ""
  }
}
