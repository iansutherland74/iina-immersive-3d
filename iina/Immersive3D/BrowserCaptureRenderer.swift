//
//  BrowserCaptureRenderer.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  CVPixelBuffer -> crop -> CVMetalTextureCache -> depth sample -> shared submitFrame.

import Cocoa
import CoreMedia
import CoreVideo
import Metal

@available(macOS 12.3, *)
final class BrowserCaptureRenderer: NSView {
  var onBlack: ((Bool) -> Void)?

  private var metalDevice: MTLDevice?
  private var commandQueue: MTLCommandQueue?
  private var textureCache: CVMetalTextureCache?
  private var scalePipeline: MTLComputePipelineState?
  private var cropPipeline: MTLComputePipelineState?
  private var scaled: MTLTexture?
  private var scaledWidth = 0
  private var scaledHeight = 0
  private var cropped: MTLTexture?
  private var croppedWidth = 0
  private var croppedHeight = 0
  private var stageTextures: [MTLTexture?] = [nil, nil]
  private var stageBusy: [Bool] = [false, false]
  private let stageLock = NSLock()
  private var pixelWidth = 2
  private var pixelHeight = 2
  private var held: CVPixelBuffer?
  private var heldTime = CMTime.invalid
  private var fullSizeEyes = false
  private var blackFrames = 0
  private var showingBlack = false
  private var frameIndex = 0
  private var loggedTexture = false
  private var loggedSend = false
  private var loggedSendFailure = false

  private struct CropUniform {
    var x: Float
    var y: Float
    var w: Float
    var h: Float
  }

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
      if let library = device.makeDefaultLibrary() {
        if let function = library.makeFunction(name: "immersiveScaleRGBA") {
          scalePipeline = try? device.makeComputePipelineState(function: function)
        }
        if let function = library.makeFunction(name: "immersiveCropBGRA") {
          cropPipeline = try? device.makeComputePipelineState(function: function)
        }
      }
    }
    if let layer = self.layer as? CAMetalLayer {
      layer.device = device
      layer.pixelFormat = .bgra8Unorm
      layer.framebufferOnly = false
      layer.isOpaque = true
      layer.allowsNextDrawableTimeout = true
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
    layer.allowsNextDrawableTimeout = true
    return layer
  }

  func setPixelSize(width: Int, height: Int, scale: CGFloat) {
    let pixels = (max(width, 2), max(height, 2))
    stageLock.lock()
    pixelWidth = pixels.0
    pixelHeight = pixels.1
    stageLock.unlock()
    let apply = {
      guard let layer = self.layer as? CAMetalLayer else { return }
      layer.contentsScale = scale
      layer.drawableSize = CGSize(width: pixels.0, height: pixels.1)
    }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async(execute: apply)
    }
  }

  func setFullSizeEyes(_ enabled: Bool) {
    fullSizeEyes = enabled
  }

  func requestCropAnalysis() {
    BrowserCaptureSettings.shared.requestAnalysis()
  }

  /// Called on the capture queue. A call from the main thread is moved there so the GPU waits never block the run loop.
  func consume(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
    if Thread.isMainThread {
      BrowserCaptureManager.shared.perform { [weak self] in
        self?.consume(pixelBuffer, at: time)
      }
      return
    }
    held = pixelBuffer
    heldTime = time
    draw(pixelBuffer, at: time)
  }

  func redrawHeld() {
    if Thread.isMainThread {
      BrowserCaptureManager.shared.perform { [weak self] in
        self?.redrawHeld()
      }
      return
    }
    guard let held else { return }
    draw(held, at: heldTime)
  }

  private func draw(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
    guard let device = metalDevice,
          let commandQueue,
          let cache = textureCache else { return }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 1, height > 1 else { return }
    analyzeIfNeeded(pixelBuffer)
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
    guard result == kCVReturnSuccess, let cvTexture, let color = CVMetalTextureGetTexture(cvTexture) else {
      browserCaptureLog.error("texture conversion failed \(result)")
      CVMetalTextureCacheFlush(cache, 0)
      return
    }
    if !loggedTexture {
      loggedTexture = true
      browserCaptureLog.info("texture conversion \(width)x\(height)")
    }
    let framed = croppedFrame(from: color, device: device) ?? color
    let sample = scaleToDepth(framed, device: device, queue: commandQueue)
    if let sample {
      noteLuma(Self.meanLuma(sample))
    }
    stageLock.lock()
    let viewWidth = pixelWidth
    let viewHeight = pixelHeight
    stageLock.unlock()
    guard let stage = acquireStage(device: device, width: viewWidth, height: viewHeight) else {
      if !loggedSendFailure {
        loggedSendFailure = true
        browserCaptureLog.error("glasses send skipped; previous frame is still on the GPU")
      }
      CVMetalTextureCacheFlush(cache, 0)
      return
    }
    let model = DepthEstimator.shared.inputSize()
    let aspect = Float(framed.width) / Float(max(framed.height, 1))
    let wrote = Immersive3DController.shared.submitFrame(
      color: framed,
      output: stage.texture,
      contentAspect: aspect,
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
    // The CVMetalTexture owns the IOSurface-backed texture. submitFrame has
    // waited for the GPU, so releasing cvTexture here is the single release.
    CVMetalTextureCacheFlush(cache, 0)
    guard wrote else {
      if !loggedSendFailure {
        loggedSendFailure = true
        browserCaptureLog.error("glasses send failed")
      }
      releaseStage(stage.index)
      return
    }
    if !loggedSend {
      loggedSend = true
      browserCaptureLog.info("glasses send \(viewWidth)x\(viewHeight)")
    }
    let presented = stage.texture
    let slot = stage.index
    let stamp = time
    DispatchQueue.main.async { [weak self] in
      self?.present(presented, slot: slot, time: stamp)
    }
  }

  private func analyzeIfNeeded(_ pixelBuffer: CVPixelBuffer) {
    frameIndex += 1
    let mode = BrowserCaptureSettings.shared.cropMode
    let due = frameIndex == 1 || frameIndex % 15 == 0 || BrowserCaptureSettings.shared.takeAnalysisRequest()
    guard mode != .manual, due else { return }
    guard let insets = BrowserCaptureCropMath.detect(pixelBuffer: pixelBuffer, mode: mode) else { return }
    BrowserCaptureSettings.shared.updateDetected(insets)
  }

  /// A texture holding only the cropped rectangle, or nil when the crop is the whole frame.
  private func croppedFrame(from color: MTLTexture, device: MTLDevice) -> MTLTexture? {
    let insets = BrowserCaptureSettings.shared.appliedInsets()
    let width = color.width
    let height = color.height
    var originX = Int((insets.left * Double(width)).rounded())
    var originY = Int((insets.top * Double(height)).rounded())
    var cropWidth = width - originX - Int((insets.right * Double(width)).rounded())
    var cropHeight = height - originY - Int((insets.bottom * Double(height)).rounded())
    if cropWidth % 2 != 0 { cropWidth -= 1 }
    if cropHeight % 2 != 0 { cropHeight -= 1 }
    originX = max(0, min(originX, width - 2))
    originY = max(0, min(originY, height - 2))
    cropWidth = max(2, min(cropWidth, width - originX))
    cropHeight = max(2, min(cropHeight, height - originY))
    if cropWidth >= width - 1 && cropHeight >= height - 1 { return nil }
    guard let pipeline = cropPipeline,
          let destination = croppedTexture(device: device, width: cropWidth, height: cropHeight),
          let commandQueue,
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
    var rect = CropUniform(
      x: Float(originX) / Float(width),
      y: Float(originY) / Float(height),
      w: Float(cropWidth) / Float(width),
      h: Float(cropHeight) / Float(height)
    )
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(color, index: 0)
    encoder.setTexture(destination, index: 1)
    encoder.setBytes(&rect, length: MemoryLayout<CropUniform>.stride, index: 0)
    encoder.dispatchThreads(
      MTLSize(width: cropWidth, height: cropHeight, depth: 1),
      threadsPerThreadgroup: MTLSize(width: min(16, cropWidth), height: min(16, cropHeight), depth: 1)
    )
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.error == nil else { return nil }
    return destination
  }

  private func acquireStage(device: MTLDevice, width: Int, height: Int) -> (index: Int, texture: MTLTexture)? {
    stageLock.lock()
    defer { stageLock.unlock() }
    guard width > 1, height > 1 else { return nil }
    for index in 0..<stageTextures.count {
      if stageBusy[index] { continue }
      if let existing = stageTextures[index], existing.width == width, existing.height == height {
        stageBusy[index] = true
        return (index, existing)
      }
      let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
      desc.usage = [.shaderWrite, .shaderRead]
      desc.storageMode = .private
      guard let texture = device.makeTexture(descriptor: desc) else { continue }
      stageTextures[index] = texture
      stageBusy[index] = true
      return (index, texture)
    }
    return nil
  }

  private func releaseStage(_ index: Int) {
    stageLock.lock()
    if stageTextures.indices.contains(index) {
      stageBusy[index] = false
    }
    stageLock.unlock()
  }

  /// Drawable acquisition stays on the main thread and does not wait for the GPU. `allowsNextDrawableTimeout` makes `nextDrawable` return instead of blocking the run loop.
  private func present(_ texture: MTLTexture, slot: Int, time: CMTime) {
    guard let commandQueue,
          let layer = self.layer as? CAMetalLayer,
          let drawable = layer.nextDrawable(),
          drawable.texture.width == texture.width,
          drawable.texture.height == texture.height,
          let buffer = commandQueue.makeCommandBuffer(),
          let blit = buffer.makeBlitCommandEncoder() else {
      browserCaptureLog.error("glasses present skipped \(texture.width)x\(texture.height)")
      releaseStage(slot)
      return
    }
    blit.copy(
      from: texture,
      sourceSlice: 0,
      sourceLevel: 0,
      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
      to: drawable.texture,
      destinationSlice: 0,
      destinationLevel: 0,
      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
    )
    blit.endEncoding()
    buffer.addCompletedHandler { [weak self] _ in
      self?.releaseStage(slot)
    }
    buffer.present(drawable)
    buffer.commit()
    BrowserCaptureManager.shared.notePresentedVideo(time)
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

  private func croppedTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
    if let cropped, croppedWidth == width, croppedHeight == height { return cropped }
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .private
    guard let texture = device.makeTexture(descriptor: desc) else { return nil }
    cropped = texture
    croppedWidth = width
    croppedHeight = height
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
