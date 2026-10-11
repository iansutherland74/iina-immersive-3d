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
}
