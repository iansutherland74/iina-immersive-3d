//
//  BrowserCaptureAudio.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Plays ScreenCaptureKit audio through AVAudioEngine on the player's Core Audio
//  device, following mpv volume and mute. Video is late because of the depth
//  pass, so samples wait until the picture on screen reaches their timestamp.
//
//  Mute uses the public macOS 14.2 process tap. It does not use a private API.
//  If muting the app makes ScreenCaptureKit silent, the tap is where macOS put
//  the sound, and that is what plays, on the same clock.

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

  func stop() {
    queue.sync { [weak self] in
      self?.stopOnQueue()
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
    queue.async { [weak self] in
      guard let self, self.started else { return }
      guard let buffer = self.pcmBuffer(from: sampleBuffer) else { return }
      let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      let pts = time.isValid ? CMTimeGetSeconds(time) : CACurrentMediaTime()
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
    }
    drainTimer = timer
    timer.resume()
  }

  private func noteVideo(_ seconds: Double) {
    guard started else { return }
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
    guard ensureEngine() else { return }
    if !node.isPlaying {
      node.play()
    }
    node.scheduleBuffer(buffer, completionHandler: nil)
  }

  @discardableResult
  private func ensureEngine() -> Bool {
    if !connected {
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: targetFormat)
      connected = true
      applyDevice(force: true)
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
    if connected {
      applyDevice(force: false)
      let gain = route.muted ? Float(0) : min(max(route.volume, 0), 1)
      engine.mainMixerNode.outputVolume = gain
    }
  }

  private func applyDevice(force: Bool) {
    let uid = route.deviceUID
    let device = uid.flatMap { Self.deviceID(forUID: $0) } ?? Self.defaultOutputDevice()
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
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var name = uid as CFString
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafePointer(to: name) { pointer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<CFString>.size),
        pointer,
        &size,
        &device
      )
    }
    guard status == noErr, device != 0 else { return nil }
    return device
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
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
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
