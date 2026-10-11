//
//  BrowserCaptureRenderer.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  CVPixelBuffer -> CVMetalTextureCache -> depth sample -> shared submitFrame.

import Cocoa
import CoreVideo
import Metal

@available(macOS 12.3, *)
final class BrowserCaptureRenderer: NSView {
  var onBlack: ((Bool) -> Void)?

  private var metalDevice: MTLDevice?
  private var commandQueue: MTLCommandQueue?
  private var textureCache: CVMetalTextureCache?
  private var scalePipeline: MTLComputePipelineState?
  private var scaled: MTLTexture?
  private var scaledWidth = 0
  private var scaledHeight = 0
  private var outputTexture: MTLTexture?
  private var outputWidth = 0
  private var outputHeight = 0
  private var held: CVPixelBuffer?
  private var fullSizeEyes = false
  private var blackFrames = 0
  private var showingBlack = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    let device = MTLCreateSystemDefaultDevice()
    metalDevice = device
    commandQueue = device?.makeCommandQueue()
    if let device {
      var cache: CVMetalTextureCache?
      CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
      textureCache = cache
      if let library = device.makeDefaultLibrary(), let function = library.makeFunction(name: "immersiveScaleRGBA") {
        scalePipeline = try? device.makeComputePipelineState(function: function)
      }
    }
    if let layer = self.layer as? CAMetalLayer {
      layer.device = device
      layer.pixelFormat = .bgra8Unorm
      layer.framebufferOnly = false
      layer.isOpaque = true
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func makeBackingLayer() -> CALayer {
    let layer = CAMetalLayer()
    layer.device = MTLCreateSystemDefaultDevice()
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.isOpaque = true
    return layer
  }

  func setPixelSize(width: Int, height: Int, scale: CGFloat) {
    guard let layer = self.layer as? CAMetalLayer else { return }
    layer.contentsScale = scale
    layer.drawableSize = CGSize(width: max(width, 2), height: max(height, 2))
  }

  func setFullSizeEyes(_ enabled: Bool) {
    fullSizeEyes = enabled
  }

  /// Called on the capture queue.
  func consume(_ pixelBuffer: CVPixelBuffer) {
    held = pixelBuffer
    draw(pixelBuffer)
  }

  func redrawHeld() {
    guard let held else { return }
    draw(held)
  }

  private func draw(_ pixelBuffer: CVPixelBuffer) {
    guard let device = metalDevice,
          let commandQueue,
          let cache = textureCache,
          let layer = self.layer as? CAMetalLayer else { return }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 1, height > 1 else { return }
    var cvTexture: CVMetalTexture?
    let result = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault,
      cache,
      pixelBuffer,
      nil,
      .bgra8Unorm,
      width,
      height,
      0,
      &cvTexture
    )
    guard result == kCVReturnSuccess, let cvTexture, let color = CVMetalTextureGetTexture(cvTexture) else { return }
    let sample = scaleToDepth(color, device: device, queue: commandQueue)
    if let sample {
      noteLuma(Self.meanLuma(sample))
    }
    let pixelWidth = max(Int(layer.drawableSize.width), 2)
    let pixelHeight = max(Int(layer.drawableSize.height), 2)
    guard let drawable = layer.nextDrawable(),
          let target = outputTarget(device: device, width: pixelWidth, height: pixelHeight) else {
      CVMetalTextureCacheFlush(cache, 0)
      return
    }
    let model = DepthEstimator.shared.inputSize()
    let wrote = Immersive3DController.shared.submitFrame(
      color: color,
      output: target,
      contentAspect: Float(width) / Float(height),
      colorIsBottomUp: false,
      depthRGBA: sample,
      modelWidth: model?.width ?? 0,
      modelHeight: model?.height ?? 0,
      fullSizeEyes: fullSizeEyes,
      compositor: nil
    ) { [weak self] in
      BrowserCaptureManager.shared.perform {
        self?.redrawHeld()
      }
    }
    CVMetalTextureCacheFlush(cache, 0)
    guard wrote,
          drawable.texture.width == pixelWidth,
          drawable.texture.height == pixelHeight,
          let present = commandQueue.makeCommandBuffer(),
          let blit = present.makeBlitCommandEncoder() else { return }
    blit.copy(
      from: target,
      sourceSlice: 0,
      sourceLevel: 0,
      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
      sourceSize: MTLSize(width: pixelWidth, height: pixelHeight, depth: 1),
      to: drawable.texture,
      destinationSlice: 0,
      destinationLevel: 0,
      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
    )
    blit.endEncoding()
    present.present(drawable)
    present.commit()
  }

  private func outputTarget(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
    if let outputTexture, outputWidth == width, outputHeight == height { return outputTexture }
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    desc.usage = [.shaderWrite, .shaderRead]
    desc.storageMode = .private
    guard let texture = device.makeTexture(descriptor: desc) else { return nil }
    outputTexture = texture
    outputWidth = width
    outputHeight = height
    return texture
  }

  private func scaleToDepth(_ color: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) -> [UInt8]? {
    guard let size = DepthEstimator.shared.inputSize() else {
      DepthEstimator.shared.ensureLoaded()
      return nil
    }
    guard let pipeline = scalePipeline,
          let texture = scaledTexture(device: device, width: size.width, height: size.height),
          let commandBuffer = queue.makeCommandBuffer(),
          let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
    var oriented: Float = 0
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(color, index: 0)
    encoder.setTexture(texture, index: 1)
    encoder.setBytes(&oriented, length: MemoryLayout<Float>.size, index: 0)
    encoder.dispatchThreads(MTLSize(width: size.width, height: size.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.error == nil else { return nil }
    var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
    bytes.withUnsafeMutableBytes { raw in
      guard let base = raw.baseAddress else { return }
      texture.getBytes(base, bytesPerRow: size.width * 4, from: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0)
    }
    return bytes
  }

  private func scaledTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
    if let scaled, scaledWidth == width, scaledHeight == height { return scaled }
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    desc.usage = [.shaderWrite]
    desc.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: desc) else { return nil }
    scaled = texture
    scaledWidth = width
    scaledHeight = height
    return texture
  }

  private func noteLuma(_ luma: Float) {
    if luma < 3 {
      blackFrames += 1
      if blackFrames == 60 && !showingBlack {
        showingBlack = true
        DispatchQueue.main.async { [weak self] in
          self?.onBlack?(true)
        }
      }
    } else if luma > 8 {
      blackFrames = 0
      if showingBlack {
        showingBlack = false
        DispatchQueue.main.async { [weak self] in
          self?.onBlack?(false)
        }
      }
    }
  }

  private static func meanLuma(_ pixels: [UInt8]) -> Float {
    let count = pixels.count / 4
    guard count > 0 else { return 255 }
    let step = max(count / 2048, 1)
    var accum: Float = 0
    var samples = 0
    var index = 0
    while index < count {
      let offset = index * 4
      accum += 0.2126 * Float(pixels[offset]) + 0.7152 * Float(pixels[offset + 1]) + 0.0722 * Float(pixels[offset + 2])
      samples += 1
      index += step
    }
    return accum / Float(max(samples, 1))
  }
}
