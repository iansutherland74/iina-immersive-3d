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
  private var stageTextures: [MTLTexture?] = Array(repeating: nil, count: CaptureStagePool.count)
  private var stagePool = CaptureStagePool()
  private var queuedPresent: QueuedPresent?
  private var presentScheduled = false
  private let stageLock = NSLock()
  private var pixelWidth = 0
  private var pixelHeight = 0
  private var pixelScale: CGFloat = 2
  private var sizeLocked = false
  private var presentCount = 0
  private var tookDrawable = false
  private var resizePending = false
  private var resizeScheduled = false
  private var depthReadbackBusy = false
  private var lastTexture: MTLTexture?
  private var lastSlot = -1
  private var held: CVPixelBuffer?
  private var heldTime = CMTime.invalid
  private var fullSizeEyes = false
  private var blackFrames = 0
  private var showingBlack = false
  private var frameIndex = 0
  private var loggedTexture = false
  private var loggedLuma = false
  private var loggedDrawableWidth = 0
  private var loggedDrawableHeight = 0
  private var loggedUnready = false
  private var sentWidth = 0
  private var sentHeight = 0
  private var lastSkipLog: CFTimeInterval = 0
  private var lastPresentSkip: CFTimeInterval = 0
  private var latencyStamp: CFTimeInterval = 0
  private var latencyPending = false
  private var lastLatencyLog: CFTimeInterval = 0
  private var lastDropLog: CFTimeInterval = 0

  private struct CropUniform {
    var x: Float
    var y: Float
    var w: Float
    var h: Float
  }

  private struct QueuedPresent {
    var texture: MTLTexture
    var slot: Int
    var generation: Int
    var time: CMTime
    var received: CFTimeInterval
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

  /// `lock` keeps a glasses screen size from being replaced by a later layout pass that still has a zero bounds.
  func setPixelSize(width: Int, height: Int, scale: CGFloat, lock: Bool) {
    guard width >= 32, height >= 32 else { return }
    stageLock.lock()
    pixelWidth = width
    pixelHeight = height
    pixelScale = scale > 0 ? scale : 2
    sizeLocked = lock
    stageLock.unlock()
    let apply = { self.applyDrawableSize() }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async(execute: apply)
    }
  }

  func unlockPixelSize() {
    stageLock.lock()
    sizeLocked = false
    stageLock.unlock()
  }

  /// Layout during a Space change must put the locked glasses size back. It does not read the window's current screen.
  func reapplyLockedSize() {
    let apply = { self.applyDrawableSize() }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async(execute: apply)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyLockedDrawable()
    adoptViewSizeIfNeeded()
  }

  override func layout() {
    super.layout()
    applyLockedDrawable()
    adoptViewSizeIfNeeded()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    applyLockedDrawable()
    adoptViewSizeIfNeeded()
  }

  /// A glasses size can be chosen before the layer exists. Layout applies it once the layer is there.
  /// A drawable that is still in the autorelease pool must not be resized: CAMetalLayer releases it, and the pool's objc_release then crashes.
  private func applyLockedDrawable() {
    applyDrawableSize()
  }

  private func applyDrawableSize() {
    if !CaptureDrawableGuard.allowsResize(tookDrawable: tookDrawable, presentCount: presentCount) {
      resizePending = true
      scheduleResize()
      return
    }
    applyDrawableSizeNow()
  }

  /// Runs on a later main-queue turn, after the pool that took the drawable has popped.
  private func scheduleResize() {
    guard !resizeScheduled else { return }
    resizeScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.resizeScheduled = false
      guard self.presentCount == 0 else { return }
      self.resizePending = false
      self.applyDrawableSizeNow()
    }
  }

  private func applyDrawableSizeNow() {
    stageLock.lock()
    let width = pixelWidth
    let height = pixelHeight
    let scale = pixelScale
    stageLock.unlock()
    guard width >= 32, height >= 32, let layer = self.layer as? CAMetalLayer else {
      if width >= 32, height >= 32, loggedDrawableWidth != width || loggedDrawableHeight != height {
        loggedDrawableWidth = width
        loggedDrawableHeight = height
        browserCaptureLog.error("output drawable \(width)x\(height) waiting for the metal layer")
      }
      return
    }
    let target = CGSize(width: width, height: height)
    if layer.contentsScale != scale {
      layer.contentsScale = scale
    }
    guard layer.drawableSize != target else { return }
    layer.drawableSize = target
    if loggedDrawableWidth != width || loggedDrawableHeight != height {
      loggedDrawableWidth = width
      loggedDrawableHeight = height
      browserCaptureLog.info("output drawable \(width)x\(height) scale \(Double(scale), privacy: .public)")
    }
  }

  /// Preview size follows the view once it has a real bounds. A locked size is the glasses screen.
  private func adoptViewSizeIfNeeded() {
    stageLock.lock()
    let locked = sizeLocked
    stageLock.unlock()
    guard !locked else { return }
    let scale = window?.backingScaleFactor ?? 2
    let size = bounds.size
    let width = Int((size.width * scale).rounded())
    let height = Int((size.height * scale).rounded())
    guard width >= 32, height >= 32 else { return }
    stageLock.lock()
    let unchanged = pixelWidth == width && pixelHeight == height
    stageLock.unlock()
    guard !unchanged else { return }
    setPixelSize(width: width, height: height, scale: scale, lock: false)
  }

  func setFullSizeEyes(_ enabled: Bool) {
    fullSizeEyes = enabled
  }

  func requestCropAnalysis() {
    BrowserCaptureSettings.shared.requestAnalysis()
  }

  /// Called on the draw queue. The sample callback has already returned. `done` runs
  /// after the stereo command buffer finishes, so the next frame is not started
  /// while this one is still on the GPU, and this queue does not wait for it.
  func consume(_ pixelBuffer: CVPixelBuffer, at time: CMTime, received: CFTimeInterval, done: @escaping () -> Void = {}) {
    if Thread.isMainThread {
      BrowserCaptureManager.shared.performDraw { [weak self] in
        self?.consume(pixelBuffer, at: time, received: received, done: done)
      }
      return
    }
    held = pixelBuffer
    heldTime = time
    latencyStamp = received
    latencyPending = received > 0
    draw(pixelBuffer, at: time, done: done)
  }

  /// Depth became ready. Run the held frame through the stereo pass again.
  func redrawHeld() {
    if Thread.isMainThread {
      BrowserCaptureManager.shared.performDraw { [weak self] in
        self?.redrawHeld()
      }
      return
    }
    guard let held else { return }
    draw(held, at: heldTime, done: {})
  }

  /// Idle ScreenCaptureKit frames have no image. Show the last texture when it still matches the drawable. A size change rebuilds from the held frame. A slot that is already busy is left alone.
  func presentHeld() {
    if Thread.isMainThread {
      BrowserCaptureManager.shared.performDraw { [weak self] in
        self?.presentHeld()
      }
      return
    }
    switch heldAction() {
    case .present(let texture, let slot, let generation):
      let stamp = heldTime
      DispatchQueue.main.async { [weak self] in
        self?.present(texture, slot: slot, generation: generation, time: stamp)
      }
    case .wait:
      return
    case .redraw:
      guard let held else { return }
      draw(held, at: heldTime, done: {})
    }
  }

  private func draw(_ pixelBuffer: CVPixelBuffer, at time: CMTime, done: @escaping () -> Void) {
    guard let device = metalDevice,
          let cache = textureCache else {
      done()
      return
    }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 1, height > 1 else {
      done()
      return
    }
    if !loggedLuma {
      loggedLuma = true
      if let luma = Self.sourceLuma(pixelBuffer) {
        let text = String(format: "%.1f", luma)
        browserCaptureLog.info("first frame luma \(text, privacy: .public)")
      } else {
        browserCaptureLog.error("first frame luma unavailable")
      }
    }
    analyzeIfNeeded(pixelBuffer)
    guard let made = CaptureTextureLifetime.make(cache: cache, pixelBuffer: pixelBuffer, width: width, height: height) else {
      browserCaptureLog.error("texture conversion failed")
      CVMetalTextureCacheFlush(cache, 0)
      latencyPending = false
      done()
      return
    }
    let keep = CaptureTextureKeep(holder: made.holder, texture: made.texture, cache: cache, flush: frameIndex % 30 == 0)
    guard let color = keep.texture else {
      keep.recycle()
      latencyPending = false
      done()
      return
    }
    if !loggedTexture {
      loggedTexture = true
      browserCaptureLog.info("texture conversion \(width)x\(height)")
    }
    let encodeQueue = Immersive3DController.shared.captureEncodeQueue() ?? commandQueue
    guard let encodeQueue else {
      keep.recycle()
      latencyPending = false
      done()
      return
    }
    let framed = croppedFrame(from: color, device: device, queue: encodeQueue) ?? color
    stageLock.lock()
    let viewWidth = pixelWidth
    let viewHeight = pixelHeight
    stageLock.unlock()
    guard viewWidth >= 32, viewHeight >= 32 else {
      if !loggedUnready {
        loggedUnready = true
        browserCaptureLog.error("output size not ready (\(viewWidth)x\(viewHeight)); waiting for the preview or glasses screen")
      }
      latencyPending = false
      keep.recycle()
      done()
      return
    }
    guard let stage = acquireStage(device: device, width: viewWidth, height: viewHeight) else {
      let now = CACurrentMediaTime()
      if now - lastSkipLog > 1 {
        lastSkipLog = now
        browserCaptureLog.error("glasses send skipped; previous frame is still on the GPU")
      }
      latencyPending = false
      keep.recycle()
      done()
      return
    }
    let depthQueued = scheduleDepth(from: framed, device: device, queue: encodeQueue)
    let aspect = Float(framed.width) / Float(max(framed.height, 1))
    let presented = stage.texture
    let slot = stage.index
    let generation = stage.generation
    let stamp = time
    let received = latencyPending ? latencyStamp : 0
    latencyPending = false
    let wrote = Immersive3DController.shared.submitFrame(
      color: framed,
      output: presented,
      contentAspect: aspect,
      colorIsBottomUp: false,
      depthRGBA: nil,
      modelWidth: 0,
      modelHeight: 0,
      fullSizeEyes: fullSizeEyes,
      compositor: nil,
      whenDepthReady: { [weak self] in
        BrowserCaptureManager.shared.performDraw {
          self?.redrawHeld()
        }
      },
      whenGPUFinished: { [weak self] ok in
        BrowserCaptureManager.shared.performDraw {
          self?.collectDepthSample()
          keep.recycle()
          guard let self else {
            done()
            return
          }
          self.finishPicture(ok: ok, texture: presented, slot: slot, generation: generation, time: stamp, received: received, done: done)
        }
      }
    )
    guard wrote.ok else {
      browserCaptureLog.error("glasses send failed: \(wrote.reason, privacy: .public)")
      releaseStage(slot, generation: generation)
      latencyPending = false
      if depthQueued {
        releaseAfterEncode(queue: encodeQueue, keep: keep, done: done)
      } else {
        keep.recycle()
        done()
      }
      return
    }
    if sentWidth != viewWidth || sentHeight != viewHeight {
      sentWidth = viewWidth
      sentHeight = viewHeight
      browserCaptureLog.info("glasses send \(viewWidth)x\(viewHeight)")
    }
    stageLock.lock()
    lastTexture = presented
    lastSlot = slot
    stageLock.unlock()
  }

  /// The stereo pass has finished. Present it unless a newer frame is already waiting and this one is late.
  /// Only the newest finished frame waits on the main thread. The slot it replaces is freed here, so the next stereo pass is not skipped while that present sits in the queue.
  private func finishPicture(ok: Bool, texture: MTLTexture, slot: Int, generation: Int, time: CMTime, received: CFTimeInterval, done: @escaping () -> Void) {
    let newer = BrowserCaptureManager.shared.hasPendingFrame
    let age = received > 0 ? CACurrentMediaTime() - received : 0
    if ok && CapturePresentBudget.shouldPresent(age: age, newerWaiting: newer) {
      stageLock.lock()
      queuedPresent = QueuedPresent(texture: texture, slot: slot, generation: generation, time: time, received: received)
      let replaced = stagePool.enqueue(CaptureStagePool.Claim(index: slot, generation: generation))
      let schedule = !presentScheduled
      presentScheduled = true
      stageLock.unlock()
      if let replaced {
        releaseStage(replaced.index, generation: replaced.generation)
      }
      if schedule {
        DispatchQueue.main.async { [weak self] in
          self?.drainPresent()
        }
      }
    } else {
      releaseStage(slot, generation: generation)
      if ok {
        let now = CACurrentMediaTime()
        if now - lastDropLog > 1 {
          lastDropLog = now
          let ms = Int((age * 1000).rounded())
          browserCaptureLog.info("dropped a late capture frame \(ms) ms")
        }
      }
    }
    done()
  }

  private func drainPresent() {
    stageLock.lock()
    guard let queued = queuedPresent else {
      presentScheduled = false
      stageLock.unlock()
      return
    }
    queuedPresent = nil
    _ = stagePool.takeForPresent()
    stageLock.unlock()
    present(queued.texture, slot: queued.slot, generation: queued.generation, time: queued.time, received: queued.received)
    stageLock.lock()
    let more = queuedPresent != nil
    if !more {
      presentScheduled = false
    }
    stageLock.unlock()
    if more {
      DispatchQueue.main.async { [weak self] in
        self?.drainPresent()
      }
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
  /// The crop is committed on `queue` and not waited on. The stereo buffer committed
  /// next on the same queue runs after it.
  private func croppedFrame(from color: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
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
          let commandBuffer = queue.makeCommandBuffer(),
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
    let group = StereoOffscreen.threadgroupSize(maxThreads: pipeline.maxTotalThreadsPerThreadgroup, width: cropWidth, height: cropHeight)
    encoder.dispatchThreads(
      MTLSize(width: cropWidth, height: cropHeight, depth: 1),
      threadsPerThreadgroup: group
    )
    encoder.endEncoding()
    commandBuffer.commit()
    return destination
  }

  /// Scales a depth sample on `queue` and returns. The bytes are read in `collectDepthSample` after the stereo buffer on the same queue finishes.
  private func scheduleDepth(from color: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) -> Bool {
    guard !depthReadbackBusy else { return false }
    guard let size = DepthEstimator.shared.inputSize() else {
      DepthEstimator.shared.ensureLoaded()
      return false
    }
    guard let pipeline = scalePipeline,
          let texture = scaledTexture(device: device, width: size.width, height: size.height),
          let commandBuffer = queue.makeCommandBuffer(),
          let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
    var oriented: Float = 0
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(color, index: 0)
    encoder.setTexture(texture, index: 1)
    encoder.setBytes(&oriented, length: MemoryLayout<Float>.size, index: 0)
    let group = StereoOffscreen.threadgroupSize(maxThreads: pipeline.maxTotalThreadsPerThreadgroup, width: size.width, height: size.height)
    encoder.dispatchThreads(MTLSize(width: size.width, height: size.height, depth: 1), threadsPerThreadgroup: group)
    encoder.endEncoding()
    commandBuffer.commit()
    depthReadbackBusy = true
    return true
  }

  private func collectDepthSample() {
    guard depthReadbackBusy else { return }
    depthReadbackBusy = false
    guard let size = DepthEstimator.shared.inputSize(), let texture = scaled, texture.width == size.width, texture.height == size.height else { return }
    var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
    let copied = bytes.withUnsafeMutableBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return false }
      texture.getBytes(base, bytesPerRow: size.width * 4, from: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0)
      return true
    }
    guard copied else { return }
    noteLuma(Self.meanLuma(bytes))
    Immersive3DController.shared.submitCaptureDepth(bytes, width: size.width, height: size.height) { [weak self] in
      BrowserCaptureManager.shared.performDraw {
        self?.redrawHeld()
      }
    }
  }

  /// An empty buffer committed after a depth scale, so the source texture stays alive until that scale finishes.
  private func releaseAfterEncode(queue: MTLCommandQueue, keep: CaptureTextureKeep, done: @escaping () -> Void) {
    guard let buffer = queue.makeCommandBuffer() else {
      depthReadbackBusy = false
      keep.recycle()
      done()
      return
    }
    buffer.addCompletedHandler { [weak self] _ in
      BrowserCaptureManager.shared.performDraw {
        self?.depthReadbackBusy = false
        keep.recycle()
        done()
      }
    }
    buffer.commit()
  }

  private func acquireStage(device: MTLDevice, width: Int, height: Int) -> (index: Int, generation: Int, texture: MTLTexture)? {
    stageLock.lock()
    defer { stageLock.unlock() }
    guard width >= 32, height >= 32 else { return nil }
    var failed: [CaptureStagePool.Claim] = []
    while let claim = stagePool.acquire(now: CACurrentMediaTime()) {
      if let existing = stageTextures[claim.index], existing.width == width, existing.height == height {
        for item in failed { stagePool.release(item) }
        return (claim.index, claim.generation, existing)
      }
      let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
      desc.usage = [.shaderWrite, .shaderRead]
      desc.storageMode = .private
      if let texture = device.makeTexture(descriptor: desc) {
        for item in failed { stagePool.release(item) }
        stageTextures[claim.index] = texture
        return (claim.index, claim.generation, texture)
      }
      failed.append(claim)
    }
    for item in failed { stagePool.release(item) }
    return nil
  }

  private func releaseStage(_ index: Int, generation: Int) {
    stageLock.lock()
    stagePool.release(CaptureStagePool.Claim(index: index, generation: generation))
    stageLock.unlock()
  }

  private enum HeldAction {
    case present(MTLTexture, Int, Int)
    case wait
    case redraw
  }

  /// Marks the last texture's slot busy again so an idle blit is not overwritten by the next frame.
  private func heldAction() -> HeldAction {
    stageLock.lock()
    defer { stageLock.unlock() }
    guard pixelWidth >= 32, pixelHeight >= 32 else { return .wait }
    guard let texture = lastTexture else { return .redraw }
    if texture.width != pixelWidth || texture.height != pixelHeight { return .redraw }
    guard stageTextures.indices.contains(lastSlot),
          let current = stageTextures[lastSlot], current === texture else { return .redraw }
    guard let claim = stagePool.claimExisting(index: lastSlot, now: CACurrentMediaTime()) else { return .wait }
    return .present(texture, claim.index, claim.generation)
  }

  /// Drawable acquisition stays on the main thread and does not wait for the GPU. `allowsNextDrawableTimeout` makes `nextDrawable` return instead of blocking the run loop. The slot is released here if the present is not committed, and in the command-buffer completion otherwise. The drawable size is not changed while this present holds a drawable.
  private func present(_ texture: MTLTexture, slot: Int?, generation: Int, time: CMTime, received: CFTimeInterval = 0) {
    if let slot {
      stageLock.lock()
      stagePool.notePresenting(index: slot, generation: generation)
      stageLock.unlock()
    }
    if presentCount == 0 && !tookDrawable {
      applyDrawableSizeNow()
    }
    presentCount += 1
    var handedOff = false
    defer {
      if !handedOff {
        endPresent()
        if let slot {
          releaseStage(slot, generation: generation)
        }
      }
    }
    guard let commandQueue, let layer = self.layer as? CAMetalLayer else {
      logPresentSkip("glasses present skipped; metal layer is not ready")
      return
    }
    guard let drawable = layer.nextDrawable() else {
      stageLock.lock()
      let targetWidth = pixelWidth
      let targetHeight = pixelHeight
      stageLock.unlock()
      logPresentSkip("glasses present skipped; no drawable \(targetWidth)x\(targetHeight)")
      return
    }
    tookDrawable = true
    let fit = GlassesDrawable.presentFit(
      textureWidth: texture.width,
      textureHeight: texture.height,
      drawableWidth: drawable.texture.width,
      drawableHeight: drawable.texture.height
    )
    guard fit != .drop else {
      logPresentSkip("glasses present skipped; drawable \(drawable.texture.width)x\(drawable.texture.height)")
      return
    }
    guard let buffer = commandQueue.makeCommandBuffer() else {
      logPresentSkip("glasses present skipped; command buffer was not created")
      return
    }
    if fit == .blit {
      guard let blit = buffer.makeBlitCommandEncoder() else {
        logPresentSkip("glasses present skipped; command buffer was not created")
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
    } else if !encodeScale(from: texture, to: drawable.texture, buffer: buffer) {
      logPresentSkip("glasses present scale failed \(texture.width)x\(texture.height) drawable \(drawable.texture.width)x\(drawable.texture.height)")
      return
    }
    buffer.addCompletedHandler { [weak self] commandBuffer in
      if let slot {
        self?.releaseStage(slot, generation: generation)
      }
      DispatchQueue.main.async {
        self?.endPresent()
        if let error = commandBuffer.error {
          browserCaptureLog.error("glasses present failed: \(error.localizedDescription, privacy: .public)")
        }
      }
    }
    buffer.present(drawable)
    buffer.commit()
    handedOff = true
    reportLatency(received)
    BrowserCaptureManager.shared.notePresentedVideo(time)
  }

  private func endPresent() {
    presentCount = max(0, presentCount - 1)
    if presentCount == 0 && resizePending {
      scheduleResize()
    }
  }

  private func encodeScale(from texture: MTLTexture, to destination: MTLTexture, buffer: MTLCommandBuffer) -> Bool {
    guard let pipeline = scalePipeline, let encoder = buffer.makeComputeCommandEncoder() else { return false }
    var oriented: Float = 0
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(texture, index: 0)
    encoder.setTexture(destination, index: 1)
    encoder.setBytes(&oriented, length: MemoryLayout<Float>.stride, index: 0)
    let group = StereoOffscreen.threadgroupSize(maxThreads: pipeline.maxTotalThreadsPerThreadgroup, width: destination.width, height: destination.height)
    encoder.dispatchThreads(
      MTLSize(width: destination.width, height: destination.height, depth: 1),
      threadsPerThreadgroup: group
    )
    encoder.endEncoding()
    return true
  }

  private func reportLatency(_ received: CFTimeInterval) {
    guard received > 0 else { return }
    let now = CACurrentMediaTime()
    BrowserCaptureManager.shared.noteCaptureLatency(now - received)
    let ms = CaptureLatency.milliseconds(received: received, presented: now)
    if now - lastLatencyLog < 1 { return }
    lastLatencyLog = now
    browserCaptureLog.info("capture latency \(ms) ms")
  }

  private func logPresentSkip(_ message: String) {
    let now = CACurrentMediaTime()
    if now - lastPresentSkip < 1 { return }
    lastPresentSkip = now
    browserCaptureLog.error("\(message, privacy: .public)")
  }

  private static func sourceLuma(_ pixelBuffer: CVPixelBuffer) -> Float? {
    guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard width > 1, height > 1, rowBytes >= width * 4 else { return nil }
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    let stepX = max(width / 48, 1)
    let stepY = max(height / 48, 1)
    var sum: Float = 0
    var count = 0
    var y = 0
    while y < height {
      var x = 0
      let row = y * rowBytes
      while x < width {
        let offset = row + x * 4
        sum += 0.2126 * Float(pixels[offset + 2]) + 0.7152 * Float(pixels[offset + 1]) + 0.0722 * Float(pixels[offset])
        count += 1
        x += stepX
      }
      y += stepY
    }
    guard count > 0 else { return nil }
    return sum / Float(count)
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

/// Holds the CVMetalTexture until the command buffer that samples it has finished.
private final class CaptureTextureKeep {
  var holder: CVMetalTexture?
  var texture: MTLTexture?
  let cache: CVMetalTextureCache
  let flush: Bool

  init(holder: CVMetalTexture, texture: MTLTexture, cache: CVMetalTextureCache, flush: Bool) {
    self.holder = holder
    self.texture = texture
    self.cache = cache
    self.flush = flush
  }

  func recycle() {
    CaptureTextureLifetime.recycle(holder: &holder, texture: &texture, cache: cache, flush: flush)
  }
}
