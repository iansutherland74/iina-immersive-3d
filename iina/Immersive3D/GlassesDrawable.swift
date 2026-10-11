//
//  GlassesDrawable.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Pixel size of the capture preview and of the glasses drawable.
//  A zero view used to become 2×2. Sizes below the minimum are refused.

import CoreGraphics
import Foundation

enum GlassesDrawable {
  static let previewPointWidth = 960.0
  static let previewPointHeight = 540.0
  static let minimumPixels = 32

  /// Points × backing scale, rounded to pixels. Nil when the result is not a real drawable.
  static func pixels(pointsWidth: Double, pointsHeight: Double, scale: Double) -> (width: Int, height: Int)? {
    guard pointsWidth.isFinite, pointsHeight.isFinite, scale.isFinite, scale > 0 else { return nil }
    let width = Int((pointsWidth * scale).rounded())
    let height = Int((pointsHeight * scale).rounded())
    guard width >= minimumPixels, height >= minimumPixels else { return nil }
    return (width, height)
  }

  static func previewPixels(scale: Double) -> (width: Int, height: Int) {
    let safe = scale.isFinite && scale > 0 ? scale : 1
    return pixels(pointsWidth: previewPointWidth, pointsHeight: previewPointHeight, scale: safe)
      ?? (width: Int(previewPointWidth), height: Int(previewPointHeight))
  }

  /// While the capture window is on the glasses, a Space change reports the Mac's
  /// screen (1512×982 at 2x is 3024×1964) or a half-moved frame (3840×1027).
  /// Those sizes are not the drawable. The glasses pixel size wins.
  static func lockedPixels(lockedWidth: Int, lockedHeight: Int, interimWidth: Int, interimHeight: Int) -> (width: Int, height: Int) {
    if lockedWidth >= minimumPixels, lockedHeight >= minimumPixels {
      return (lockedWidth, lockedHeight)
    }
    return (interimWidth, interimHeight)
  }

  enum PresentFit: Equatable {
    case blit
    case scale
    case drop
  }

  /// A texture from the previous size is scaled onto the drawable. Skipping it
  /// left the glasses on the last frame that happened to match.
  static func presentFit(textureWidth: Int, textureHeight: Int, drawableWidth: Int, drawableHeight: Int) -> PresentFit {
    guard textureWidth >= minimumPixels, textureHeight >= minimumPixels,
          drawableWidth >= minimumPixels, drawableHeight >= minimumPixels else { return .drop }
    if textureWidth == drawableWidth && textureHeight == drawableHeight { return .blit }
    return .scale
  }
}
