//
//  StereoOffscreen.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  The side-by-side compute pass shared by the player framebuffer and Browser
//  Capture. A capture texture is the picture itself. A player texture is the
//  glasses framebuffer, which may already pillarbox that picture.

import Foundation
import Metal

enum StereoOffscreen {
  struct Params {
    var maxShift: Float
    var convergence: Float
    var holeThreshold: Float
    var invertDepth: Float
    var glOriented: Float
    var searchPixels: Float
    var contentX: Float
    var contentY: Float
    var contentW: Float
    var contentH: Float
  }

  struct Rect: Equatable {
    var x: Float
    var y: Float
    var w: Float
    var h: Float
  }

  static let fullPicture = Rect(x: 0, y: 0, w: 1, h: 1)

  struct EncodeResult: Equatable {
    var ok: Bool
    var reason: String

    static let sent = EncodeResult(ok: true, reason: "")

    static func failed(_ reason: String) -> EncodeResult {
      EncodeResult(ok: false, reason: reason)
    }
  }

  /// 16×16 is 256 threads. A pipeline whose limit is smaller rejects the dispatch,
  /// and that fault makes later command buffers fail as well. The size stays inside the limit.
  static func threadgroupSize(maxThreads: Int, width: Int, height: Int) -> MTLSize {
    let limit = max(maxThreads, 1)
    var threadsWide = min(16, max(width, 1))
    var threadsHigh = min(16, max(height, 1))
    while threadsWide * threadsHigh > limit && threadsHigh > 1 {
      threadsHigh /= 2
    }
    while threadsWide * threadsHigh > limit && threadsWide > 1 {
      threadsWide /= 2
    }
    return MTLSize(width: max(threadsWide, 1), height: max(threadsHigh, 1), depth: 1)
  }

  /// Where the picture sits inside the color texture, top-down and normalized.
  /// `colorIsPicture` means the texture is the captured window, so each eye samples all of it.
  /// Otherwise a 3840×1080 framebuffer pillarboxes a narrower picture and each eye samples that band.
  static func contentRect(outputWidth: Int, outputHeight: Int, contentAspect: Float, fullSizeEyes: Bool, colorIsPicture: Bool) -> Rect {
    if colorIsPicture || !fullSizeEyes || outputWidth <= 1 || outputHeight <= 1 {
      return fullPicture
    }
    let frameAspect = Float(outputWidth) / Float(outputHeight)
    let videoAspect: Float = contentAspect > 0.01 ? contentAspect : (16.0 / 9.0)
    if videoAspect >= frameAspect {
      let contentH = min(max(frameAspect / videoAspect, 0.01), 1)
      return Rect(x: 0, y: (1 - contentH) * 0.5, w: 1, h: contentH)
    }
    let contentW = min(max(videoAspect / frameAspect, 0.01), 1)
    return Rect(x: (1 - contentW) * 0.5, y: 0, w: contentW, h: 1)
  }

  /// `completion` is the capture path. The command buffer is committed and the
  /// caller is not blocked. The player path passes nil and waits, because it
  /// reads the texture immediately afterwards.
  static func encode(
    commandQueue: MTLCommandQueue,
    pipeline: MTLComputePipelineState,
    color: MTLTexture,
    depth: MTLTexture,
    output: MTLTexture,
    params: Params,
    completion: ((Bool) -> Void)? = nil
  ) -> EncodeResult {
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      return .failed("command buffer was not created")
    }
    guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
      return .failed("compute encoder was not created")
    }
    var params = params
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(color, index: 0)
    encoder.setTexture(depth, index: 1)
    encoder.setTexture(output, index: 2)
    encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
    let group = threadgroupSize(maxThreads: pipeline.maxTotalThreadsPerThreadgroup, width: output.width, height: output.height)
    encoder.dispatchThreads(
      MTLSize(width: output.width, height: output.height, depth: 1),
      threadsPerThreadgroup: group
    )
    encoder.endEncoding()
    if let completion {
      commandBuffer.addCompletedHandler { buffer in
        completion(buffer.error == nil)
      }
      commandBuffer.commit()
      return .sent
    }
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    if let error = commandBuffer.error {
      return .failed(error.localizedDescription)
    }
    return .sent
  }

  /// Scales a BGRA picture onto a drawable of a different size. Same kernel the
  /// preview uses when the glasses drawable is not the texture size.
  static func scale(
    commandQueue: MTLCommandQueue,
    pipeline: MTLComputePipelineState,
    source: MTLTexture,
    destination: MTLTexture
  ) -> Bool {
    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
    var oriented: Float = 0
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(source, index: 0)
    encoder.setTexture(destination, index: 1)
    encoder.setBytes(&oriented, length: MemoryLayout<Float>.stride, index: 0)
    let width = destination.width
    let height = destination.height
    let group = threadgroupSize(maxThreads: pipeline.maxTotalThreadsPerThreadgroup, width: width, height: height)
    encoder.dispatchThreads(
      MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: group
    )
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    return commandBuffer.error == nil
  }
}
