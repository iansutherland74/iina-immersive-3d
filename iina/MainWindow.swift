//
//  MainWindow.swift
//  iina
//
//  Created by Collider LI on 10/1/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa

class MainWindow: CommonWindow {
  var forceKeyAndMain = false

  override func keyDown(with event: NSEvent) {
    if menu?.performKeyEquivalent(with: event) == true {
      return
    }
    /// Forward all key events which the window receives to its controller.
    /// This allows `ESC` & `TAB` key bindings to work, instead of getting swallowed by
    /// MacOS keyboard focus navigation (which we don't use).
    if let controller = windowController as? MainWindowController {
      controller.keyDown(with: event)
    } else {
      super.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    /// AppKit by default will prioritize menu item key equivalents over arrow key navigation
    /// (although for some reason it is the opposite for `ESC`, `TAB`, `ENTER` or `RETURN`).
    /// Need to add an explicit check here for arrow keys to ensure that they always work when desired.
    if let responder = firstResponder, shouldFavorArrowKeyNavigation(for: responder) {

      let keyCode = KeyCodeHelper.mpvKeyCode(from: event)
      let normalizedKeyCode = KeyCodeHelper.normalizeMpv(keyCode)

      switch normalizedKeyCode {
      case "UP", "DOWN", "LEFT", "RIGHT":
        // Send arrow keys to view to enable key navigation
        responder.keyDown(with: event)
        return true
      default:
        break
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  private func shouldFavorArrowKeyNavigation(for responder: NSResponder) -> Bool {
    return responder as? NSTextView != nil
  }

  override var canBecomeKey: Bool {
    forceKeyAndMain ? true : super.canBecomeKey
  }
  
  override var canBecomeMain: Bool {
    forceKeyAndMain ? true : super.canBecomeMain
  }

  /// Play on Glasses must use `NSScreen.frame` in global desktop coordinates, including a
  /// non-zero origin (the measured SmartGlasses 3D frame is (1512, -98, 3840, 1080)) and the
  /// menu-bar / camera-housing area. The default implementation pulls the window into `visibleFrame`.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    // AppKit's fullscreen-exit transition calls setFrame while quitting. A NaN, infinite,
    // or empty rect raises in `_reallySetFrame`. Never return one, and don't pass one to super.
    if Immersive3DController.shared.glassesActive, Immersive3DController.isUsableWindowFrame(frameRect) {
      return frameRect
    }
    if Immersive3DController.isUsableWindowFrame(frameRect) {
      let constrained = super.constrainFrameRect(frameRect, to: screen)
      if Immersive3DController.isUsableWindowFrame(constrained) {
        return constrained
      }
    }
    if Immersive3DController.isUsableWindowFrame(frame) {
      return frame
    }
    return Immersive3DController.fallbackWindowFrame()
  }
}

class MainWindowContentView: NSView {
  override func resetCursorRects() {
    guard let controller = window?.windowController as? MainWindowController else { return }
    for side in [SidebarController.Side.leading, .trailing] where controller.sidebars.sideBar(for: side).status != .hidden {
      addCursorRect(controller.sidebars.resizeHandleRect(for: side), cursor: .resizeLeftRight)
    }
  }

  /// Invoked automatically when the view’s geometry changes such that its tracking areas need to be recalculated.
  ///
  /// Previous to macOS Sequoia this method was not needed, AppKit properly handled the re-computation of the tracking area
  /// when the view geometry changed. But as of macOS 15 something is going wrong in AppKit and it fails to call `mouseMoved`
  /// after legacy full screen mode is entered or exited. See issues [#5535](https://github.com/iina/iina/issues/5535)
  /// and [#5288](https://github.com/iina/iina/issues/5288).
  /// - Note: This method intentionally does not check for the availability of macOS 15 as this method works fine with older versions
  ///     of macOS as well. This protects against Apple back porting the bad Sequoia behavior into older versions of macOS which
  ///     has occurred with past macOS problems.
  override func updateTrackingAreas() {
    defer { super.updateTrackingAreas() }
    guard trackingAreas.count == 1,
          let controller = window?.windowController as? MainWindowController else { return }
    controller.log("Recreating tracking area", level: .verbose)
    removeTrackingArea(trackingAreas[0])
    addTrackingArea(NSTrackingArea(rect: bounds,
      options: [.activeAlways, .enabledDuringMouseDrag, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
      owner: controller, userInfo: ["obj": 0]))
  }
}
