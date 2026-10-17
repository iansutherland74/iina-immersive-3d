//
//  GlassesSession.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  One glasses output. The picture is either the player or Browser Capture.
//  Play on Glasses, capture start, and capture stop all go through this.

import Foundation

enum PictureSource: Equatable {
  case player
  case capture
}

struct GlassesDisplayChoice: Equatable {
  var id: UInt32
  var pixelWidth: Int
  var pixelHeight: Int
  var fullSizeEyes: Bool
  var name: String
}

enum GlassesOutput: Equatable {
  case off
  case showing(PictureSource, GlassesDisplayChoice)
}

enum GlassesEffect: Equatable {
  case pinPlayer(GlassesDisplayChoice)
  case unpinPlayer
  case pinCapture(GlassesDisplayChoice)
  case unpinCapture
  case noDisplay
}

enum GlassesEvent: Equatable {
  /// Menu, button, and shortcut. `displays` is preference order; the first is used.
  case play(displays: [GlassesDisplayChoice], captureRunning: Bool)
  case playOn(GlassesDisplayChoice, captureRunning: Bool)
  case exit
  case captureStarted(displays: [GlassesDisplayChoice])
  case captureStopped
}

struct GlassesSession: Equatable {
  var output: GlassesOutput = .off
  var captureRunning = false
  /// The player was on the glasses when capture took that output.
  var restorePlayer = false

  var isOn: Bool {
    if case .off = output { return false }
    return true
  }

  var source: PictureSource? {
    if case .showing(let source, _) = output { return source }
    return nil
  }

  struct Transition: Equatable {
    var session: GlassesSession
    var effects: [GlassesEffect]
  }

  func transition(_ event: GlassesEvent) -> Transition {
    switch event {
    case .play(let displays, let captureRunning):
      if isOn { return exitTransition(captureRunning: captureRunning) }
      return show(displays: displays, captureRunning: captureRunning)
    case .playOn(let display, let captureRunning):
      if isOn { return exitTransition(captureRunning: captureRunning) }
      return show(displays: [display], captureRunning: captureRunning)
    case .exit:
      return exitTransition(captureRunning: captureRunning)
    case .captureStarted(let displays):
      return captureDidStart(displays)
    case .captureStopped:
      return captureDidStop()
    }
  }

  private func show(displays: [GlassesDisplayChoice], captureRunning: Bool) -> Transition {
    var next = self
    next.captureRunning = captureRunning
    guard let display = displays.first else {
      return Transition(session: next, effects: [.noDisplay])
    }
    if captureRunning {
      next.output = .showing(.capture, display)
      return Transition(session: next, effects: [.pinCapture(display)])
    }
    next.output = .showing(.player, display)
    return Transition(session: next, effects: [.pinPlayer(display)])
  }

  private func exitTransition(captureRunning: Bool) -> Transition {
    var next = self
    next.captureRunning = captureRunning
    next.restorePlayer = false
    switch output {
    case .off:
      return Transition(session: next, effects: [])
    case .showing(.player, _):
      next.output = .off
      return Transition(session: next, effects: [.unpinPlayer])
    case .showing(.capture, _):
      next.output = .off
      return Transition(session: next, effects: [.unpinCapture])
    }
  }

  private func captureDidStart(_ displays: [GlassesDisplayChoice]) -> Transition {
    var next = self
    next.captureRunning = true
    guard let display = displays.first else {
      return Transition(session: next, effects: [])
    }
    switch output {
    case .off:
      next.output = .showing(.capture, display)
      return Transition(session: next, effects: [.pinCapture(display)])
    case .showing(.capture, let current):
      next.output = .showing(.capture, display)
      if current != display {
        return Transition(session: next, effects: [.pinCapture(display)])
      }
      return Transition(session: next, effects: [])
    case .showing(.player, _):
      next.restorePlayer = true
      next.output = .showing(.capture, display)
      return Transition(session: next, effects: [.pinCapture(display), .unpinPlayer])
    }
  }

  private func captureDidStop() -> Transition {
    var next = self
    next.captureRunning = false
    guard case .showing(.capture, let display) = output else {
      return Transition(session: next, effects: [])
    }
    if restorePlayer {
      next.restorePlayer = false
      next.output = .showing(.player, display)
      return Transition(session: next, effects: [.unpinCapture, .pinPlayer(display)])
    }
    next.output = .off
    return Transition(session: next, effects: [.unpinCapture])
  }

  /// A 2D/3D mode switch changes the glasses pixel size. The window pin is separate.
  /// It does not change the system output or the mpv device.
  mutating func noteScreen(_ display: GlassesDisplayChoice) {
    guard case .showing(let source, _) = output else { return }
    output = .showing(source, display)
  }
}
