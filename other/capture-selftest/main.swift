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
  var slots = CapturePresentSlots()
  check(CapturePresentSlots.count >= 3, "a stereo pass, a blit, and a waiting frame each have a slot")
  check(slots.offer(0) == nil, "the first finished frame waits to present")
  check(slots.offer(1) == 0, "a newer frame frees the slot that was still waiting")
  check(slots.pending == 1, "the present keeps the newest frame")
  let group = StereoOffscreen.threadgroupSize(maxThreads: 32, width: 3840, height: 1080)
  check(group.width * group.height <= 32 && group.width >= 1 && group.height >= 1, "the stereo threadgroup fits a 32-thread pipeline")
  let wide = StereoOffscreen.threadgroupSize(maxThreads: 1024, width: 3840, height: 1080)
  check(wide.width == 16 && wide.height == 16, "a 1024-thread pipeline keeps a 16 by 16 threadgroup")
}

private func testStagePool() {
  var pool = CaptureStagePool()
  guard let first = pool.acquire(now: 0) else {
    check(false, "the first stage slot is free")
    return
  }
  _ = pool.enqueue(first)
  guard let second = pool.acquire(now: 0.2) else {
    check(false, "a second slot is free while one frame is queued")
    return
  }
  check(second.index != first.index, "a queued frame is not handed out again")
  let waiting = pool.takeForPresent()
  check(waiting == first, "the queued frame is the one that presents")
  guard let third = pool.acquire(now: 0.4) else {
    check(false, "the third slot is free while one frame is presenting")
    return
  }
  check(third.index != first.index && third.index != second.index, "the presenting frame keeps its own slot")
  check(pool.age(of: first.index, now: 5) > 1, "the presenting slot has been held for more than a second")
  check(pool.acquire(now: 5) == nil, "a presenting slot is not reclaimed after one second")
  check(pool.release(second), "the stereo slot is released when that pass finishes")
  guard let reused = pool.acquire(now: 5.1) else {
    check(false, "a released slot can be used for the next frame")
    return
  }
  check(reused.index == second.index, "the finished slot is the one that is reused")
  check(pool.release(first), "the present releases its slot when the blit finishes")
  guard let afterPresent = pool.acquire(now: 6) else {
    check(false, "a presented slot can be used again")
    return
  }
  check(afterPresent.index == first.index, "the presented slot is reused only after the blit finishes")
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
  check(CaptureAudioPolicy.Offer.toggleOff.logLine == "routing not started: the toggle is off. Sound stays in the other app.", "the toggle off is logged")
  check(CaptureAudioPolicy.Offer.needsMacOS13.logLine == "routing not started: needs macOS 13. Sound stays in the other app.", "an older system is logged")
  check(CaptureAudioPolicy.Offer.deviceMissing.logLine == "routing not started: IINA Capture Audio was not found. Sound stays in the other app.", "a missing device is logged")
  check(CaptureAudioPolicy.Offer.previousOutputNotSaved.logLine == "routing not started: the previous output could not be saved. Sound stays in the other app.", "a refused switch is logged")
  check(CaptureAudioPolicy.Offer.started.logLine == "routing started: IINA Capture Audio is installed and the toggle is on.", "a started route is logged")
  check(CaptureAudioPolicy.deviceLine(installed: true) == "IINA Capture Audio: found (IINACaptureAudio_UID).", "an installed device is named")
  check(CaptureAudioPolicy.deviceLine(installed: false) == "IINA Capture Audio: not found. Turning the toggle on asks to install it.", "a missing device is named")
  let quiet = CaptureAudioPolicy.statusLine(systemSupportsRouting: true, userEnabled: false, deviceInstalled: true, capturing: true)
  check(quiet.contains("found (IINACaptureAudio_UID)") && quiet.contains("Sound stays in the other app."), "the toggle off still says the device was found and the sound stayed put")
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
  check(CaptureLoopbackClock.decide(chunk: CaptureLoopbackClock.Chunk(hostTime: 10, duration: 0.02), now: 10, delay: 0) == .play, "loopback plays at once before a picture measurement")
  check(CaptureLoopbackClock.decide(chunk: CaptureLoopbackClock.Chunk(hostTime: 10, duration: 0.02), now: 11.2, delay: 0) == .drop, "audio buffered before playback started is dropped")
  check(CaptureLoopbackClock.decide(chunk: CaptureLoopbackClock.Chunk(hostTime: 11.19, duration: 0.02), now: 11.2, delay: 0) == .play, "a new loopback chunk plays without a video measurement")
  check(CaptureSyncOffset.minMs == -500 && CaptureSyncOffset.maxMs == 2000, "audio sync runs from -500 ms to +2000 ms")
  check(CaptureSyncOffset.clamp(2000) == 2000 && CaptureSyncOffset.clamp(2001) == 2000, "positive offset stops at +2000 ms")
  check(CaptureSyncOffset.clamp(-500) == -500 && CaptureSyncOffset.clamp(-800) == -500, "negative offset stops at -500 ms")
  check(CaptureSyncOffset.clamp(800) == 800, "an offset between -500 ms and +2000 ms is kept")
  check(CaptureSyncOffset.label(ms: 40) == "Audio sync +40 ms", "a positive offset shows a plus")
  check(CaptureSyncOffset.label(ms: 2000) == "Audio sync +2000 ms", "a +2000 ms offset shows a plus")
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
  let picture = CaptureSyncOffset.paths(automatic: 0.004, offsetMs: 500)
  check(abs(picture.audioDelay - 0.004) < 0.0001 && abs(picture.videoHold - 0.5) < 0.0001, "a positive offset delays video and leaves the loopback delay")
  let longPicture = CaptureSyncOffset.paths(automatic: 0.004, offsetMs: 2000)
  check(abs(longPicture.audioDelay - 0.004) < 0.0001 && abs(longPicture.videoHold - 2) < 0.0001, "a +2000 ms offset delays video by 2000 ms")
  let overPicture = CaptureSyncOffset.paths(automatic: 0.004, offsetMs: 4000)
  check(abs(overPicture.videoHold - 2) < 0.0001, "video delay stays at 2000 ms")
  let sound = CaptureSyncOffset.paths(automatic: 0.004, offsetMs: -40)
  check(abs(sound.audioDelay - 0.044) < 0.0001 && sound.videoHold == 0, "a negative offset delays audio")
  let farSound = CaptureSyncOffset.paths(automatic: 0.004, offsetMs: -800)
  check(abs(farSound.audioDelay - 0.504) < 0.0001 && farSound.videoHold == 0, "audio delay stays at 500 ms")
  let none = CaptureSyncOffset.paths(automatic: 0.004, offsetMs: 0)
  check(abs(none.audioDelay - 0.004) < 0.0001 && none.videoHold == 0, "zero offset keeps the measured delay")
  check(CaptureSyncOffset.effectLabel(ms: 500) == "Audio sync +500 ms (delays video)", "a positive offset is labeled as delaying video")
  check(CaptureSyncOffset.effectLabel(ms: 2000) == "Audio sync +2000 ms (delays video)", "a +2000 ms offset is labeled as delaying video")
  check(CaptureSyncOffset.effectLabel(ms: 2400) == "Audio sync +2000 ms (delays video)", "a value past +2000 ms is labeled at the cap")
  check(CaptureSyncOffset.effectLabel(ms: -40) == "Audio sync -40 ms (delays audio)", "a negative offset is labeled as delaying audio")
  check(CaptureSyncOffset.effectLabel(ms: 0) == "Audio sync 0 ms", "zero offset names the setting")
  let suggested = CaptureSyncOffset.suggested(currentMs: 100, averageDeltaMs: 450)
  check(suggested.ms == 550 && suggested.raw == 550, "a suggestion inside -500 to +2000 ms is kept")
  let high = CaptureSyncOffset.suggested(currentMs: 1600, averageDeltaMs: 500)
  check(high.ms == 2000 && high.raw == 2100, "a suggestion past +2000 ms is clamped")
  let low = CaptureSyncOffset.suggested(currentMs: -200, averageDeltaMs: -400)
  check(low.ms == -500 && low.raw == -600, "a suggestion past -500 ms is clamped")
}

private func testAVSync() {
  var luma = CaptureLevelEdge(low: 48, high: 110, rise: 45)
  check(!luma.observe(20) && !luma.observe(30), "a dark frame is not a flash")
  check(luma.observe(180), "a luma jump is a flash")
  check(!luma.observe(190), "the flash is counted once")
  check(!luma.observe(40), "the picture has to go dark again")
  check(luma.observe(200), "the next luma jump is a new flash")
  var beep = CaptureLevelEdge(low: 0.008, high: 0.03, rise: 0.02)
  check(!beep.observe(0.001), "silence is not a beep")
  check(beep.observe(0.08), "an RMS jump is a beep")
  check(!beep.observe(0.09), "the beep is counted once")

  var tracker = CaptureAVSyncTracker()
  let hd = CaptureAVSyncFlash(time: 10, captureWidth: 1280, captureHeight: 720, outputWidth: 1920, outputHeight: 1080, mode: "2D")
  check(tracker.addFlash(hd) == nil, "a flash waits for its beep")
  let first = tracker.addBeep(time: 10.5)
  check(first?.deltaMs == 500 && first?.averageMs == 500 && first?.count == 1, "the first flash-to-beep delta is 500 ms")
  check(first?.captureWidth == 1280 && first?.captureHeight == 720 && first?.mode == "2D", "the 720p measurement keeps 2D")
  let uhd = CaptureAVSyncFlash(time: 12, captureWidth: 3840, captureHeight: 2160, outputWidth: 3840, outputHeight: 1080, mode: "3D SBS")
  check(tracker.addFlash(uhd) == nil, "the 4K flash waits for its beep")
  let second = tracker.addBeep(time: 12.25)
  check(second?.deltaMs == 250 && second?.averageMs == 375 && second?.count == 2, "the average covers both flashes")
  check(second?.captureWidth == 3840 && second?.captureHeight == 2160 && second?.mode == "3D SBS", "the 4K measurement keeps 3D SBS")
  var queued = CaptureAVSyncTracker()
  queued.window = 1
  _ = queued.addFlash(CaptureAVSyncFlash(time: 0, captureWidth: 1280, captureHeight: 720, outputWidth: 1920, outputHeight: 1080, mode: "2D"))
  _ = queued.addFlash(CaptureAVSyncFlash(time: 1.25, captureWidth: 1920, captureHeight: 1080, outputWidth: 3840, outputHeight: 1080, mode: "3D SBS"))
  let kept = queued.addBeep(time: 0.125)
  check(kept?.deltaMs == 125 && kept?.captureWidth == 1280, "a beep still matches the flash it belongs to")
  let early = CaptureAVSyncFlash(time: 20, captureWidth: 1920, captureHeight: 1080, outputWidth: 1920, outputHeight: 1080, mode: "3D SBS")
  _ = tracker.addFlash(early)
  let ahead = tracker.addBeep(time: 19.875)
  check(ahead?.deltaMs == -125, "a beep before the flash is a negative delta")

  if let first = first {
    let line720 = CaptureAVSyncLog.line(match: first, currentOffsetMs: 0)
    check(line720.contains("capture=1280x720") && line720.contains("mode=2D") && line720.contains("suggested=+500 ms (delays video)"), "a 720p 2D measurement names the resolution, mode, and video delay")
    let clamped = CaptureAVSyncLog.line(match: first, currentOffsetMs: 1600)
    check(clamped.contains("suggested=+2000 ms") && clamped.contains("clamped from +2100"), "a suggestion past +2000 ms says it was clamped")
    let lowSuggestion = CaptureAVSyncLog.line(match: first, currentOffsetMs: -1200)
    check(lowSuggestion.contains("suggested=-500 ms") && lowSuggestion.contains("clamped from -700"), "a suggestion past -500 ms says it was clamped")
  } else {
    check(false, "a 720p 2D measurement names the resolution, mode, and video delay")
  }
  if let second = second {
    let line4k = CaptureAVSyncLog.line(match: second, currentOffsetMs: 0)
    check(line4k.contains("capture=3840x2160") && line4k.contains("output=3840x1080") && line4k.contains("mode=3D SBS"), "a 4K 3D SBS measurement names the resolution and mode")
  } else {
    check(false, "a 4K 3D SBS measurement names the resolution and mode")
  }

  check(CapturePictureMode.resolve(onGlasses: true, outputWidth: 3840, outputHeight: 1080) == .sideBySide, "3840x1080 is 3D SBS")
  check(CapturePictureMode.resolve(onGlasses: true, outputWidth: 1920, outputHeight: 1080) == .sideBySide, "1920x1080 on the glasses is half side-by-side")
  check(CapturePictureMode.resolve(onGlasses: false, outputWidth: 1920, outputHeight: 1080) == .twoD, "a 1080p preview is 2D")
  check(CapturePictureMode.resolve(onGlasses: false, outputWidth: 1280, outputHeight: 720) == .twoD, "a 720p preview is 2D")
  check(CapturePictureMode.resolve(onGlasses: true, outputWidth: 3840, outputHeight: 2160) == .twoD, "a 16:9 glasses frame is 2D")
  check(CaptureHostClock.secondsPerTick > 0, "mach time converts to seconds")

  var delayed = CaptureVideoDelayQueue()
  delayed.hold = 0.5
  delayed.push(id: 1, received: 0)
  delayed.push(id: 2, received: 0.2)
  delayed.push(id: 3, received: 0.4)
  check(delayed.popDue(now: 0.49) == nil, "a frame waits out the video delay")
  check(delayed.popDue(now: 0.5)?.id == 1, "the frame is drawn once it is old enough")
  check(delayed.popDue(now: 0.9)?.id == 3, "the newest frame that has waited is the one drawn")
  delayed.hold = 0
  delayed.push(id: 4, received: 1)
  delayed.push(id: 5, received: 1.1)
  check(delayed.popDue(now: 1.1)?.id == 5 && delayed.waiting.isEmpty, "without a video delay only the newest frame is kept")
  delayed.hold = 0.5
  delayed.push(id: 6, received: 2)
  delayed.push(id: 7, received: 2.2)
  delayed.flush()
  check(delayed.waiting.isEmpty && delayed.popDue(now: 4) == nil, "flush drops frames still waiting out a video delay")
  delayed.hold = 0
  check(delayed.popDue(now: 4) == nil, "a flushed queue stays empty when the offset is cleared")

  let holdSeconds = Double(CaptureSyncOffset.maxMs) / 1000
  let frames = CaptureVideoDelayQueue.capacity(frameRate: CaptureVideoDelayQueue.captureFrameRate, holdSeconds: holdSeconds)
  check(CaptureVideoDelayQueue.captureFrameRate == 30 && frames == 61, "2000 ms at 30 fps is 60 intervals plus the frame that just became due")
  check(CaptureVideoDelayQueue().cap == frames, "the hold queue cap is that frame count")
  var held = CaptureVideoDelayQueue()
  held.hold = holdSeconds
  held.cap = frames
  let step = 1.0 / CaptureVideoDelayQueue.captureFrameRate
  var kept = true
  for index in 0..<frames {
    if !held.push(id: index, received: Double(index) * step).isEmpty {
      kept = false
    }
  }
  check(kept && held.waiting.count == frames && held.waiting.first?.id == 0, "the queue holds 2000 ms of frames at the capture rate")
  let drawn = held.popDue(now: holdSeconds)
  check(drawn?.id == 0, "the frame that has waited 2000 ms is the one drawn")
  var full = CaptureVideoDelayQueue()
  full.hold = holdSeconds
  full.cap = frames
  for index in 0..<frames {
    _ = full.push(id: index, received: Double(index) * step)
  }
  let overflow = full.push(id: frames, received: Double(frames) * step)
  check(overflow == [0], "a frame past the cap drops the oldest id")
  check(full.waiting.count == frames && full.waiting.first?.id == 1 && full.waiting.last?.id == frames, "the queue stays at its frame cap")
  var burst = CaptureVideoDelayQueue()
  burst.hold = holdSeconds
  burst.cap = frames
  var lastDropped: [Int] = []
  for index in 0..<400 {
    lastDropped = burst.push(id: index, received: Double(index) * step)
  }
  check(burst.waiting.count == frames, "a long capture does not grow the hold queue past the frame cap")
  check(burst.waiting.first?.id == 400 - frames, "frames older than the cap are the ones dropped")
  check(lastDropped == [400 - frames - 1], "each extra frame drops the oldest id so its buffer can be released")
  var replaced = CaptureVideoDelayQueue()
  replaced.hold = 0
  _ = replaced.push(id: 1, received: 0)
  check(replaced.push(id: 2, received: 0.01) == [1], "clearing the video delay returns the frame it replaced")
}

private func testLoopbackOutput() {
  let actions: [CaptureGlassesAudio.Action] = [.playOnGlasses, .exitGlasses, .immersive3DToggle, .screenParameters]
  for action in actions {
    check(CaptureGlassesAudio.routeEffects(for: action).isEmpty, "glasses action \(action) does not move the audio route")
  }
  check(CapturePinnedDeviceHold.keepMPVDevice(routed: true, deviceStillListed: false), "a missing device during capture keeps the mpv pin")
  check(!CapturePinnedDeviceHold.keepMPVDevice(routed: true, deviceStillListed: true), "a device that is still listed is not a hold")
  check(!CapturePinnedDeviceHold.keepMPVDevice(routed: false, deviceStillListed: false), "outside a capture a missing device can fall back to auto")

  let notices: [CaptureOutputWatch.Notice] = [
    .running(false),
    .alive(false),
    .nominalSampleRate(44100),
    .streamFormat(sampleRate: 44100, channels: 8),
    .devicesChanged,
    .defaultOutputChanged,
    .defaultSystemOutputChanged
  ]
  for notice in notices {
    check(CaptureOutputWatch.routeEffects(for: notice).isEmpty, "\(notice.name) does not change the system output or mpv")
  }
  check(CaptureOutputWatch.Notice.devicesChanged.name == "Devices", "device list events are named")
  check(CaptureOutputWatch.Notice.defaultOutputChanged.name == "DefaultOutputDevice", "default output events are named")
  check(CaptureOutputWatch.Notice.streamFormat(sampleRate: 48000, channels: 2).name == "StreamFormat", "format events are named")

  let before = CaptureOutputWatch.Snapshot(deviceID: 4, alive: true, running: true, sampleRate: 48000, channels: 2)
  let stopped = CaptureOutputWatch.Snapshot(deviceID: 4, alive: true, running: false, sampleRate: 48000, channels: 2)
  check(
    CaptureOutputWatch.step(notice: .running(false), applied: before, resolved: stopped, rebuiltRecently: false) == .restart("DeviceIsRunning"),
    "the output proc restarts when the device stops"
  )
  let reappeared = CaptureOutputWatch.Snapshot(deviceID: 11, alive: true, running: false, sampleRate: 44100, channels: 8)
  check(
    CaptureOutputWatch.step(notice: .devicesChanged, applied: before, resolved: reappeared, rebuiltRecently: false) == .restart("Devices"),
    "re-enumeration restarts the output proc on the saved device"
  )
  check(
    CaptureOutputWatch.step(notice: .defaultOutputChanged, applied: before, resolved: reappeared, rebuiltRecently: false) == .restart("DefaultOutputDevice"),
    "a default-device change restarts the saved device and does not select the default"
  )
  check(
    CaptureOutputWatch.step(notice: .streamFormat(sampleRate: 44100, channels: 8), applied: before, resolved: reappeared, rebuiltRecently: false) == .restart("StreamFormat"),
    "a new rate and channel count restarts the output proc"
  )
  let opened = CaptureOutputWatch.Snapshot(deviceID: 11, alive: true, running: true, sampleRate: 44100, channels: 8)
  check(
    CaptureOutputWatch.step(notice: .running(true), applied: opened, resolved: opened, rebuiltRecently: true) == .keep,
    "our own start does not restart again"
  )
  check(
    CaptureOutputWatch.step(notice: .running(false), applied: opened, resolved: opened, rebuiltRecently: true) == .keep,
    "a stop notification that has already recovered does not loop"
  )
  check(
    CaptureOutputWatch.step(notice: .devicesChanged, applied: opened, resolved: opened, rebuiltRecently: true) == .keep,
    "the device-list echo of a restart is ignored"
  )
  check(
    CaptureOutputWatch.step(notice: .devicesChanged, applied: opened, resolved: opened, rebuiltRecently: false) == .restart("Devices"),
    "a later device-list change rebuilds the proc once"
  )
  check(
    CaptureOutputWatch.step(notice: .defaultSystemOutputChanged, applied: opened, resolved: opened, rebuiltRecently: false) == .restart("DefaultSystemOutputDevice"),
    "the system output notification rebuilds the saved device once"
  )
  let retimed = CaptureOutputWatch.Snapshot(deviceID: 11, alive: true, running: true, sampleRate: 96000, channels: 2)
  check(
    CaptureOutputWatch.step(notice: .nominalSampleRate(96000), applied: opened, resolved: retimed, rebuiltRecently: true) == .restart("NominalSampleRate"),
    "a sample-rate change restarts even when a rebuild just happened"
  )
  let reformatted = CaptureOutputWatch.Snapshot(
    deviceID: 11, alive: true, running: true, sampleRate: 44100, channels: 8,
    bits: 24, isFloat: false, bytesPerFrame: 6, nonInterleaved: false
  )
  check(
    CaptureOutputWatch.step(notice: .streamFormat(sampleRate: 44100, channels: 8), applied: opened, resolved: reformatted, rebuiltRecently: true) == .restart("StreamFormat"),
    "a new sample format restarts the output proc"
  )
  check(CaptureOutputWatch.matches(before, CaptureOutputWatch.Snapshot(deviceID: 4, alive: true, running: true, sampleRate: 48000.4, channels: 2)), "half a hertz is the same rate")
  check(!CaptureOutputWatch.matches(before, retimed), "a different device does not match")
  let split = CaptureOutputWatch.Snapshot(deviceID: 4, alive: true, running: true, sampleRate: 48000, channels: 2, nonInterleaved: true)
  check(!CaptureOutputWatch.matches(before, split), "a non-interleaved format is a different stream")

  let stereo = CapturePlaybackRoute.stereoPair(preferred: [1, 2], channels: 2)
  check(stereo.left == 0 && stereo.right == 1, "stereo channels 1 and 2 are the first pair")
  let surround = CapturePlaybackRoute.stereoPair(preferred: [3, 4], channels: 8)
  check(surround.left == 2 && surround.right == 3, "the preferred pair is used on a multi-channel device")
  let fallback = CapturePlaybackRoute.stereoPair(preferred: [0, 0], channels: 2)
  check(fallback.left == 0 && fallback.right == 1, "an empty preferred pair falls back to stereo")
  let monoPair = CapturePlaybackRoute.stereoPair(preferred: [1, 2], channels: 1)
  check(monoPair.left == 0 && monoPair.right == 0, "a mono device mixes to its only channel")
}

private func testLoopbackPlayback() {
  check(CapturePlaybackRoute.uid(restore: "SmartGlasses-DP", pinned: "BuiltInSpeakerDevice") == "SmartGlasses-DP", "playback uses the glasses uid from the restore file")
  check(CapturePlaybackRoute.uid(restore: "  SmartGlasses-DP\n", pinned: nil) == "SmartGlasses-DP", "the restore file uid is trimmed")
  check(CapturePlaybackRoute.uid(restore: "IINACaptureAudio_UID", pinned: "SmartGlasses-DP") == "SmartGlasses-DP", "playback does not target the virtual device")
  check(CapturePlaybackRoute.uid(restore: nil, pinned: "SmartGlasses-DP") == "SmartGlasses-DP", "the pinned uid is used when the restore file is empty")
  check(CapturePlaybackRoute.uid(restore: "", pinned: "IINACaptureAudio_UID") == nil, "there is no playback device when every uid is virtual")

  let glasses441 = CapturePlaybackRoute.plan(sampleRate: 44100, channels: 2, bits: 32, isFloat: true, interleaved: true)
  check(glasses441.resample && glasses441.sampleRate == 44100 && glasses441.channels == 2 && glasses441.encoding == .float32Interleaved, "44.1 kHz glasses are resampled from the 48 kHz loopback")
  let glasses48 = CapturePlaybackRoute.plan(sampleRate: 48000, channels: 2, bits: 32, isFloat: true, interleaved: true)
  check(!glasses48.resample && glasses48.encoding == .float32Interleaved, "48 kHz glasses play the loopback rate directly")
  let int16 = CapturePlaybackRoute.plan(sampleRate: 48000, channels: 2, bits: 16, isFloat: false, interleaved: true)
  check(int16.encoding == .int16Interleaved, "16-bit glasses are converted from float")
  let int32 = CapturePlaybackRoute.plan(sampleRate: 48000, channels: 2, bits: 32, isFloat: false, interleaved: true)
  check(int32.encoding == .int32Interleaved, "32-bit integer glasses are converted from float")
  let int24 = CapturePlaybackRoute.plan(sampleRate: 48000, channels: 2, bits: 24, isFloat: false, interleaved: true, bytesPerFrame: 6)
  check(int24.encoding == .int24Interleaved && int24.bytesPerFrame == 6, "24-bit packed glasses are converted from float")
  let int24wide = CapturePlaybackRoute.plan(sampleRate: 48000, channels: 2, bits: 24, isFloat: false, interleaved: true, bytesPerFrame: 8)
  check(int24wide.encoding == .int24Interleaved && int24wide.bytesPerFrame == 8, "24-bit glasses in a 32-bit word are converted from float")
  let planar = CapturePlaybackRoute.plan(sampleRate: 48000, channels: 2, bits: 32, isFloat: true, interleaved: false)
  check(planar.encoding == .float32Planar, "planar float glasses stay planar")
  check(CaptureRateConvert.int16(0.5) == 16384 && CaptureRateConvert.int16(-1) == -32767, "float samples convert to 16-bit")

  let same = CaptureRateConvert.convert([0.25, -0.25, 0.5, -0.5], channels: 2, fromRate: 48000, toRate: 48000)
  check(same.count == 4 && abs(same[0] - 0.25) < 0.0001 && abs(same[1] + 0.25) < 0.0001, "a matching rate is copied")
  var tone = [Float](repeating: 0, count: 480 * 2)
  for index in 0..<480 {
    let sample = Float(sin(2 * Double.pi * Double(index) / 48))
    tone[index * 2] = sample
    tone[index * 2 + 1] = sample * 0.5
  }
  let converted = CaptureRateConvert.convert(tone, channels: 2, fromRate: 48000, toRate: 44100)
  var energy = 0.0
  for sample in converted {
    energy += Double(sample * sample)
  }
  let mean = energy / Double(max(converted.count, 1))
  check(converted.count > 400 && converted.count < 960 && mean > 0.05, "a 48 kHz tone resampled to 44.1 kHz is not silence")

  check(CaptureDeviceGain.restoredScalar(0) == 1 && CaptureDeviceGain.restoredScalar(0.0001) == 1, "a zero loopback volume is raised to 1")
  check(CaptureDeviceGain.restoredScalar(0.4) == nil, "a non-zero loopback volume is left alone")
  check(CaptureDeviceGain.shouldClearMute(true) && !CaptureDeviceGain.shouldClearMute(false), "a muted loopback device is cleared")
  let handoff = CaptureGlassesAudioHandoff.afterPin(readerRunning: true)
  check(!handoff.stopReader && handoff.reopenOutput, "taking the glasses keeps the reader running and reopens the output")
  let idle = CaptureGlassesAudioHandoff.afterPin(readerRunning: false)
  check(!idle.stopReader && !idle.reopenOutput, "taking the glasses does not start a reader that is not running")

  let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iina-capture-log-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: home) }
  CaptureAudioFileLog.append("loopback reader started device=7 uid=IINACaptureAudio_UID format=48000 Hz 2ch float32", home: home, maxBytes: 120)
  CaptureAudioFileLog.append("loopback in rms=0.2500", home: home, maxBytes: 120)
  let log = CaptureAudioFileLog.fileURL(home: home)
  let first = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
  check(first.contains("loopback reader started") && first.contains("loopback in rms=0.2500"), "loopback lines are written to capture-audio.log")
  for index in 0..<30 {
    CaptureAudioFileLog.append("loopback out rms=0.2500 \(index)", home: home, maxBytes: 120)
  }
  let live = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
  let backupURL = URL(fileURLWithPath: log.path + ".1")
  let backup = (try? String(contentsOf: backupURL, encoding: .utf8)) ?? ""
  let attrs = try? FileManager.default.attributesOfItem(atPath: log.path)
  let liveSize = (attrs?[.size] as? NSNumber)?.intValue ?? (attrs?[.size] as? Int) ?? Int.max
  check(liveSize <= 200 && !backup.isEmpty && (live.contains("loopback out rms=") || backup.contains("loopback reader started")), "capture-audio.log rotates and stays small")

  check(CaptureMicAccess.usageDescriptionPresent(["NSMicrophoneUsageDescription": "IINA reads the loopback"]), "the microphone usage description is present")
  check(!CaptureMicAccess.usageDescriptionPresent(nil) && !CaptureMicAccess.usageDescriptionPresent([:]), "a missing microphone usage description is reported")
  check(!CaptureMicAccess.usageDescriptionPresent(["NSMicrophoneUsageDescription": "  "]), "a blank microphone usage description is missing")
  check(CaptureMicAccess.waitForDecision(.notDetermined), "microphone access is requested before the reader starts")
  check(!CaptureMicAccess.waitForDecision(.authorized) && !CaptureMicAccess.waitForDecision(.denied), "a decided microphone starts the reader without another prompt")
  check(CaptureMicAccess.inputWillBeSilence(.notDetermined) && CaptureMicAccess.inputWillBeSilence(.denied) && CaptureMicAccess.inputWillBeSilence(.restricted), "TCC delivers silence until the microphone is authorized")
  check(!CaptureMicAccess.inputWillBeSilence(.authorized), "an authorized microphone can deliver samples")
  let denied = CaptureMicAccess.logLine(status: .denied, usageDescriptionPresent: true)
  check(denied.contains("loopback mic authorization denied") && denied.contains("usageDescription=present") && denied.contains("input=silence"), "a denied microphone is logged as silence")
  let granted = CaptureMicAccess.logLine(status: .authorized, usageDescriptionPresent: true)
  check(granted.contains("loopback mic authorization authorized") && granted.contains("input=live"), "an authorized microphone is logged as live")
  let missing = CaptureMicAccess.logLine(status: .notDetermined, usageDescriptionPresent: false)
  check(missing.contains("usageDescription=missing") && missing.contains("input=silence"), "a missing usage description is logged as silence")
  if let plistPath = ProcessInfo.processInfo.environment["CAPTURE_INFO_PLIST"],
     let plist = NSDictionary(contentsOfFile: plistPath),
     let text = plist["NSMicrophoneUsageDescription"] as? String {
    check(CaptureMicAccess.usageDescriptionPresent(["NSMicrophoneUsageDescription": text]), "Info.plist has NSMicrophoneUsageDescription")
  } else {
    check(false, "Info.plist has NSMicrophoneUsageDescription")
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
  check(encoded.ok, "stereo encode of a synthetic frame")
  guard encoded.ok else { return }

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

private final class CaptureSendFlag {
  var ok = false
}

/// The capture send path: a private stage texture, the async completion, then the same texture again.
private func testCaptureSend() {
  guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    check(false, "Metal device is available for the capture send")
    return
  }
  let libraryURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CAPTURE_METALLIB"] ?? "")
  guard let library = try? device.makeLibrary(URL: libraryURL),
        let function = library.makeFunction(name: "immersiveStereo"),
        let pipeline = try? device.makeComputePipelineState(function: function) else {
    check(false, "immersiveStereo loaded for the capture send")
    return
  }
  guard let pixelBuffer = makeBuffer(width: 320, height: 180) else {
    check(false, "fake capture frame")
    return
  }
  fill(pixelBuffer, width: 320, height: 180)
  var cache: CVMetalTextureCache?
  guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache,
        let made = CaptureTextureLifetime.make(cache: cache, pixelBuffer: pixelBuffer, width: 320, height: 180) else {
    check(false, "fake capture frame became a texture")
    return
  }
  let color = made.texture
  var holder: CVMetalTexture? = made.holder
  var colorTexture: MTLTexture? = color
  defer { CaptureTextureLifetime.recycle(holder: &holder, texture: &colorTexture, cache: cache, flush: true) }
  guard let depth = texture(device, width: 2, height: 2, format: .r32Float, usage: [.shaderRead], shared: true),
        let stage = texture(device, width: 3840, height: 1080, format: .bgra8Unorm, usage: [.shaderWrite, .shaderRead], shared: false),
        let readback = texture(device, width: 3840, height: 1080, format: .bgra8Unorm, usage: [.shaderWrite, .shaderRead], shared: true) else {
    check(false, "private stage texture")
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
  let done = DispatchSemaphore(value: 0)
  let flag = CaptureSendFlag()
  let sent = StereoOffscreen.encode(
    commandQueue: queue,
    pipeline: pipeline,
    color: color,
    depth: depth,
    output: stage,
    params: params,
    completion: { ok in
      flag.ok = ok
      done.signal()
    }
  )
  check(sent.ok, "renderer send path accepts a fake frame (\(sent.reason))")
  guard sent.ok else { return }
  let waited = done.wait(timeout: .now() + 5)
  check(waited == .success && flag.ok, "renderer send path finishes the fake frame")
  guard waited == .success, flag.ok else { return }
  let again = StereoOffscreen.encode(commandQueue: queue, pipeline: pipeline, color: color, depth: depth, output: stage, params: params)
  check(again.ok, "the same stage texture sends again after the first frame finishes (\(again.reason))")
  guard again.ok else { return }
  guard let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else {
    check(false, "stage readback blit")
    return
  }
  blit.copy(
    from: stage,
    sourceSlice: 0,
    sourceLevel: 0,
    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
    sourceSize: MTLSize(width: stage.width, height: stage.height, depth: 1),
    to: readback,
    destinationSlice: 0,
    destinationLevel: 0,
    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
  )
  blit.endEncoding()
  buffer.commit()
  buffer.waitUntilCompleted()
  check(buffer.error == nil, "stage readback blit succeeded")
  var pixel = [UInt8](repeating: 0, count: 4)
  func read(_ x: Int) -> (b: Int, r: Int) {
    pixel.withUnsafeMutableBytes { raw in
      readback.getBytes(raw.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(x, 540, 1, 1), mipmapLevel: 0)
    }
    return (Int(pixel[0]), Int(pixel[2]))
  }
  let left = read(480)
  let right = read(3360)
  check(left.r > 200 && left.b < 40 && right.b > 200 && right.r < 40, "the fake frame is non-black in both eyes")
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
    testStagePool()
    testQuitDuringCapture()
    testAudioPolicy()
    testRoute()
    testAVSync()
    testLoopbackOutput()
    testLoopbackPlayback()
    testContentRect()
    let zombies = ProcessInfo.processInfo.environment["CAPTURE_ZOMBIES"] == "1"
    if !zombies {
      testStereoPipeline()
      testCaptureSend()
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

