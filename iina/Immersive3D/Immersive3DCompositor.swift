//
//  Immersive3DCompositor.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Called from ViewLayer.draw(inCGLContext:) after mpv_render_context_render.
//  The layer framebuffer already holds the decoded frame (subtitles included).
//  This copies it to an IOSurface, estimates depth asynchronously, and replaces
//  the framebuffer with a full-frame side-by-side image from the Metal kernel.

import Cocoa
import CoreVideo
import IOSurface
import Metal
import OpenGL.GL
import OpenGL.GL3

final class Immersive3DCompositor {
  private let device: MTLDevice?
  private let commandQueue: MTLCommandQueue?
  private var pipeline: MTLComputePipelineState?
  private var pipelineFailed = false

  private var program: GLuint = 0
  private var vao: GLuint = 0
  private var vbo: GLuint = 0
  private var sizeUniform: GLint = -1
  private var glReady = false
  private var glFailed = false
  private var failureCount = 0

  private var surfaces: SharedSurfaces?
  private var small: SmallTarget?
  private var depthTexture: MTLTexture?
  private var depthSerial: UInt64 = 0
  private var depthWidth = 0
  private var depthHeight = 0

  private var previousSmall: [UInt8]?
  private var lastSubmit = Date.distantPast
  private let changeThreshold: Float = 2.2
  private let maxReuseInterval: TimeInterval = 0.4

  init() {
    let device = MTLCreateSystemDefaultDevice()
    self.device = device
    self.commandQueue = device?.makeCommandQueue()
    if device == nil {
      log3D("No Metal device; Immersive 3D will pass frames through", level: .error)
    }
  }

  /// Replace the current layer framebuffer with side-by-side stereo when Immersive 3D is on.
  /// Already-SBS sources are not passed in here. Returns without drawing if the pass cannot run,
  /// which leaves mpv's frame untouched.
  func process(cglContext: CGLContextObj, layerFBO: GLuint, width: Int, height: Int, whenDepthReady: @escaping () -> Void) {
    guard width >= 16, height >= 16, !glFailed, !pipelineFailed else { return }
    guard let device, let commandQueue else { return }
    let snapshot = Immersive3DController.shared.currentSnapshot()
    guard snapshot.shouldProcess else { return }

    let saved = GLState.capture()
    defer { saved.restore() }

    guard ensureGLProgram() else {
      noteFailure("OpenGL present shader")
      return
    }
    guard ensurePipeline(device: device) else {
      noteFailure("Metal stereo pipeline")
      return
    }
    guard let surfaces = ensureSurfaces(cglContext: cglContext, device: device, width: width, height: height) else {
      noteFailure("IOSurface")
      return
    }

    if let size = DepthEstimator.shared.inputSize() {
      considerDepthUpdate(layerFBO: layerFBO, fullWidth: width, fullHeight: height, modelWidth: size.width, modelHeight: size.height, whenDepthReady: whenDepthReady)
    } else {
      DepthEstimator.shared.ensureLoaded()
    }
    _ = uploadDepthIfNeeded(device: device)

    blit(from: layerFBO, to: surfaces.colorFBO, srcWidth: width, srcHeight: height, dstWidth: width, dstHeight: height)
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    glFinish()

    guard encode(commandQueue: commandQueue, surfaces: surfaces, snapshot: snapshot, width: width, height: height) else {
      noteFailure("Metal encode")
      return
    }
    present(surfaces: surfaces, layerFBO: layerFBO, width: width, height: height)
    failureCount = 0
  }

  // MARK: - Depth

  private func considerDepthUpdate(layerFBO: GLuint, fullWidth: Int, fullHeight: Int, modelWidth: Int, modelHeight: Int, whenDepthReady: @escaping () -> Void) {
    guard ensureSmallTarget(width: modelWidth, height: modelHeight), let small else { return }
    blit(from: layerFBO, to: small.fbo, srcWidth: fullWidth, srcHeight: fullHeight, dstWidth: modelWidth, dstHeight: modelHeight)
    glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), small.fbo)
    glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
    glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 1)
    var pixels = [UInt8](repeating: 0, count: modelWidth * modelHeight * 4)
    pixels.withUnsafeMutableBytes { raw in
      glReadPixels(0, 0, GLsizei(modelWidth), GLsizei(modelHeight), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), raw.baseAddress)
    }
    flipVertical(&pixels, width: modelWidth, height: modelHeight)
    let now = Date()
    let delta = previousSmall.map { meanLumaDelta($0, pixels) } ?? 255
    let stale = now.timeIntervalSince(lastSubmit) >= maxReuseInterval
    previousSmall = pixels
    guard delta >= changeThreshold || stale || lastSubmit == .distantPast else { return }
    lastSubmit = now
    DepthEstimator.shared.submit(topDownRGBA: pixels, width: modelWidth, height: modelHeight, token: ObjectIdentifier(self), whenReady: whenDepthReady)
  }

  private func uploadDepthIfNeeded(device: MTLDevice) -> MTLTexture? {
    if let image = DepthEstimator.shared.latestIfNew(token: ObjectIdentifier(self), since: depthSerial) {
      guard let texture = makeDepthTexture(device: device, width: image.width, height: image.height) else { return depthTexture }
      image.pixels.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0, withBytes: base, bytesPerRow: image.width * MemoryLayout<Float>.size)
      }
      depthSerial = image.serial
      return texture
    }
    if depthTexture == nil {
      guard let texture = makeDepthTexture(device: device, width: 2, height: 2) else { return nil }
      var flat = [Float](repeating: 0.5, count: 4)
      flat.withUnsafeBytes { raw in
        texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: 8)
      }
      return texture
    }
    return depthTexture
  }

  private func makeDepthTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
    if let depthTexture, depthWidth == width, depthHeight == height {
      return depthTexture
    }
    guard width > 0, height > 0 else { return nil }
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
    desc.usage = [.shaderRead]
    desc.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: desc) else { return nil }
    depthTexture = texture
    depthWidth = width
    depthHeight = height
    return texture
  }

  // MARK: - Metal

  private func ensurePipeline(device: MTLDevice) -> Bool {
    if pipeline != nil { return true }
    if pipelineFailed { return false }
    do {
      guard let library = device.makeDefaultLibrary(),
            let function = library.makeFunction(name: "immersiveStereo") else {
        log3D("immersiveStereo is missing from the default Metal library. Is Immersive3D.metal in the IINA target?", level: .error)
        pipelineFailed = true
        return false
      }
      pipeline = try device.makeComputePipelineState(function: function)
      return true
    } catch {
      log3D("Metal pipeline failed: \(error.localizedDescription)", level: .error)
      pipelineFailed = true
      return false
    }
  }

  private func encode(commandQueue: MTLCommandQueue, surfaces: SharedSurfaces, snapshot: Immersive3DController.Snapshot, width: Int, height: Int) -> Bool {
    guard let pipeline, let depthTexture,
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
    var params = StereoParams(
      maxShift: snapshot.maxShift,
      convergence: snapshot.convergence,
      holeThreshold: 0.08,
      invertDepth: snapshot.invertDepth ? 1 : 0,
      glOriented: snapshot.verticalFlip ? 0 : 1,
      searchPixels: 18
    )
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(surfaces.colorMetal, index: 0)
    encoder.setTexture(depthTexture, index: 1)
    encoder.setTexture(surfaces.outputMetal, index: 2)
    encoder.setBytes(&params, length: MemoryLayout<StereoParams>.stride, index: 0)
    let threads = MTLSize(width: width, height: height, depth: 1)
    let group = MTLSize(width: 16, height: 16, depth: 1)
    encoder.dispatchThreads(threads, threadsPerThreadgroup: group)
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    if let error = commandBuffer.error {
      log3D("Stereo command buffer failed: \(error.localizedDescription)", level: .error)
      return false
    }
    return true
  }

  // MARK: - OpenGL

  private func ensureGLProgram() -> Bool {
    if glReady { return true }
    let vertex: String = """
    #version 150
    in vec2 aPos;
    out vec2 vUV;
    void main() {
      vUV = aPos * 0.5 + 0.5;
      gl_Position = vec4(aPos, 0.0, 1.0);
    }
    """
    let fragment: String = """
    #version 150
    uniform sampler2DRect uTex;
    uniform vec2 uSize;
    in vec2 vUV;
    out vec4 fragColor;
    void main() {
      fragColor = texture(uTex, vUV * uSize);
    }
    """
    let vs = compileShader(GLenum(GL_VERTEX_SHADER), vertex)
    let fs = compileShader(GLenum(GL_FRAGMENT_SHADER), fragment)
    guard vs != 0, fs != 0 else {
      glFailed = true
      return false
    }
    let program = glCreateProgram()
    glAttachShader(program, vs)
    glAttachShader(program, fs)
    glBindAttribLocation(program, 0, "aPos")
    glLinkProgram(program)
    glDeleteShader(vs)
    glDeleteShader(fs)
    var linked: GLint = 0
    glGetProgramiv(program, GLenum(GL_LINK_STATUS), &linked)
    guard linked != 0 else {
      log3D("Present program link failed: \(shaderLog(program, program: true))", level: .error)
      glDeleteProgram(program)
      glFailed = true
      return false
    }
    var vertices: [Float] = [-1, -1, 1, -1, -1, 1, 1, 1]
    var vao: GLuint = 0
    var vbo: GLuint = 0
    glGenVertexArrays(1, &vao)
    glGenBuffers(1, &vbo)
    glBindVertexArray(vao)
    glBindBuffer(GLenum(GL_ARRAY_BUFFER), vbo)
    glBufferData(GLenum(GL_ARRAY_BUFFER), GLsizeiptr(vertices.count * MemoryLayout<Float>.size), &vertices, GLenum(GL_STATIC_DRAW))
    glEnableVertexAttribArray(0)
    glVertexAttribPointer(0, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), GLsizei(MemoryLayout<Float>.size * 2), nil)
    glBindVertexArray(0)
    self.program = program
    self.vao = vao
    self.vbo = vbo
    self.sizeUniform = glGetUniformLocation(program, "uSize")
    glReady = true
    return true
  }

  private func present(surfaces: SharedSurfaces, layerFBO: GLuint, width: Int, height: Int) {
    glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), layerFBO)
    glViewport(0, 0, GLsizei(width), GLsizei(height))
    glDisable(GLenum(GL_BLEND))
    glDisable(GLenum(GL_DEPTH_TEST))
    glDisable(GLenum(GL_SCISSOR_TEST))
    glUseProgram(program)
    glUniform2f(sizeUniform, GLfloat(width), GLfloat(height))
    glActiveTexture(GLenum(GL_TEXTURE0))
    glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), surfaces.outputGL)
    glBindVertexArray(vao)
    glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
    glBindVertexArray(0)
  }

  private func blit(from src: GLuint, to dst: GLuint, srcWidth: Int, srcHeight: Int, dstWidth: Int, dstHeight: Int) {
    glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), src)
    glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), dst)
    glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
    glDrawBuffer(GLenum(GL_COLOR_ATTACHMENT0))
    glBlitFramebuffer(0, 0, GLint(srcWidth), GLint(srcHeight), 0, 0, GLint(dstWidth), GLint(dstHeight), GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR))
  }

  private func ensureSmallTarget(width: Int, height: Int) -> Bool {
    if let small, small.width == width, small.height == height { return true }
    if let small {
      var tex = small.tex
      var fbo = small.fbo
      glDeleteTextures(1, &tex)
      glDeleteFramebuffers(1, &fbo)
      self.small = nil
      // A newly selected depth model may use a different input size.
      previousSmall = nil
      lastSubmit = .distantPast
    }
    var tex: GLuint = 0
    var fbo: GLuint = 0
    glGenTextures(1, &tex)
    glBindTexture(GLenum(GL_TEXTURE_2D), tex)
    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GLint(GL_LINEAR))
    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GLint(GL_LINEAR))
    glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GLint(GL_RGBA8), GLsizei(width), GLsizei(height), 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
    glGenFramebuffers(1, &fbo)
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
    glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), tex, 0)
    let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
    guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
      log3D("Small depth FBO incomplete (\(status))", level: .error)
      glDeleteTextures(1, &tex)
      glDeleteFramebuffers(1, &fbo)
      return false
    }
    small = SmallTarget(width: width, height: height, tex: tex, fbo: fbo)
    previousSmall = nil
    return true
  }

  private func ensureSurfaces(cglContext: CGLContextObj, device: MTLDevice, width: Int, height: Int) -> SharedSurfaces? {
    if let surfaces, surfaces.width == width, surfaces.height == height {
      return surfaces
    }
    destroySurfaces()
    guard let color = makeSurface(cglContext: cglContext, device: device, width: width, height: height, needsFBO: true),
          let output = makeSurface(cglContext: cglContext, device: device, width: width, height: height, needsFBO: false) else {
      destroySurfaces()
      return nil
    }
    let shared = SharedSurfaces(
      width: width,
      height: height,
      colorSurface: color.surface,
      colorGL: color.gl,
      colorFBO: color.fbo,
      colorMetal: color.metal,
      outputSurface: output.surface,
      outputGL: output.gl,
      outputMetal: output.metal
    )
    surfaces = shared
    log3D("Immersive 3D surfaces \(width)x\(height)", level: .debug)
    return shared
  }

  private func makeSurface(cglContext: CGLContextObj, device: MTLDevice, width: Int, height: Int, needsFBO: Bool) -> (surface: IOSurfaceRef, gl: GLuint, fbo: GLuint, metal: MTLTexture)? {
    let bytesPerRow = (width * 4 + 15) & ~15
    let props: [CFString: Any] = [
      kIOSurfaceWidth: NSNumber(value: width),
      kIOSurfaceHeight: NSNumber(value: height),
      kIOSurfaceBytesPerElement: NSNumber(value: 4),
      kIOSurfaceBytesPerRow: NSNumber(value: bytesPerRow),
      kIOSurfacePixelFormat: NSNumber(value: kCVPixelFormatType_32BGRA),
      kIOSurfaceAllocSize: NSNumber(value: bytesPerRow * height)
    ]
    guard let surface = IOSurfaceCreate(props as CFDictionary) else { return nil }
    var tex: GLuint = 0
    glGenTextures(1, &tex)
    glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), tex)
    glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_TEXTURE_MIN_FILTER), GLint(GL_LINEAR))
    glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_TEXTURE_MAG_FILTER), GLint(GL_LINEAR))
    let cglError = CGLTexImageIOSurface2D(
      cglContext,
      GLenum(GL_TEXTURE_RECTANGLE),
      GLenum(GL_RGBA),
      GLsizei(width),
      GLsizei(height),
      GLenum(GL_BGRA),
      GLenum(GL_UNSIGNED_INT_8_8_8_8_REV),
      surface,
      0
    )
    guard cglError == kCGLNoError else {
      log3D("CGLTexImageIOSurface2D failed (\(cglError))", level: .error)
      glDeleteTextures(1, &tex)
      return nil
    }
    var fbo: GLuint = 0
    if needsFBO {
      glGenFramebuffers(1, &fbo)
      glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
      glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_RECTANGLE), tex, 0)
      let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
      guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
        log3D("Color IOSurface FBO incomplete (\(status))", level: .error)
        glDeleteTextures(1, &tex)
        glDeleteFramebuffers(1, &fbo)
        return nil
      }
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    desc.usage = needsFBO ? [.shaderRead] : [.shaderWrite]
    desc.storageMode = .shared
    guard let metal = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) else {
      glDeleteTextures(1, &tex)
      if fbo != 0 { glDeleteFramebuffers(1, &fbo) }
      return nil
    }
    return (surface, tex, fbo, metal)
  }

  private func destroySurfaces() {
    guard let surfaces else { return }
    var color = surfaces.colorGL
    var output = surfaces.outputGL
    var fbo = surfaces.colorFBO
    glDeleteTextures(1, &color)
    glDeleteTextures(1, &output)
    if fbo != 0 { glDeleteFramebuffers(1, &fbo) }
    self.surfaces = nil
  }

  private func noteFailure(_ stage: String) {
    failureCount += 1
    if failureCount == 1 || failureCount == 8 {
      log3D("Immersive 3D pass failed at \(stage); showing the original frame", level: .error)
    }
    if failureCount >= 8 {
      glFailed = true
    }
  }
}

private struct StereoParams {
  var maxShift: Float
  var convergence: Float
  var holeThreshold: Float
  var invertDepth: Float
  var glOriented: Float
  var searchPixels: Float
}

private struct SmallTarget {
  var width: Int
  var height: Int
  var tex: GLuint
  var fbo: GLuint
}

private struct SharedSurfaces {
  var width: Int
  var height: Int
  var colorSurface: IOSurfaceRef
  var colorGL: GLuint
  var colorFBO: GLuint
  var colorMetal: MTLTexture
  var outputSurface: IOSurfaceRef
  var outputGL: GLuint
  var outputMetal: MTLTexture
}

private struct GLState {
  var readFBO: GLint
  var drawFBO: GLint
  var viewport: [GLint]
  var program: GLint
  var vao: GLint
  var activeTexture: GLint
  var rectTexture: GLint
  var tex2D: GLint
  var pack: GLint
  var blend: GLboolean
  var depth: GLboolean
  var scissor: GLboolean

  static func capture() -> GLState {
    var readFBO: GLint = 0
    var drawFBO: GLint = 0
    var viewport = [GLint](repeating: 0, count: 4)
    var program: GLint = 0
    var vao: GLint = 0
    var active: GLint = 0
    var rect: GLint = 0
    var tex2D: GLint = 0
    var pack: GLint = 4
    glGetIntegerv(GLenum(GL_READ_FRAMEBUFFER_BINDING), &readFBO)
    glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &drawFBO)
    glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
    glGetIntegerv(GLenum(GL_CURRENT_PROGRAM), &program)
    glGetIntegerv(GLenum(GL_VERTEX_ARRAY_BINDING), &vao)
    glGetIntegerv(GLenum(GL_ACTIVE_TEXTURE), &active)
    glGetIntegerv(GLenum(GL_TEXTURE_BINDING_RECTANGLE), &rect)
    glGetIntegerv(GLenum(GL_TEXTURE_BINDING_2D), &tex2D)
    glGetIntegerv(GLenum(GL_PACK_ALIGNMENT), &pack)
    return GLState(
      readFBO: readFBO,
      drawFBO: drawFBO,
      viewport: viewport,
      program: program,
      vao: vao,
      activeTexture: active,
      rectTexture: rect,
      tex2D: tex2D,
      pack: pack,
      blend: glIsEnabled(GLenum(GL_BLEND)),
      depth: glIsEnabled(GLenum(GL_DEPTH_TEST)),
      scissor: glIsEnabled(GLenum(GL_SCISSOR_TEST))
    )
  }

  func restore() {
    glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(readFBO))
    glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), GLuint(drawFBO))
    glViewport(viewport[0], viewport[1], viewport[2], viewport[3])
    glUseProgram(GLuint(program))
    glBindVertexArray(GLuint(vao))
    glActiveTexture(GLenum(activeTexture))
    glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), GLuint(rectTexture))
    glBindTexture(GLenum(GL_TEXTURE_2D), GLuint(tex2D))
    glPixelStorei(GLenum(GL_PACK_ALIGNMENT), pack)
    setEnabled(GLenum(GL_BLEND), blend)
    setEnabled(GLenum(GL_DEPTH_TEST), depth)
    setEnabled(GLenum(GL_SCISSOR_TEST), scissor)
  }

  private func setEnabled(_ cap: GLenum, _ enabled: GLboolean) {
    if enabled == GL_TRUE {
      glEnable(cap)
    } else {
      glDisable(cap)
    }
  }
}

private func compileShader(_ type: GLenum, _ source: String) -> GLuint {
  let shader = glCreateShader(type)
  source.withCString { pointer in
    var pointer = pointer
    glShaderSource(shader, 1, &pointer, nil)
  }
  glCompileShader(shader)
  var status: GLint = 0
  glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &status)
  guard status != 0 else {
    log3D("Shader compile failed: \(shaderLog(shader, program: false))", level: .error)
    glDeleteShader(shader)
    return 0
  }
  return shader
}

private func shaderLog(_ object: GLuint, program: Bool) -> String {
  var length: GLint = 0
  if program {
    glGetProgramiv(object, GLenum(GL_INFO_LOG_LENGTH), &length)
  } else {
    glGetShaderiv(object, GLenum(GL_INFO_LOG_LENGTH), &length)
  }
  guard length > 1 else { return "no log" }
  var chars = [GLchar](repeating: 0, count: Int(length))
  if program {
    glGetProgramInfoLog(object, length, nil, &chars)
  } else {
    glGetShaderInfoLog(object, length, nil, &chars)
  }
  return String(cString: chars)
}

private func flipVertical(_ pixels: inout [UInt8], width: Int, height: Int) {
  let row = width * 4
  guard row > 0, height > 1 else { return }
  for y in 0..<(height / 2) {
    let top = y * row
    let bottom = (height - 1 - y) * row
    for i in 0..<row {
      let tmp = pixels[top + i]
      pixels[top + i] = pixels[bottom + i]
      pixels[bottom + i] = tmp
    }
  }
}

private func meanLumaDelta(_ a: [UInt8], _ b: [UInt8]) -> Float {
  let pixels = min(a.count, b.count) / 4
  guard pixels > 0 else { return 255 }
  let step = max(pixels / 2048, 1)
  var accum: Float = 0
  var count = 0
  var i = 0
  while i < pixels {
    let o = i * 4
    let la = 0.2126 * Float(a[o]) + 0.7152 * Float(a[o + 1]) + 0.0722 * Float(a[o + 2])
    let lb = 0.2126 * Float(b[o]) + 0.7152 * Float(b[o + 1]) + 0.0722 * Float(b[o + 2])
    accum += abs(la - lb)
    count += 1
    i += step
  }
  return accum / Float(max(count, 1))
}
