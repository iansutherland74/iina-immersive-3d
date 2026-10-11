//
//  Browser Capture self-test. No window server and no glasses display.
//  Compile with other/browser-capture-selftest.sh.
//

import CoreGraphics
import CoreVideo
import Foundation
import Metal

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
  if condition {
    print("ok \(message)")
  } else {
    failures += 1
    print("FAIL \(message)")
  }
}

private let glasses = GlassesDisplayChoice(id: 1, pixelWidth: 3840, pixelHeight: 1080, fullSizeEyes: true, name: "SmartGlasses")

private func chrome(_ id: UInt32, title: String, width: Int, height: Int, onScreen: Bool, displayID: UInt32 = 2) -> CaptureWindowRecord {
  CaptureWindowRecord(
    id: id,
    title: title,
    owner: "Google Chrome",
    bundleID: "com.google.Chrome",
    width: width,
    height: height,
    onScreen: onScreen,
    displayID: displayID
  )
}

private func testDrawable() {
  let full = GlassesDrawable.pixels(pointsWidth: 3840, pointsHeight: 1080, scale: 1)
  check(full?.width == 3840 && full?.height == 1080, "3840x1080 points at scale 1")
  let retina = GlassesDrawable.pixels(pointsWidth: 1920, pointsHeight: 1080, scale: 2)
  check(retina?.width == 3840 && retina?.height == 2160, "1920x1080 points at scale 2")
  let preview = GlassesDrawable.previewPixels(scale: 2)
  check(preview.width == 1920 && preview.height == 1080, "preview 960x540 at scale 2")
  check(GlassesDrawable.pixels(pointsWidth: 0, pointsHeight: 0, scale: 2) == nil, "zero view is not a drawable")
  check(GlassesDrawable.pixels(pointsWidth: 10, pointsHeight: 10, scale: 1) == nil, "tiny view is not 2x2")
  check(GlassesDrawable.pixels(pointsWidth: 100, pointsHeight: 100, scale: 0) == nil, "zero scale is not a drawable")
}

private func testSession() {
  var session = GlassesSession()
  let missing = session.transition(.play(displays: [], captureRunning: false))
  check(missing.effects == [.noDisplay] && !missing.session.isOn, "play with no display stays off")

  let player = session.transition(.play(displays: [glasses], captureRunning: false))
  check(player.session.source == .player && player.effects == [.pinPlayer(glasses)], "play sends the player")
  session = player.session

  let exitPlayer = session.transition(.exit)
  check(exitPlayer.session.output == .off && exitPlayer.effects == [.unpinPlayer], "exit leaves the player")
  session = exitPlayer.session

  let capturePlay = session.transition(.play(displays: [glasses], captureRunning: true))
  check(capturePlay.session.source == .capture && capturePlay.effects == [.pinCapture(glasses)], "play during capture sends the capture")
  session = capturePlay.session

  let startedAgain = session.transition(.captureStarted(displays: [glasses]))
  check(startedAgain.effects.isEmpty && startedAgain.session.source == .capture, "capture start while already showing capture does not pin twice")

  let stopped = startedAgain.session.transition(.captureStopped)
  check(stopped.session.output == .off && stopped.effects == [.unpinCapture], "stopping capture leaves the glasses")

  session = GlassesSession()
  session = session.transition(.play(displays: [glasses], captureRunning: false)).session
  let takeover = session.transition(.captureStarted(displays: [glasses]))
  check(
    takeover.session.source == .capture && takeover.session.restorePlayer
      && takeover.effects == [.pinCapture(glasses), .unpinPlayer],
    "capture start replaces the player on the glasses"
  )
  let restored = takeover.session.transition(.captureStopped)
  check(
    restored.session.source == .player && !restored.session.restorePlayer
      && restored.effects == [.unpinCapture, .pinPlayer(glasses)],
    "stopping capture restores the player"
  )

  var off = GlassesSession()
  let auto = off.transition(.captureStarted(displays: [glasses]))
  check(auto.session.source == .capture && auto.effects == [.pinCapture(glasses)], "capture start with glasses connected pins capture")
  off = off.transition(.captureStarted(displays: [])).session
  check(!off.isOn && off.captureRunning, "capture start without glasses stays a preview")

  var showing = GlassesSession()
  showing = showing.transition(.play(displays: [glasses], captureRunning: true)).session
  let menuExit = showing.transition(.play(displays: [glasses], captureRunning: true))
  check(menuExit.session.output == .off && menuExit.effects == [.unpinCapture], "play toggles capture off the glasses")
}

private func testWindowMatch() {
  let track = CaptureTrack(
    kind: .window,
    windowID: 145,
    title: "Me at the zoo - YouTube",
    owner: "Google Chrome",
    bundleID: "com.google.Chrome",
    displayID: 2
  )
  let same = chrome(145, title: "Me at the zoo - YouTube", width: 1400, height: 900, onScreen: true)
  check(CaptureWindowMatch.decide(track: track, windows: [same], displayIDs: [1, 2]) == .keep, "the same window id stays")

  let fullscreen = chrome(900, title: "YouTube", width: 1512, height: 982, onScreen: false)
  let gone = CaptureWindowMatch.decide(track: track, windows: [fullscreen], displayIDs: [1, 2])
  if case .window(let found, let reason) = gone {
    check(found.id == 900 && reason.contains("largest"), "fullscreen title change follows the largest Chrome window")
  } else {
    check(false, "fullscreen title change follows the largest Chrome window")
  }

  let none = CaptureWindowMatch.decide(track: track, windows: [], displayIDs: [1, 2])
  if case .display(let id, let reason) = none {
    check(id == 2 && reason.contains("display 2"), "no Chrome window falls back to the screen it was on")
  } else {
    check(false, "no Chrome window falls back to the screen it was on")
  }

  let small = chrome(10, title: "New Tab", width: 800, height: 600, onScreen: true)
  let big = chrome(11, title: "Other", width: 1400, height: 900, onScreen: true)
  let tracked = CaptureTrack(kind: .window, windowID: 10, title: "New Tab", owner: "Google Chrome", bundleID: "com.google.Chrome", displayID: 2)
  check(
    CaptureWindowMatch.decide(track: tracked, windows: [small, big], displayIDs: [2]) == .keep,
    "a larger Chrome window does not steal a window that is still there"
  )

  let offscreen = chrome(10, title: "New Tab", width: 800, height: 600, onScreen: false)
  let moved = CaptureWindowMatch.decide(track: tracked, windows: [offscreen, big], displayIDs: [2])
  if case .window(let found, _) = moved {
    check(found.id == 11, "an off-screen window yields to the largest Chrome window")
  } else {
    check(false, "an off-screen window yields to the largest Chrome window")
  }

  let displays = [
    (id: UInt32(1), frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
    (id: UInt32(2), frame: CGRect(x: 1512, y: 0, width: 3840, height: 1080))
  ]
  let onBuiltIn = CaptureWindowMatch.displayID(covering: CGRect(x: 100, y: 100, width: 800, height: 600), displays: displays)
  check(onBuiltIn == 1, "a window is matched to the display it overlaps")
  let onGlasses = CaptureWindowMatch.displayID(covering: CGRect(x: 2000, y: 10, width: 1200, height: 800), displays: displays)
  check(onGlasses == 2, "a window on the glasses display is matched there")

  var displayTrack = track
  displayTrack.kind = .display
  displayTrack.windowID = 0
  let back = CaptureWindowMatch.decide(track: displayTrack, windows: [fullscreen], displayIDs: [2])
  if case .window(let found, _) = back {
    check(found.id == 900, "whole-display fallback returns to a Chrome window when one exists")
  } else {
    check(false, "whole-display fallback returns to a Chrome window when one exists")
  }
}

private func testContentRect() {
  let player = StereoOffscreen.contentRect(outputWidth: 3840, outputHeight: 1080, contentAspect: 16.0 / 9.0, fullSizeEyes: true, colorIsPicture: false)
  check(abs(player.x - 0.25) < 0.001 && abs(player.w - 0.5) < 0.001, "player 16:9 sits in the center of 3840x1080")
  let capture = StereoOffscreen.contentRect(outputWidth: 3840, outputHeight: 1080, contentAspect: 16.0 / 9.0, fullSizeEyes: true, colorIsPicture: true)
  check(capture == StereoOffscreen.fullPicture, "capture samples the whole picture into each eye")
  let half = StereoOffscreen.contentRect(outputWidth: 1920, outputHeight: 1080, contentAspect: 16.0 / 9.0, fullSizeEyes: false, colorIsPicture: false)
  check(half == StereoOffscreen.fullPicture, "1920x1080 glasses sample the full framebuffer")
}

private func texture(_ device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat, usage: MTLTextureUsage, shared: Bool) -> MTLTexture? {
  let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
  desc.usage = usage
  desc.storageMode = shared ? .shared : .private
  return device.makeTexture(descriptor: desc)
}

private func testStereoPipeline() {
  guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    check(false, "Metal device is available")
    return
  }
  let libraryURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CAPTURE_METALLIB"] ?? "")
  guard let library = try? device.makeLibrary(URL: libraryURL),
        let function = library.makeFunction(name: "immersiveStereo"),
        let pipeline = try? device.makeComputePipelineState(function: function) else {
    check(false, "immersiveStereo loaded from \(libraryURL.path)")
    return
  }

  let sourceWidth = 320
  let sourceHeight = 180
  var pixelBuffer: CVPixelBuffer?
  let created = CVPixelBufferCreate(
    kCFAllocatorDefault,
    sourceWidth,
    sourceHeight,
    kCVPixelFormatType_32BGRA,
    [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
    &pixelBuffer
  )
  guard created == kCVReturnSuccess, let pixelBuffer else {
    check(false, "synthetic pixel buffer")
    return
  }
  guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
    check(false, "pixel buffer lock")
    return
  }
  let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
  let pixels = base.assumingMemoryBound(to: UInt8.self)
  for y in 0..<sourceHeight {
    for x in 0..<sourceWidth {
      let offset = y * rowBytes + x * 4
      let red = x < sourceWidth / 2
      pixels[offset] = red ? 0 : 255
      pixels[offset + 1] = 0
      pixels[offset + 2] = red ? 255 : 0
      pixels[offset + 3] = 255
    }
  }
  CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

  var cache: CVMetalTextureCache?
  guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
    check(false, "metal texture cache")
    return
  }
  var cvTexture: CVMetalTexture?
  let textureResult = CVMetalTextureCacheCreateTextureFromImage(
    kCFAllocatorDefault,
    cache,
    pixelBuffer,
    nil,
    .bgra8Unorm,
    sourceWidth,
    sourceHeight,
    0,
    &cvTexture
  )
  guard textureResult == kCVReturnSuccess, let cvTexture, let color = CVMetalTextureGetTexture(cvTexture) else {
    check(false, "pixel buffer became a texture")
    return
  }
  guard let depth = texture(device, width: 2, height: 2, format: .r32Float, usage: [.shaderRead], shared: true),
        let output = texture(device, width: 3840, height: 1080, format: .bgra8Unorm, usage: [.shaderWrite], shared: true) else {
    check(false, "depth and 3840x1080 output textures")
    return
  }
  let flat = [Float](repeating: 0.5, count: 4)
  flat.withUnsafeBytes { raw in
    depth.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: 8)
  }
  let rect = StereoOffscreen.contentRect(outputWidth: 3840, outputHeight: 1080, contentAspect: 16.0 / 9.0, fullSizeEyes: true, colorIsPicture: true)
  let params = StereoOffscreen.Params(
    maxShift: 0.03,
    convergence: 0.5,
    holeThreshold: 0.08,
    invertDepth: 0,
    glOriented: 0,
    searchPixels: 18,
    contentX: rect.x,
    contentY: rect.y,
    contentW: rect.w,
    contentH: rect.h
  )
  let encoded = StereoOffscreen.encode(commandQueue: queue, pipeline: pipeline, color: color, depth: depth, output: output, params: params)
  check(encoded, "stereo encode of a synthetic frame")
  guard encoded else { return }

  var bytes = [UInt8](repeating: 0, count: 3840 * 1080 * 4)
  bytes.withUnsafeMutableBytes { raw in
    output.getBytes(raw.baseAddress!, bytesPerRow: 3840 * 4, from: MTLRegionMake2D(0, 0, 3840, 1080), mipmapLevel: 0)
  }
  func sample(_ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int) {
    let offset = (y * 3840 + x) * 4
    return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
  }
  func bright(_ pixel: (b: Int, g: Int, r: Int)) -> Bool {
    max(pixel.r, pixel.g, pixel.b) > 40
  }
  let leftRed = sample(480, 540)
  let leftBlue = sample(1440, 540)
  let rightRed = sample(1920 + 480, 540)
  let rightBlue = sample(1920 + 1440, 540)
  check(bright(leftRed) && bright(leftBlue) && bright(rightRed) && bright(rightBlue), "3840x1080 SBS is non-black in both eyes")
  check(leftRed.r > 200 && leftRed.b < 40, "left eye shows the red half of the picture")
  check(leftBlue.b > 200 && leftBlue.r < 40, "left eye shows the blue half of the picture")
  check(rightRed.r > 200 && rightRed.b < 40, "right eye shows the red half of the picture")
  check(rightBlue.b > 200 && rightBlue.r < 40, "right eye shows the blue half of the picture")
  let mean = bytes.enumerated().reduce(0) { partial, item in
    partial + (item.offset % 4 == 3 ? 0 : Int(item.element))
  }
  check(mean > 1000, "mean channel sum is not a black frame (\(mean))")
}

@main
enum CaptureSelfTest {
  static func main() {
    testDrawable()
    testSession()
    testWindowMatch()
    testContentRect()
    testStereoPipeline()
    if failures == 0 {
      print("browser capture self-test passed")
    } else {
      print("browser capture self-test failed: \(failures)")
      exit(1)
    }
  }
}
