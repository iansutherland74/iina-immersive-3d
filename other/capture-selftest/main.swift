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

private func follow(
  track: CaptureTrack,
  windows: [CaptureWindowRecord],
  displays: [UInt32] = [1, 2],
  now: TimeInterval,
  clock: CaptureFollowClock
) -> CaptureFollowOutcome {
  CaptureWindowMatch.decide(track: track, windows: windows, displayIDs: displays, now: now, clock: clock)
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
  check(follow(track: track, windows: [same], now: 0, clock: .empty).decision == .keep, "the same window id stays")

  let shadow = chrome(2003, title: "", width: 1512, height: 982, onScreen: true)
  let offscreen = chrome(145, title: "Me at the zoo - YouTube", width: 1512, height: 982, onScreen: false)
  var clock = CaptureFollowClock.empty
  var flipped = false
  for tick in stride(from: 0.0, through: 3.0, by: 0.5) {
    let outcome = follow(track: track, windows: [offscreen, shadow], now: tick, clock: clock)
    clock = outcome.clock
    if outcome.decision != .keep { flipped = true }
  }
  check(!flipped, "an off-screen YouTube window is not replaced by an untitled Chrome window")
  check(CaptureWindowMatch.isPlaceholder(shadow), "an untitled window is a placeholder")
  check(!CaptureWindowMatch.isPlaceholder(offscreen), "a titled full-screen window is not a placeholder")

  let tiny = chrome(2004, title: "YouTube", width: 80, height: 80, onScreen: true)
  check(CaptureWindowMatch.isPlaceholder(tiny), "a tiny window is a placeholder")

  clock = .empty
  let missingSoon = follow(track: track, windows: [shadow], now: 10, clock: clock)
  check(missingSoon.decision == .keep && missingSoon.clock.absentSince == 10, "a missing window waits before the filter changes")
  let stillWaiting = follow(track: track, windows: [shadow], now: 11.5, clock: missingSoon.clock)
  check(stillWaiting.decision == .keep, "1.5 seconds is not long enough to leave the window")
  let titled = chrome(900, title: "YouTube", width: 1512, height: 982, onScreen: false)
  let switched = follow(track: track, windows: [shadow, titled], now: 11.6, clock: stillWaiting.clock)
  if case .window(let found, _) = switched.decision {
    check(found.id == 900, "after 1.5 seconds the titled window is followed, not the untitled one")
  } else {
    check(false, "after 1.5 seconds the titled window is followed, not the untitled one")
  }
  var followed = track
  followed.windowID = 900
  followed.title = "YouTube"
  let stayed = follow(track: followed, windows: [offscreen, shadow, titled], now: 12.1, clock: switched.clock)
  check(stayed.decision == .keep, "the follow does not switch back to the previous window")

  let onlyShadow = follow(track: track, windows: [shadow], now: 20, clock: CaptureFollowClock(absentSince: 10, departedID: 0, departedAt: 0))
  if case .display(let id, let reason) = onlyShadow.decision {
    check(id == 2 && reason.contains("display 2"), "no real Chrome window falls back to the screen it was on")
  } else {
    check(false, "no real Chrome window falls back to the screen it was on")
  }

  let small = chrome(10, title: "New Tab", width: 800, height: 600, onScreen: true)
  let big = chrome(11, title: "Other", width: 1400, height: 900, onScreen: true)
  let tracked = CaptureTrack(kind: .window, windowID: 10, title: "New Tab", owner: "Google Chrome", bundleID: "com.google.Chrome", displayID: 2)
  check(
    follow(track: tracked, windows: [small, big], now: 0, clock: .empty).decision == .keep,
    "a larger Chrome window does not steal a window that is still there"
  )
  let hidden = chrome(10, title: "New Tab", width: 800, height: 600, onScreen: false)
  check(
    follow(track: tracked, windows: [hidden, big], now: 0, clock: .empty).decision == .keep,
    "leaving the current screen does not drop a window that still exists"
  )

  let placeholder = chrome(2003, title: " ", width: 1400, height: 900, onScreen: true)
  let stuck = CaptureTrack(kind: .window, windowID: 2003, title: "Me at the zoo - YouTube", owner: "Google Chrome", bundleID: "com.google.Chrome", displayID: 2)
  let escaped = follow(track: stuck, windows: [placeholder, offscreen], now: 0, clock: .empty)
  if case .window(let found, _) = escaped.decision {
    check(found.id == 145, "an untitled window gives way to the titled YouTube window")
  } else {
    check(false, "an untitled window gives way to the titled YouTube window")
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
  let back = follow(track: displayTrack, windows: [titled, shadow], now: 0, clock: .empty)
  if case .window(let found, _) = back.decision {
    check(found.id == 900, "whole-display fallback returns to a titled Chrome window")
  } else {
    check(false, "whole-display fallback returns to a titled Chrome window")
  }
  let shadowOnly = follow(track: displayTrack, windows: [shadow], now: 0, clock: .empty)
  check(shadowOnly.decision == .keep, "an untitled window does not end whole-display capture")
}

private func testDrawableLock() {
  let builtIn = GlassesDrawable.lockedPixels(lockedWidth: 3840, lockedHeight: 1080, interimWidth: 3024, interimHeight: 1964)
  check(builtIn.width == 3840 && builtIn.height == 1080, "a Space change does not adopt the Mac screen")
  let partial = GlassesDrawable.lockedPixels(lockedWidth: 3840, lockedHeight: 1080, interimWidth: 3840, interimHeight: 1027)
  check(partial.width == 3840 && partial.height == 1080, "a half-moved frame does not shrink the glasses drawable")
  check(GlassesDrawable.presentFit(textureWidth: 1920, textureHeight: 1080, drawableWidth: 3024, drawableHeight: 1964) == .scale, "a size mismatch is scaled")
  check(GlassesDrawable.presentFit(textureWidth: 3840, textureHeight: 1080, drawableWidth: 3840, drawableHeight: 1080) == .blit, "a matching drawable is blitted")
  check(GlassesDrawable.presentFit(textureWidth: 2, textureHeight: 2, drawableWidth: 3840, drawableHeight: 1080) == .drop, "a 2x2 texture is not presented")
}

private func testCoalescer() {
  var gate = CaptureFrameCoalescer()
  check(gate.arrive() == 1 && gate.arrive() == 2 && gate.arrive() == 3, "three frames arrived")
  check(gate.takeForDraw() == 3, "the draw takes the newest frame")
  check(gate.arrive() == 4 && gate.arrive() == 5, "later frames replace the one in flight")
  check(gate.finishDraw() == 5, "the next draw is the newest frame that arrived")
  check(gate.finishDraw() == nil && !gate.drawing, "an idle draw queue waits")
  check(CaptureLatency.milliseconds(received: 10, presented: 10.042) == 42, "capture latency is the present time minus the copy time")
  var smooth = CaptureLatencySmooth()
  let normal = smooth.observe(0.012)
  check(abs(normal - 0.012) < 0.001, "a 12 ms delay is kept")
  let spike = smooth.observe(0.575)
  check(abs(spike - normal) < 0.001, "a 575 ms stall does not move the audio delay")
  check(abs(smooth.observe(0.181) - normal) < 0.001, "a 181 ms stall does not move the audio delay")
  check(!CapturePresentBudget.shouldPresent(age: 0.575, newerWaiting: true), "a late frame is dropped when a newer one is waiting")
  check(!CapturePresentBudget.shouldPresent(age: 0.213, newerWaiting: true), "a 213 ms frame is dropped when a newer one is waiting")
  check(CapturePresentBudget.shouldPresent(age: 0.012, newerWaiting: true), "a fresh frame is presented")
  check(CapturePresentBudget.shouldPresent(age: 0.575, newerWaiting: false), "the only frame is still presented")
}

private func testQuitDuringCapture() {
  var pool = CaptureDrawableGuard()
  check(pool.requestResize(), "the first drawable size is applied before any drawable exists")
  pool.noteDrawable()
  pool.endSameTurn()
  pool.noteDrawable()
  check(!pool.requestResize(), "quit does not resize while the Apple Event pool holds a drawable")
  check(!pool.appliedOnThisTurn, "that resize is not applied in the quit turn")
  pool.endSameTurn()
  check(pool.nextTurn(), "the resize runs on the next turn, after the pool pops")
  var early = CaptureDrawableGuard()
  early.noteDrawable()
  early.endSameTurn()
  check(!early.requestResize(), "ending a present does not resize in that same turn")
  check(early.nextTurn(), "the deferred resize runs after the pool pops")
}

private func testAudioPolicy() {
  check(!CaptureAudioPolicy.shouldCaptureAudio(userEnabled: false, virtualDevicePresent: true), "ScreenCaptureKit audio stays off")
  check(!CaptureAudioPolicy.shouldCaptureAudio(userEnabled: true, virtualDevicePresent: true), "ScreenCaptureKit audio stays off so the loopback is the only copy")
  check(!CaptureAudioPolicy.shouldRouteLoopback(userEnabled: false, deviceInstalled: true), "the loopback stays off when the toggle is off")
  check(!CaptureAudioPolicy.shouldRouteLoopback(userEnabled: true, deviceInstalled: false), "the loopback stays off until the device is installed")
  check(CaptureAudioPolicy.shouldRouteLoopback(userEnabled: true, deviceInstalled: true), "the loopback runs when the toggle is on and the device is installed")
  check(CaptureAudioPolicy.looksVirtual(name: "BlackHole 2ch", uid: "BlackHole2ch_UID"), "BlackHole is a virtual device")
  check(CaptureAudioPolicy.looksVirtual(name: "IINA Capture Audio", uid: "IINACaptureAudio_UID"), "the bundled device is virtual")
  check(!CaptureAudioPolicy.looksVirtual(name: "MacBook Pro Speakers", uid: "BuiltInSpeakerDevice"), "the built-in speakers are not a virtual device")
}

private func testRoute() {
  let speakers = CaptureOutputRoute.Snapshot(outputUID: "BuiltInSpeakerDevice", mpvDevice: "auto")
  var state = CaptureOutputRoute.State()
  let off = CaptureOutputRoute.engage(state: state, capturing: true, enabled: false, installed: true, current: speakers, fallbackRealUID: nil)
  check(off.effects.isEmpty && off.state.phase == .idle, "the toggle off does not change the output")
  let idle = CaptureOutputRoute.engage(state: state, capturing: false, enabled: true, installed: true, current: speakers, fallbackRealUID: nil)
  check(idle.effects.isEmpty, "the toggle does nothing until a capture is running")
  let missing = CaptureOutputRoute.engage(state: state, capturing: true, enabled: true, installed: false, current: speakers, fallbackRealUID: nil)
  check(missing.effects.isEmpty, "a missing device does not change the output")
  let on = CaptureOutputRoute.engage(state: state, capturing: true, enabled: true, installed: true, current: speakers, fallbackRealUID: nil)
  check(on.began == .routed, "capture routes the browser")
  check(on.effects == [
    .writeCrashFile("BuiltInSpeakerDevice"),
    .setMPVDevice("coreaudio/BuiltInSpeakerDevice"),
    .setSystemOutput(CaptureOutputRoute.virtualUID)
  ], "the player is pinned before the system output changes")
  state = on.state
  let again = CaptureOutputRoute.engage(state: state, capturing: true, enabled: true, installed: true, current: speakers, fallbackRealUID: nil)
  check(again.effects.isEmpty && again.began == .already, "a second start does not forget the saved output")
  let stopped = CaptureOutputRoute.end(state: state)
  check(stopped.effects == [
    .setSystemOutput("BuiltInSpeakerDevice"),
    .setMPVDevice("auto"),
    .deleteCrashFile
  ], "stopping restores the output and the player device")
  check(stopped.state.crashUID == nil, "the route is idle after restore")
  let recovered = CaptureOutputRoute.recover(state: CaptureOutputRoute.State(crashUID: "BuiltInSpeakerDevice"))
  check(recovered.effects == [
    .setSystemOutput("BuiltInSpeakerDevice"),
    .deleteCrashFile
  ], "launch restores the output saved before a crash")
  let virtualNow = CaptureOutputRoute.Snapshot(outputUID: CaptureOutputRoute.virtualUID, mpvDevice: "auto")
  let resume = CaptureOutputRoute.engage(
    state: CaptureOutputRoute.State(crashUID: "BuiltInSpeakerDevice"),
    capturing: true,
    enabled: true,
    installed: true,
    current: virtualNow,
    fallbackRealUID: "Headphones"
  )
  if case .routed(let saved, _) = resume.state.phase {
    check(saved.outputUID == "BuiltInSpeakerDevice", "the saved speakers are kept, not the virtual device")
  } else {
    check(false, "the saved speakers are kept, not the virtual device")
  }
  check(resume.effects.first == .writeCrashFile("BuiltInSpeakerDevice"), "the crash file is written before the switch")
  let fallback = CaptureOutputRoute.engage(
    state: CaptureOutputRoute.State(),
    capturing: true,
    enabled: true,
    installed: true,
    current: virtualNow,
    fallbackRealUID: "Headphones"
  )
  if case .routed(let saved, _) = fallback.state.phase {
    check(saved.outputUID == "Headphones", "a real device is used when the default is already virtual")
  } else {
    check(false, "a real device is used when the default is already virtual")
  }
  let stuck = CaptureOutputRoute.engage(
    state: CaptureOutputRoute.State(),
    capturing: true,
    enabled: true,
    installed: true,
    current: virtualNow,
    fallbackRealUID: nil
  )
  check(stuck.effects.isEmpty, "there is no switch when every device is the virtual one")
  let quiet = CaptureOutputRoute.end(state: CaptureOutputRoute.State())
  check(quiet.effects.isEmpty, "stopping when nothing was routed does not touch the output")
  let chunk = CaptureLoopbackClock.Chunk(hostTime: 10, duration: 0.02)
  check(CaptureLoopbackClock.decide(chunk: chunk, now: 10, delay: 0.08) == .wait, "loopback waits for the picture")
  check(CaptureLoopbackClock.decide(chunk: chunk, now: 10.08, delay: 0.08) == .play, "loopback plays when the picture catches up")
  check(CaptureLoopbackClock.decide(chunk: chunk, now: 10.40, delay: 0.08) == .drop, "late loopback audio is dropped")
  check(CaptureSyncOffset.clamp(800) == 500 && CaptureSyncOffset.clamp(-800) == -500, "the sync offset stays inside ±500 ms")
  check(CaptureSyncOffset.label(ms: 40) == "Audio sync +40 ms", "a positive offset shows a plus")
  check(CaptureSyncOffset.label(ms: -15) == "Audio sync -15 ms", "a negative offset shows a minus")
  check(CaptureSyncOffset.label(ms: 0) == "Audio sync 0 ms", "zero offset is labeled")
  check(abs(CaptureSyncOffset.delay(automatic: 0.020, offsetMs: 40) - 0.060) < 0.0001, "the slider adds to the measured delay")
  check(abs(CaptureSyncOffset.delay(automatic: 0.020, offsetMs: -500) - (-0.480)) < 0.0001, "a negative offset plays earlier than the measured delay")
  let early = CaptureLoopbackClock.decide(chunk: CaptureLoopbackClock.Chunk(hostTime: 1, duration: 0.01), now: 1, delay: -0.04)
  check(early == .play, "a negative sync offset can play as soon as the chunk is due")
  let matched = [
    CaptureDefaultOutput.Write(status: 0, readBack: 7),
    CaptureDefaultOutput.Write(status: 0, readBack: 7)
  ]
  check(CaptureDefaultOutput.accepted(deviceID: 7, writes: matched), "both default outputs must read back as the device that was set")
  let missed = [
    CaptureDefaultOutput.Write(status: 0, readBack: 7),
    CaptureDefaultOutput.Write(status: 0, readBack: 4)
  ]
  check(!CaptureDefaultOutput.accepted(deviceID: 7, writes: missed), "a read-back that does not match is not success")
  let failed = [
    CaptureDefaultOutput.Write(status: 1852797029, readBack: 0),
    CaptureDefaultOutput.Write(status: 0, readBack: 7)
  ]
  check(!CaptureDefaultOutput.accepted(deviceID: 7, writes: failed), "a failed OSStatus is not success")
  check(CaptureDefaultOutput.statusText(0) == "0", "noErr is logged as 0")
  check(CaptureDefaultOutput.statusText(1852797029) == "1852797029 'nope'", "the OSStatus fourcc is logged")
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

private func fill(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) {
  guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
  let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
  let pixels = base.assumingMemoryBound(to: UInt8.self)
  for y in 0..<height {
    for x in 0..<width {
      let offset = y * rowBytes + x * 4
      let red = x < width / 2
      pixels[offset] = red ? 0 : 255
      pixels[offset + 1] = 0
      pixels[offset + 2] = red ? 255 : 0
      pixels[offset + 3] = 255
    }
  }
  CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
}

private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
  var pixelBuffer: CVPixelBuffer?
  let created = CVPixelBufferCreate(
    kCFAllocatorDefault,
    width,
    height,
    kCVPixelFormatType_32BGRA,
    [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
    &pixelBuffer
  )
  guard created == kCVReturnSuccess else { return nil }
  return pixelBuffer
}

private func testTextureLifetime() {
  guard let device = MTLCreateSystemDefaultDevice() else {
    check(false, "Metal device is available for the texture lifetime")
    return
  }
  var cache: CVMetalTextureCache?
  guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
    check(false, "texture cache for the lifetime loop")
    return
  }
  var survived = true
  for _ in 0..<40 {
    autoreleasepool {
      guard let pixelBuffer = makeBuffer(width: 320, height: 180) else {
        survived = false
        return
      }
      fill(pixelBuffer, width: 320, height: 180)
      guard let made = CaptureTextureLifetime.make(cache: cache, pixelBuffer: pixelBuffer, width: 320, height: 180) else {
        survived = false
        return
      }
      var holder: CVMetalTexture? = made.holder
      var texture: MTLTexture? = made.texture
      if texture?.width != 320 { survived = false }
      CaptureTextureLifetime.recycle(holder: &holder, texture: &texture, cache: cache, flush: true)
    }
  }
  check(survived, "texture create and flush survives an autorelease pool")
}

private func testScale() {
  guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    check(false, "Metal device is available for scaling")
    return
  }
  let libraryURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CAPTURE_METALLIB"] ?? "")
  guard let library = try? device.makeLibrary(URL: libraryURL),
        let function = library.makeFunction(name: "immersiveScaleRGBA"),
        let pipeline = try? device.makeComputePipelineState(function: function) else {
    check(false, "immersiveScaleRGBA loaded")
    return
  }
  guard let pixelBuffer = makeBuffer(width: 1920, height: 1080) else {
    check(false, "1920x1080 source buffer")
    return
  }
  fill(pixelBuffer, width: 1920, height: 1080)
  var cache: CVMetalTextureCache?
  guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache,
        let made = CaptureTextureLifetime.make(cache: cache, pixelBuffer: pixelBuffer, width: 1920, height: 1080) else {
    check(false, "1920x1080 texture")
    return
  }
  var holder: CVMetalTexture? = made.holder
  var source: MTLTexture? = made.texture
  defer { CaptureTextureLifetime.recycle(holder: &holder, texture: &source, cache: cache, flush: true) }
  guard let source, let destination = texture(device, width: 3840, height: 1080, format: .bgra8Unorm, usage: [.shaderWrite], shared: true) else {
    check(false, "3840x1080 scale destination")
    return
  }
  check(StereoOffscreen.scale(commandQueue: queue, pipeline: pipeline, source: source, destination: destination), "scale 1920x1080 onto 3840x1080")
  var pixel = [UInt8](repeating: 0, count: 4)
  func read(_ x: Int) -> (b: Int, r: Int) {
    pixel.withUnsafeMutableBytes { raw in
      destination.getBytes(raw.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(x, 540, 1, 1), mipmapLevel: 0)
    }
    return (Int(pixel[0]), Int(pixel[2]))
  }
  let left = read(480)
  let right = read(3360)
  check(left.r > 200 && left.b < 40 && right.b > 200 && right.r < 40, "scaled 3840x1080 keeps both halves of the picture")
}

@main
enum CaptureSelfTest {
  static func main() {
    testDrawable()
    testDrawableLock()
    testSession()
    testWindowMatch()
    testCoalescer()
    testQuitDuringCapture()
    testAudioPolicy()
    testRoute()
    testContentRect()
    let zombies = ProcessInfo.processInfo.environment["CAPTURE_ZOMBIES"] == "1"
    if !zombies {
      testStereoPipeline()
      testScale()
    }
    testTextureLifetime()
    if failures == 0 {
      print("browser capture self-test passed")
    } else {
      print("browser capture self-test failed: \(failures)")
      exit(1)
    }
  }
}

