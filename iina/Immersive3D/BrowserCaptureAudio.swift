//
//  BrowserCaptureAudio.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Plays loopback samples on the saved Core Audio device. The host-clock path
//  uses an IO proc so a glasses display-mode change can restart that proc.
//  AVAudioEngine remains for the mute-tap path. Volume and mute follow mpv.
//  The samples wait for the measured capture latency so they line up with the
//  picture. ScreenCaptureKit audio stays off: muting the browser silences that
//  capture, and playing it while the browser still speaks is an echo.

import AVFoundation
import AudioToolbox
import Cocoa
import CoreAudio
import CoreMedia
import os

struct BrowserCaptureAudioRoute {
  var volume: Float
  var muted: Bool
  var deviceUID: String?

  static let full = BrowserCaptureAudioRoute(volume: 1, muted: false, deviceUID: nil)
}

enum BrowserCaptureAudioRouteReader {
  static func current() -> BrowserCaptureAudioRoute {
    guard !PlayerCore.playerCores.isEmpty else { return .full }
    let player = PlayerCore.active
    let volume = Float(player.mpv.getDouble(MPVOption.Audio.volume) / 100)
    let muted = player.mpv.getFlag(MPVOption.Audio.mute)
    let name = player.mpv.getString(MPVProperty.audioDevice) ?? "auto"
    return BrowserCaptureAudioRoute(volume: volume, muted: muted, deviceUID: coreAudioUID(name))
  }

  /// `coreaudio/<uid>` and `auto` follow the player. Any other mpv driver uses the system output.
  static func coreAudioUID(_ name: String) -> String? {
    if name.isEmpty || name == "auto" { return nil }
    let prefix = "coreaudio/"
    guard name.hasPrefix(prefix) else { return nil }
    let uid = String(name.dropFirst(prefix.count))
    return uid.isEmpty ? nil : uid
  }
}

/// PCM playback synced to the captured picture.
final class BrowserCaptureAudioPlayer {
  var onNote: ((String) -> Void)?
  var onStatus: ((String) -> Void)?

  private let queue = DispatchQueue(label: "com.colliderli.iina.browser-capture-audio", qos: .userInteractive)
  private let loopbackOutput = CaptureLoopbackOutput()
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let targetFormat: AVAudioFormat
  private var converter: AVAudioConverter?
  private var converterFormat: AVAudioFormat?
  private var connected = false
  private var started = false
  private var route = BrowserCaptureAudioRoute.full
  private var appliedUID: String?
  private var appliedDevice = AudioDeviceID(0)
  private var routeTimer: DispatchSourceTimer?
  private var drainTimer: DispatchSourceTimer?
  private var pending: [(pts: Double, buffer: AVAudioPCMBuffer)] = []
  private var videoPTS: Double?
  private var queuedUntil: Double = 0
  private var heardCapture = false
  private var captureSilentSince: Double?
  private var playingTap = false
  private var announcedTap = false
  private var announcedSilence = false
  private var muteActive = false
  private var hostMode = false
  private var haveDelay = false
  private var hostDelay = 0.0
  private var syncOffsetMs = 0
  private var pinnedUID: String?
  private var announcedDelayMs: Int?
  private var announcedOffset: Int?
  private var loggedConvert = false
  private var loggedDevice = false
  private var loggedMute = false
  private var lastOutLog: CFTimeInterval = 0
  private var outSum: Float = 0
  private var outCount = 0
  private let lateWindow = 0.20
  private let lead = 0.050

  init() {
    targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
  }

  func start() {
    queue.async { [weak self] in
      self?.startOnQueue()
    }
  }

  /// Loopback samples are stamped with the host clock. Playback starts at delay 0
  /// so a missing video present cannot mute the capture. A later measurement
  /// tightens that delay. `pinnedUID` is the real output, never the system default.
  /// The glasses 3D button does not come through here and does not change this UID.
  func beginHostClock(pinnedUID: String) {
    queue.async { [weak self] in
      guard let self else { return }
      self.startOnQueue()
      self.pinnedUID = pinnedUID
      self.hostMode = true
      self.haveDelay = true
      self.hostDelay = 0
      self.announcedDelayMs = nil
      self.announcedOffset = nil
      self.loggedConvert = false
      self.loggedDevice = false
      self.loggedMute = false
      self.lastOutLog = 0
      self.outSum = 0
      self.outCount = 0
      self.openOutput()
    }
  }

  /// The glasses display can reset its audio device when the capture window
  /// lands on it. Open the output again. The reader is left running.
  func reopenOutput() {
    queue.async { [weak self] in
      guard let self, self.hostMode else { return }
      self.loggedDevice = false
      self.openOutput(force: true)
    }
  }

  func setHostDelay(_ seconds: Double) {
    queue.async { [weak self] in
      guard let self else { return }
      self.hostDelay = min(max(seconds, 0), 2)
      self.haveDelay = true
      self.logDelay()
      self.pumpHost()
    }
  }

  /// User adjustment, added to the measured delay. Negative plays earlier.
  func setSyncOffset(ms: Int) {
    queue.async { [weak self] in
      guard let self else { return }
      self.syncOffsetMs = CaptureSyncOffset.clamp(ms)
      if self.hostMode {
        self.logDelay()
      }
      self.pumpHost()
    }
  }

  func consumeHostClock(_ buffer: AVAudioPCMBuffer, hostTime: Double) {
    queue.async { [weak self] in
      guard let self, self.started, self.hostMode else { return }
      guard let converted = self.convert(buffer) else {
        if !self.loggedConvert {
          self.loggedConvert = true
          captureAudioNote("loopback convert failed", error: true)
        }
        return
      }
      self.pending.append((hostTime, converted))
      while self.pending.count > 48 {
        self.pending.removeFirst()
      }
      self.pumpHost()
    }
  }

  func stop() {
    // queue.sync from the main thread blocks the run loop for the whole audio teardown.
    let work = { [weak self] in
      guard let self else { return }
      self.hostMode = false
      self.pinnedUID = nil
      self.haveDelay = false
      self.stopOnQueue()
    }
    if Thread.isMainThread {
      queue.async(execute: work)
    } else {
      queue.sync(execute: work)
    }
  }

  func setSourceMuteActive(_ on: Bool) {
    queue.async { [weak self] in
      guard let self else { return }
      self.muteActive = on
      if !on {
        self.playingTap = false
        self.announcedTap = false
        self.announcedSilence = false
        self.captureSilentSince = nil
      }
    }
  }

  func consumeCapture(_ sampleBuffer: CMSampleBuffer) {
    // OBS copies the audio bytes before the ScreenCaptureKit callback returns.
    // The sample buffer is not owned past that callback.
    guard let buffer = pcmBuffer(from: sampleBuffer) else { return }
    let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let pts = time.isValid ? CMTimeGetSeconds(time) : CACurrentMediaTime()
    queue.async { [weak self] in
      guard let self, self.started else { return }
      self.enqueue(buffer, pts: pts, fromTap: false)
    }
  }

  func notePresentedVideo(_ time: CMTime) {
    let seconds = time.isValid ? CMTimeGetSeconds(time) : CACurrentMediaTime()
    queue.async { [weak self] in
      self?.noteVideo(seconds)
    }
  }

  private func startOnQueue() {
    stopOnQueue()
    hostMode = false
    haveDelay = false
    pinnedUID = nil
    started = true
    playingTap = false
    announcedTap = false
    announcedSilence = false
    heardCapture = false
    captureSilentSince = nil
    videoPTS = nil
    queuedUntil = 0
    pending.removeAll()
    armRouteTimer()
    armDrainTimer()
  }

  private func stopOnQueue() {
    routeTimer?.cancel()
    routeTimer = nil
    drainTimer?.cancel()
    drainTimer = nil
    loopbackOutput.stop()
    started = false
    pending.removeAll()
    videoPTS = nil
    queuedUntil = 0
    if node.isPlaying {
      node.stop()
    }
    if engine.isRunning {
      engine.stop()
    }
  }

  private func armRouteTimer() {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: 0.4)
    timer.setEventHandler { [weak self] in
      let route = BrowserCaptureAudioRouteReader.current()
      self?.queue.async { [weak self] in
        self?.applyRoute(route)
      }
    }
    routeTimer = timer
    timer.resume()
  }

  private func armDrainTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 0.02, repeating: 0.02)
    timer.setEventHandler { [weak self] in
      self?.drainTap()
      if self?.hostMode == true {
        self?.pumpHost()
      }
    }
    drainTimer = timer
    timer.resume()
  }

  private func noteVideo(_ seconds: Double) {
    guard started, !hostMode else { return }
    if let videoPTS, seconds + 0.5 < videoPTS {
      pending.removeAll()
      queuedUntil = 0
      if node.isPlaying {
        node.stop()
      }
    }
    videoPTS = seconds
    pump()
  }

  private func enqueue(_ buffer: AVAudioPCMBuffer, pts: Double, fromTap: Bool) {
    guard started, let converted = convert(buffer) else { return }
    let energy = rms(converted)
    if fromTap {
      guard muteActive, playingTap || captureIsSilent() else { return }
      if energy > 0.002 && captureIsSilent() {
        if !playingTap {
          playingTap = true
          if !announcedTap {
            announcedTap = true
            DispatchQueue.main.async { [weak self] in
              self?.onNote?("Muted the source app. macOS sent its sound to the mute tap, so IINA plays that, in time with the picture.")
            }
          }
        }
      }
      guard playingTap else { return }
    } else {
      if energy > 0.008 {
        heardCapture = true
        captureSilentSince = nil
        announcedSilence = false
        if playingTap {
          playingTap = false
          DispatchQueue.main.async { [weak self] in
            self?.onNote?("Captured audio is playing again.")
          }
        }
      } else if muteActive && heardCapture {
        if captureSilentSince == nil {
          captureSilentSince = CACurrentMediaTime()
        }
      }
      if playingTap && energy <= 0.002 {
        return
      }
    }
    pending.append((pts, converted))
    while pending.count > 1 && pending[pending.count - 1].pts - pending[0].pts > 2.5 {
      pending.removeFirst()
    }
    pump()
  }

  private func drainTap() {
    guard muteActive, started else { return }
    guard #available(macOS 14.2, *) else { return }
    let chunks = BrowserCaptureSourceMute.shared.takeAudio()
    for chunk in chunks {
      guard let buffer = chunk.buffer else { continue }
      enqueue(buffer, pts: chunk.pts, fromTap: true)
    }
    if heardCapture, !playingTap, !announcedSilence, let captureSilentSince, CACurrentMediaTime() - captureSilentSince > 2 {
      announcedSilence = true
      DispatchQueue.main.async { [weak self] in
        self?.onNote?("The source app is muted and the captured audio is silent. Turn Mute source app off to hear that app again.")
      }
    }
  }

  private func captureIsSilent() -> Bool {
    guard let captureSilentSince else { return false }
    return CACurrentMediaTime() - captureSilentSince > 0.8
  }

  private func pumpHost() {
    guard started, hostMode else { return }
    let now = CACurrentMediaTime()
    while let first = pending.first {
      let duration = Double(first.buffer.frameLength) / targetFormat.sampleRate
      switch CaptureLoopbackClock.decide(
        chunk: CaptureLoopbackClock.Chunk(hostTime: first.pts, duration: duration),
        now: now,
        delay: CaptureSyncOffset.delay(automatic: hostDelay, offsetMs: syncOffsetMs)
      ) {
      case .drop:
        pending.removeFirst()
      case .wait:
        return
      case .play:
        pending.removeFirst()
        logDelay()
        schedule(first.buffer)
      }
    }
  }

  private func logDelay() {
    let ms = Int((hostDelay * 1000).rounded())
    if announcedDelayMs == ms && announcedOffset == syncOffsetMs { return }
    announcedDelayMs = ms
    announcedOffset = syncOffsetMs
    captureAudioNote("loopback delay \(ms) ms offset \(self.syncOffsetMs) ms")
  }

  private func openOutput(force: Bool = false) {
    let outcome = loopbackOutput.start(uid: pinnedUID ?? "", force: force)
    switch outcome.kind {
    case .started:
      appliedDevice = outcome.device
      appliedUID = outcome.uid
      let rate = Int(outcome.rate.rounded())
      captureAudioNote("loopback output started device=\(outcome.device) uid=\(outcome.uid) status=\(CaptureDefaultOutput.statusText(outcome.status)) rate=\(rate) ch=\(outcome.channels)")
    case .already:
      appliedDevice = outcome.device
      appliedUID = outcome.uid
    case .failed:
      if !loggedDevice {
        loggedDevice = true
        captureAudioNote("loopback output did not start uid=\(outcome.uid.isEmpty ? "none" : outcome.uid) status=\(CaptureDefaultOutput.statusText(outcome.status)) device=\(outcome.device) rate=\(Int(outcome.rate.rounded())) ch=\(outcome.channels)", error: true)
      }
    }
    let gain = route.muted ? Float(0) : min(max(route.volume, 0), 1)
    loopbackOutput.setGain(gain)
    if gain == 0 && !loggedMute {
      loggedMute = true
      captureAudioNote("loopback output gain is 0")
    }
  }

  private func pump() {
    guard let videoPTS else { return }
    let horizon = videoPTS + lead
    while let first = pending.first {
      let duration = Double(first.buffer.frameLength) / targetFormat.sampleRate
      let end = first.pts + duration
      if end < videoPTS - lateWindow {
        pending.removeFirst()
        continue
      }
      if first.pts > horizon {
        break
      }
      if queuedUntil > horizon && first.pts > videoPTS {
        break
      }
      pending.removeFirst()
      schedule(first.buffer)
      queuedUntil = max(queuedUntil, end)
    }
  }

  private func schedule(_ buffer: AVAudioPCMBuffer) {
    if hostMode {
      loopbackOutput.enqueue(buffer)
      return
    }
    guard ensureEngine() else { return }
    if !node.isPlaying {
      node.play()
    }
    node.scheduleBuffer(buffer, completionHandler: nil)
  }

  @discardableResult
  private func ensureEngine() -> Bool {
    if hostMode { return false }
    if let pinnedUID, Self.deviceID(forUID: pinnedUID) == nil {
      if hostMode && !loggedDevice {
        loggedDevice = true
        captureAudioNote("loopback output device was not found uid=\(pinnedUID)", error: true)
      }
      return false
    }
    if !connected {
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: targetFormat)
      connected = true
      applyDevice(force: true)
    }
    if let pinnedUID, appliedUID != pinnedUID {
      applyDevice(force: true)
      guard appliedUID == pinnedUID else { return false }
    }
    let gain = route.muted ? Float(0) : min(max(route.volume, 0), 1)
    engine.mainMixerNode.outputVolume = gain
    if engine.isRunning { return true }
    do {
      try engine.start()
      return true
    } catch {
      DispatchQueue.main.async { [weak self] in
        self?.onStatus?("Captured audio could not play: \(error.localizedDescription)")
      }
      return false
    }
  }

  private func applyRoute(_ route: BrowserCaptureAudioRoute) {
    self.route = route
    let gain = route.muted ? Float(0) : min(max(route.volume, 0), 1)
    if hostMode {
      loopbackOutput.setGain(gain)
      if gain == 0 && !loggedMute {
        loggedMute = true
        captureAudioNote("loopback output gain is 0")
      }
      return
    }
    if connected {
      applyDevice(force: false)
      engine.mainMixerNode.outputVolume = gain
    }
  }

  private func applyDevice(force: Bool) {
    if hostMode { return }
    let uid = pinnedUID ?? route.deviceUID
    let device: AudioDeviceID
    if let uid, let id = Self.deviceID(forUID: uid) {
      device = id
    } else if pinnedUID != nil {
      // The system default is the loopback while a capture is routed. Playing
      // there would feed IINA back into the buffer it is reading.
      return
    } else {
      device = Self.defaultOutputDevice()
    }
    if !force && device == appliedDevice && uid == appliedUID { return }
    let wasRunning = engine.isRunning
    if wasRunning {
      node.stop()
      engine.stop()
      queuedUntil = 0
    }
    guard let unit = engine.outputNode.audioUnit else { return }
    var id = device
    let status = AudioUnitSetProperty(
      unit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &id,
      UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    if status == noErr {
      appliedDevice = device
      appliedUID = uid
    } else if hostMode && !loggedDevice {
      loggedDevice = true
      captureAudioNote("loopback output device was not set status=\(CaptureDefaultOutput.statusText(status)) device=\(device)", error: true)
    }
    if wasRunning {
      try? engine.start()
      node.play()
    }
  }

  private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
          let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
    var asbd = basic.pointee
    guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
    guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
    let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
    buffer.frameLength = frames
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
    guard status == noErr else { return nil }
    return buffer
  }

  private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    if buffer.format.sampleRate == targetFormat.sampleRate &&
        buffer.format.channelCount == targetFormat.channelCount &&
        buffer.format.commonFormat == targetFormat.commonFormat &&
        buffer.format.isInterleaved == targetFormat.isInterleaved {
      return buffer
    }
    if converter == nil || converterFormat != buffer.format {
      converter = AVAudioConverter(from: buffer.format, to: targetFormat)
      converterFormat = buffer.format
    }
    guard let converter else { return nil }
    converter.reset()
    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
    var error: NSError?
    var supplied = false
    let status = converter.convert(to: output, error: &error) { _, statusOut in
      if supplied {
        statusOut.pointee = .noDataNow
        return nil
      }
      supplied = true
      statusOut.pointee = .haveData
      return buffer
    }
    guard error == nil, status != .error, output.frameLength > 0 else { return nil }
    return output
  }

  private static func interleavedStereo(_ buffer: AVAudioPCMBuffer) -> [Float]? {
    guard let channels = buffer.floatChannelData else { return nil }
    let frames = Int(buffer.frameLength)
    let count = Int(buffer.format.channelCount)
    guard frames > 0, count > 0 else { return nil }
    var samples = [Float](repeating: 0, count: frames * 2)
    let left = channels[0]
    let right = count > 1 ? channels[1] : channels[0]
    for frame in 0..<frames {
      samples[frame * 2] = left[frame]
      samples[frame * 2 + 1] = right[frame]
    }
    return samples
  }

  private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let channels = buffer.floatChannelData else { return 0 }
    let frames = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard frames > 0, channelCount > 0 else { return 0 }
    let step = max(frames / 256, 1)
    var sum: Float = 0
    var count = 0
    var index = 0
    while index < frames {
      var sample: Float = 0
      for channel in 0..<channelCount {
        sample += channels[channel][index]
      }
      sample /= Float(channelCount)
      sum += sample * sample
      count += 1
      index += step
    }
    return sqrt(sum / Float(max(count, 1)))
  }

  private static func defaultOutputDevice() -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return device
  }

  private static func deviceID(forUID uid: String) -> AudioDeviceID? {
    CaptureSystemOutput.deviceID(forUID: uid)
  }
}

struct BrowserCaptureTapChunk {
  var buffer: AVAudioPCMBuffer?
  var pts: Double
}

/// Silences one other process with a public Core Audio tap. Samples are kept
/// only so playback can continue when ScreenCaptureKit goes silent.
@available(macOS 14.2, *)
final class BrowserCaptureSourceMute {
  static let shared = BrowserCaptureSourceMute()

  private let stateLock = NSLock()
  private var unfair = os_unfair_lock()
  private var running = false
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?
  private var activePID: pid_t = 0
  private var streamDescription = AudioStreamBasicDescription()
  private var hasFormat = false
  private var freeChunks: [TapPacket] = (0..<32).map { _ in TapPacket() }
  private var filledChunks: [TapPacket] = []
  private let ticksToSeconds: Double

  private init() {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    ticksToSeconds = Double(info.numer) / Double(info.denom) / 1_000_000_000
  }

  /// Nil when the source app is muted. A string is the reason mute did not start.
  func start(pid: pid_t) -> String? {
    var failure: String?
    stateLock.lock()
    if running && activePID == pid {
      stateLock.unlock()
      return nil
    }
    teardownLocked()
    do {
      try startLocked(pid: pid)
    } catch {
      teardownLocked()
      failure = error.localizedDescription
    }
    stateLock.unlock()
    return failure
  }

  func stop() {
    stateLock.lock()
    teardownLocked()
    stateLock.unlock()
  }

  func takeAudio() -> [BrowserCaptureTapChunk] {
    os_unfair_lock_lock(&unfair)
    let packets = filledChunks
    filledChunks = []
    os_unfair_lock_unlock(&unfair)
    var result: [BrowserCaptureTapChunk] = []
    result.reserveCapacity(packets.count)
    for packet in packets {
      result.append(BrowserCaptureTapChunk(buffer: packet.makeBuffer(), pts: packet.pts))
      packet.count = 0
    }
    os_unfair_lock_lock(&unfair)
    freeChunks.append(contentsOf: packets)
    os_unfair_lock_unlock(&unfair)
    return result
  }

  private func startLocked(pid: pid_t) throws {
    let process = try Self.processObject(for: pid)
    let tap = CATapDescription(stereoMixdownOfProcesses: [process])
    tap.name = "IINA Capture Mute"
    tap.uuid = UUID()
    tap.isPrivate = true
    tap.isExclusive = false
    tap.muteBehavior = .mutedWhenTapped
    var newTap = AudioObjectID(kAudioObjectUnknown)
    let tapStatus = AudioHardwareCreateProcessTap(tap, &newTap)
    guard tapStatus == noErr, newTap != kAudioObjectUnknown else {
      throw MuteFailure("Could not mute that app (\(tapStatus)). It keeps playing, and IINA still plays the captured audio.")
    }
    tapID = newTap
    streamDescription = AudioStreamBasicDescription()
    hasFormat = Self.readFormat(of: newTap, into: &streamDescription)

    let outputDevice = Self.defaultOutputDevice()
    guard let outputUID = Self.uid(of: outputDevice) else {
      throw MuteFailure("Could not mute that app because the output device has no id. It keeps playing, and IINA still plays the captured audio.")
    }
    let aggregateUID = UUID().uuidString
    let description: [String: Any] = [
      kAudioAggregateDeviceNameKey as String: "IINA Capture Mute",
      kAudioAggregateDeviceUIDKey as String: aggregateUID,
      kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
      kAudioAggregateDeviceIsPrivateKey as String: true,
      kAudioAggregateDeviceIsStackedKey as String: false,
      kAudioAggregateDeviceTapAutoStartKey as String: true,
      kAudioAggregateDeviceSubDeviceListKey as String: [
        [kAudioSubDeviceUIDKey as String: outputUID]
      ],
      kAudioAggregateDeviceTapListKey as String: [
        [
          kAudioSubTapDriftCompensationKey as String: true,
          kAudioSubTapUIDKey as String: tap.uuid.uuidString
        ]
      ]
    ]
    var aggregate = AudioObjectID(kAudioObjectUnknown)
    let aggregateStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
    guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
      throw MuteFailure("Could not mute that app (\(aggregateStatus)). It keeps playing, and IINA still plays the captured audio.")
    }
    aggregateID = aggregate
    var newProc: AudioDeviceIOProcID?
    let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregate, nil) { [weak self] _, input, inputTime, output, _ in
      self?.handleInput(input, time: inputTime, output: output)
    }
    guard procStatus == noErr, let newProc else {
      throw MuteFailure("Could not mute that app (\(procStatus)). It keeps playing, and IINA still plays the captured audio.")
    }
    procID = newProc
    os_unfair_lock_lock(&unfair)
    running = true
    os_unfair_lock_unlock(&unfair)
    let startStatus = AudioDeviceStart(aggregate, newProc)
    guard startStatus == noErr else {
      throw MuteFailure("Could not mute that app (\(startStatus)). It keeps playing, and IINA still plays the captured audio.")
    }
    activePID = pid
  }

  private func teardownLocked() {
    os_unfair_lock_lock(&unfair)
    running = false
    os_unfair_lock_unlock(&unfair)
    activePID = 0
    if let procID, aggregateID != kAudioObjectUnknown {
      AudioDeviceStop(aggregateID, procID)
      AudioDeviceDestroyIOProcID(aggregateID, procID)
    }
    procID = nil
    if aggregateID != kAudioObjectUnknown {
      AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = kAudioObjectUnknown
    }
    if tapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = kAudioObjectUnknown
    }
    hasFormat = false
    os_unfair_lock_lock(&unfair)
    freeChunks.append(contentsOf: filledChunks)
    filledChunks.removeAll()
    os_unfair_lock_unlock(&unfair)
  }

  private func handleInput(_ input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>, output: UnsafeMutablePointer<AudioBufferList>) {
    zero(output)
    os_unfair_lock_lock(&unfair)
    let active = running && hasFormat
    let packet = active ? freeChunks.popLast() : nil
    os_unfair_lock_unlock(&unfair)
    guard let packet else { return }
    let frames = copyFloats(from: input, into: packet)
    guard frames > 0 else {
      os_unfair_lock_lock(&unfair)
      freeChunks.append(packet)
      os_unfair_lock_unlock(&unfair)
      return
    }
    packet.count = frames * 2
    packet.pts = hostSeconds(time)
    packet.sampleRate = streamDescription.mSampleRate > 0 ? streamDescription.mSampleRate : 48000
    os_unfair_lock_lock(&unfair)
    if running {
      filledChunks.append(packet)
    } else {
      freeChunks.append(packet)
    }
    os_unfair_lock_unlock(&unfair)
  }

  private func copyFloats(from input: UnsafePointer<AudioBufferList>, into packet: TapPacket) -> Int {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard let first = buffers.first, let data = first.mData else { return 0 }
    let asbd = streamDescription
    let channels = Int(asbd.mChannelsPerFrame)
    guard channels > 0 else { return 0 }
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let bytesPerFrame = Int(asbd.mBytesPerFrame == 0 ? asbd.mBitsPerChannel / 8 * UInt32(nonInterleaved ? 1 : channels) : asbd.mBytesPerFrame)
    guard bytesPerFrame > 0 else { return 0 }
    let frames: Int
    if nonInterleaved {
      frames = Int(first.mDataByteSize) / max(Int(asbd.mBitsPerChannel / 8), 1)
    } else {
      frames = Int(first.mDataByteSize) / bytesPerFrame
    }
    let capacity = packet.samples.count / 2
    let count = min(frames, capacity)
    guard count > 0 else { return 0 }
    if isFloat && !nonInterleaved && channels >= 2 && asbd.mBitsPerChannel == 32 {
      let source = data.assumingMemoryBound(to: Float.self)
      packet.samples.withUnsafeMutableBufferPointer { dest in
        dest.baseAddress?.update(from: source, count: count * 2)
      }
      return count
    }
    if isFloat && nonInterleaved && channels >= 1 && asbd.mBitsPerChannel == 32 {
      let left = data.assumingMemoryBound(to: Float.self)
      let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
      for frame in 0..<count {
        packet.samples[frame * 2] = left[frame]
        packet.samples[frame * 2 + 1] = right?[frame] ?? left[frame]
      }
      return count
    }
    if !isFloat && !nonInterleaved && asbd.mBitsPerChannel == 16 && channels >= 2 {
      let source = data.assumingMemoryBound(to: Int16.self)
      for frame in 0..<count {
        packet.samples[frame * 2] = Float(source[frame * channels]) / 32768
        packet.samples[frame * 2 + 1] = Float(source[frame * channels + 1]) / 32768
      }
      return count
    }
    return 0
  }

  private func zero(_ output: UnsafeMutablePointer<AudioBufferList>) {
    let buffers = UnsafeMutableAudioBufferListPointer(output)
    for buffer in buffers {
      guard let data = buffer.mData else { continue }
      memset(data, 0, Int(buffer.mDataByteSize))
    }
  }

  private func hostSeconds(_ stamp: UnsafePointer<AudioTimeStamp>) -> Double {
    if stamp.pointee.mFlags.rawValue & AudioTimeStampFlags.hostTimeValid.rawValue != 0 {
      return Double(stamp.pointee.mHostTime) * ticksToSeconds
    }
    return CACurrentMediaTime()
  }

  private static func processObject(for pid: pid_t) throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var pid = pid
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      UInt32(MemoryLayout<pid_t>.size),
      &pid,
      &size,
      &object
    )
    guard status == noErr, object != kAudioObjectUnknown else {
      throw MuteFailure("That app is not playing audio macOS can mute yet. IINA still plays the captured audio, and the other app keeps playing.")
    }
    return object
  }

  private static func readFormat(of tap: AudioObjectID, into description: inout AudioStreamBasicDescription) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description)
    return status == noErr && description.mChannelsPerFrame > 0 && description.mSampleRate > 0
  }

  private static func defaultOutputDevice() -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return device
  }

  private static func uid(of device: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    // kAudioDevicePropertyDeviceUID hands back one +1 CFString. The buffer is a
    // single pointer. takeRetainedValue consumes that retain. Sizing the buffer
    // as an Unmanaged optional (two words) makes Core Audio write a pointer into
    // the wrong layout, and the next autorelease pop releases it again.
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
    guard status == noErr, let name else { return nil }
    return name.takeRetainedValue() as String
  }
}

@available(macOS 14.2, *)
private final class TapPacket {
  var samples = [Float](repeating: 0, count: 8192)
  var count = 0
  var pts = 0.0
  var sampleRate = 48000.0

  func makeBuffer() -> AVAudioPCMBuffer? {
    guard count >= 2, sampleRate > 0 else { return nil }
    let frames = count / 2
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
          let left = buffer.floatChannelData?[0],
          let right = buffer.floatChannelData?[1] else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    for frame in 0..<frames {
      left[frame] = samples[frame * 2]
      right[frame] = samples[frame * 2 + 1]
    }
    return buffer
  }
}

private struct MuteFailure: LocalizedError {
  var errorDescription: String?
  init(_ text: String) { errorDescription = text }
}
