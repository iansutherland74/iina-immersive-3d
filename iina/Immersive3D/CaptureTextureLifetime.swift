//
//  CaptureTextureLifetime.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  CVMetalTextureCacheCreateTextureFromImage returns +1. CVMetalTextureGetTexture
//  does not. The cache flush releases every texture it still owns, so flushing
//  while the holder is alive frees the texture the holder releases next.

import CoreVideo
import Metal

enum CaptureTextureLifetime {
  static func make(
    cache: CVMetalTextureCache,
    pixelBuffer: CVPixelBuffer,
    width: Int,
    height: Int
  ) -> (holder: CVMetalTexture, texture: MTLTexture)? {
    guard width > 1, height > 1 else { return nil }
    var holder: CVMetalTexture?
    let result = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault,
      cache,
      pixelBuffer,
      nil,
      .bgra8Unorm,
      width,
      height,
      0,
      &holder
    )
    guard result == kCVReturnSuccess, let holder, let texture = CVMetalTextureGetTexture(holder) else {
      return nil
    }
    return (holder, texture)
  }

  static func recycle(
    holder: inout CVMetalTexture?,
    texture: inout MTLTexture?,
    cache: CVMetalTextureCache,
    flush: Bool
  ) {
    texture = nil
    holder = nil
    if flush {
      CVMetalTextureCacheFlush(cache, 0)
    }
  }
}
