//
//  CaptureLoopbackOutput.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Plays the 48 kHz loopback on the saved output device with an IO proc.
//  The glasses 3D button changes the display mode. That restarts the
//  DisplayPort device (it can go away, come back with a new id, or change
//  rate and channel count) while the virtual-device reader keeps running.
//  Property listeners tear this proc down and open it again on the saved UID.
//  Nothing here writes the system default or mpv's audio device.

import AudioToolbox
import Cocoa
import CoreAudio
import Darwin
import os
import QuartzCore

/// Lines for ~/Library/Logs/IINA/capture-audio.log, and the unified log the
/// same category already uses.
enum CaptureAudioFileLog {
  private static let queue = DispatchQueue(label: "com.colliderli.iina.capture-audio-log")
  private static let path: String = {
    (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/IINA/capture-audio.log")
  }()
  private static let stamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
  }()

  static func info(_ message: String) {
    browserCaptureLog.info("\(message, privacy: .public)")
    append(message)
  }

  static func error(_ message: String) {
    browserCaptureLog.error("\(message, privacy: .public)")
    append(message)
  }

  private static func append(_ message: String) {
    let line = message
    queue.async {
      let url = URL(fileURLWithPath: path)
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
      }
      guard let handle = FileHandle(forWritingAtPath: path) else { return }
      defer { try? handle.close() }
      do {
        try handle.seekToEnd()
        let text = "\(stamp.string(from: Date())) \(line)\n"
        if let data = text.data(using: .utf8) {
          try handle.write(contentsOf: data)
        }
      } catch {
        return
      }
    }
  }
}

/// Output IO proc for the capture loopback. Samples are 48 kHz stereo float.
/// The proc resamples when the device is not 48 kHz and places the pair on the
/// device's preferred stereo channels.
final class CaptureLoopbackOutput {
  private struct PlaybackFormat {
    var sampleRate: Double = CaptureLoopbackMix.sourceRate
    var channels: Int = 2
    var left: Int = 0
    var right: Int = 1
    var bits: Int = 32
    var isFloat: Bool = true
    var nonInterleaved: Bool = false
    var bytesPerFrame: Int = 8
    var bytesPerSample: Int = 4
    var bigEndian: Bool = false
    var alignedHigh: Bool = false
    var valid: Bool = false

    static let invalid = PlaybackFormat()
  }

  private struct InstalledListener {
    var object: AudioObjectID
    var selector: AudioObjectPropertySelector
    var scope: AudioObjectPropertyScope
  }

  private let queueKey = DispatchSpecificKey<UInt8>()
  private let queue: DispatchQueue
  private var lock = os_unfair_lock()
  private var savedUID: String?
  private var wanted = false
  private var gain: Float = 1
  private var playbackFormat = PlaybackFormat.invalid
  private var ioStarted = false
  private var lastCallback = 0.0
  private var procID: AudioDeviceIOProcID?
  private var openedDevice = AudioDeviceID(0)
  private var installed: [InstalledListener] = []
  private var listenedDevice = AudioDeviceID(0)
  private var applied = CaptureOutputWatch.Snapshot(deviceID: 0, alive: false, running: false, sampleRate: 0, channels: 0)
  private var lastRestart = 0.0
  private var didStart = false
  private var lastFailureKey = ""
  private var lastFailureLog = 0.0
  private var watchdog: DispatchSourceTimer?
  private var rmsSum: Float = 0
  private var rmsCount = 0
  private var underrunWindow = 0
  private var underrunTotal = 0
  private var lastRMSLog = 0.0

  private let ringCapacity = 48000
  private let ring: UnsafeMutablePointer<Float>
  private var ringRead = 0
  private var ringCount = 0
  private var phase = 0.0
  private let scratchFrames = 8192
  private let scratch: UnsafeMutablePointer<Float>
  private let chunkLimit = 1024
  private let mixed: UnsafeMutablePointer<Float>

  init() {
    queue = DispatchQueue(label: "com.colliderli.iina.capture-loopback-out", qos: .userInteractive)
    ring = .allocate(capacity: 48000 * 2)
    ring.initialize(repeating: 0, count: 48000 * 2)
    scratch = .allocate(capacity: 8192 * 2)
    scratch.initialize(repeating: 0, count: 8192 * 2)
    mixed = .allocate(capacity: 1024 * 32)
    mixed.initialize(repeating: 0, count: 1024 * 32)
    queue.setSpecific(key: queueKey, value: 1)
  }

  deinit {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      tearDown()
    } else {
      queue.sync { self.tearDown() }
    }
    ring.deinitialize(count: ringCapacity * 2)
    ring.deallocate()
    scratch.deinitialize(count: scratchFrames * 2)
    scratch.deallocate()
    mixed.deinitialize(count: chunkLimit * 32)
    mixed.deallocate()
  }

  func start(uid: String) {
    queue.async {
      self.savedUID = uid
      self.setWanted(true)
      self.installSystemListeners()
      self.armWatchdog()
      self.restart(reason: "start")
    }
  }

  func stop() {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      tearDown()
    } else {
      queue.sync { self.tearDown() }
    }
  }

  func setGain(_ value: Float) {
    let clamped = min(max(value, 0), 1)
    os_unfair_lock_lock(&lock)
    gain = clamped
    os_unfair_lock_unlock(&lock)
  }

  func write(_ samples: UnsafePointer<Float>, frames: Int) {
    guard frames > 0 else { return }
    os_unfair_lock_lock(&lock)
    if wanted {
      appendLocked(samples, frames: frames)
    }
    os_unfair_lock_unlock(&lock)
  }

  private func tearDown() {
    cancelWatchdog()
    os_unfair_lock_lock(&lock)
    wanted = false
    os_unfair_lock_unlock(&lock)
    stopIO()
    removeListeners()
    os_unfair_lock_lock(&lock)
    ringCount = 0
    ringRead = 0
    phase = 0
    playbackFormat = .invalid
    os_unfair_lock_unlock(&lock)
    savedUID = nil
    applied = CaptureOutputWatch.Snapshot(deviceID: 0, alive: false, running: false, sampleRate: 0, channels: 0)
    didStart = false
    lastRestart = 0
    lastFailureKey = ""
  }

  private func setWanted(_ value: Bool) {
    os_unfair_lock_lock(&lock)
    wanted = value
    os_unfair_lock_unlock(&lock)
  }

  private func wantedFlag() -> Bool {
    os_unfair_lock_lock(&lock)
    let value = wanted
    os_unfair_lock_unlock(&lock)
    return value
  }

  private func armWatchdog() {
    if watchdog != nil { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
    timer.setEventHandler { [weak self] in
      self?.poke()
    }
    watchdog = timer
    timer.resume()
  }

  private func cancelWatchdog() {
    watchdog?.cancel()
    watchdog = nil
  }

  private func poke() {
    guard wantedFlag(), savedUID != nil else { return }
    os_unfair_lock_lock(&lock)
    let started = ioStarted
    let last = lastCallback
    os_unfair_lock_unlock(&lock)
    if !started {
      restart(reason: "retry")
      return
    }
    if last > 0 && CACurrentMediaTime() - last > 1.5 {
      CaptureAudioFileLog.error("loopback output callback stalled")
      restart(reason: "stalled")
    }
  }

  /// Reads the saved UID again, prefers a stereo layout, and opens a new proc.
  /// A default-device notification is only a reason to do this. The default itself is not written.
  private func restart(reason: String) {
    guard let uid = savedUID, !uid.isEmpty else { return }
    stopIO()
    guard let device = CaptureSystemOutput.deviceID(forUID: uid), device != 0 else {
      syncDeviceListeners(0)
      report(false, "loopback output restart failed reason=\(reason) status=device-missing device=0 uid=\(uid)")
      return
    }
    syncDeviceListeners(device)
    let alive = readUInt32(device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal) == 1
    if !alive {
      report(false, "loopback output restart failed reason=\(reason) status=not-alive device=\(device) uid=\(uid)")
      return
    }
    let layoutStatus = setStereoLayout(device)
    let pairStatus = setStereoPair(device)
    var stream = readStreamFormat(device)
    if !playable(stream) {
      let nominal = readNominal(device)
      let rate = stream.mSampleRate > 0 ? stream.mSampleRate : (nominal > 0 ? nominal : CaptureLoopbackMix.sourceRate)
      let channels = stream.mChannelsPerFrame > 0 ? Int(stream.mChannelsPerFrame) : 2
      let setStatus = setFloatFormat(device, rate: rate, channels: channels)
      let setText = CaptureDefaultOutput.statusText(setStatus)
      CaptureAudioFileLog.info("loopback output set stream format status=\(setText)")
      stream = readStreamFormat(device)
    }
    let nominal = readNominal(device)
    let rate = stream.mSampleRate > 0 ? stream.mSampleRate : nominal
    let channels = Int(stream.mChannelsPerFrame)
    guard rate > 0, channels > 0, channels <= 32, playable(stream) else {
      let rateText = String(format: "%.0f", rate)
      let bits = Int(stream.mBitsPerChannel)
      report(false, "loopback output restart failed reason=\(reason) status=unplayable device=\(device) uid=\(uid) rate=\(rateText) ch=\(channels) bits=\(bits) bytes=\(sampleBytes(stream))")
      return
    }
    let mapped = CaptureLoopbackMix.stereoPair(preferred: readStereoPair(device), channels: channels)
    let flags = stream.mFormatFlags
    let format = PlaybackFormat(
      sampleRate: rate,
      channels: channels,
      left: mapped.left,
      right: mapped.right,
      bits: Int(stream.mBitsPerChannel),
      isFloat: flags & kAudioFormatFlagIsFloat != 0,
      nonInterleaved: flags & kAudioFormatFlagIsNonInterleaved != 0,
      bytesPerFrame: Int(stream.mBytesPerFrame),
      bytesPerSample: sampleBytes(stream),
      bigEndian: flags & kAudioFormatFlagIsBigEndian != 0,
      alignedHigh: flags & kAudioFormatFlagIsAlignedHigh != 0,
      valid: true
    )
    os_unfair_lock_lock(&lock)
    playbackFormat = format
    os_unfair_lock_unlock(&lock)
    let pairText = "\(mapped.left + 1),\(mapped.right + 1)"
    let layoutText = CaptureDefaultOutput.statusText(layoutStatus)
    let pairStatusText = CaptureDefaultOutput.statusText(pairStatus)
    CaptureAudioFileLog.info("loopback output preferred stereo layout=\(layoutText) channels=\(pairStatusText) pair=\(pairText)")

    var created: AudioDeviceIOProcID?
    let createStatus = AudioDeviceCreateIOProcID(device, Self.ioProc, Unmanaged.passUnretained(self).toOpaque(), &created)
    guard createStatus == noErr, let created else {
      report(false, "loopback output restart failed reason=\(reason) status=\(CaptureDefaultOutput.statusText(createStatus)) device=\(device) uid=\(uid)")
      return
    }
    let startStatus = AudioDeviceStart(device, created)
    if startStatus != noErr {
      AudioDeviceDestroyIOProcID(device, created)
      report(false, "loopback output restart failed reason=\(reason) status=\(CaptureDefaultOutput.statusText(startStatus)) device=\(device) uid=\(uid)")
      return
    }
    procID = created
    openedDevice = device
    os_unfair_lock_lock(&lock)
    ioStarted = true
    lastCallback = CACurrentMediaTime()
    os_unfair_lock_unlock(&lock)
    let aliveNow = readUInt32(device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal) == 1
    let runningNow = readUInt32(device, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 1
    applied = CaptureOutputWatch.Snapshot(
      deviceID: device,
      alive: aliveNow,
      running: runningNow,
      sampleRate: rate,
      channels: channels,
      bits: format.bits,
      isFloat: format.isFloat,
      bytesPerFrame: format.bytesPerFrame,
      nonInterleaved: format.nonInterleaved
    )
    lastRestart = CACurrentMediaTime()
    let rateText = String(format: "%.0f", rate)
    let nominalText = String(format: "%.0f", nominal)
    let name = CaptureSystemOutput.copyString(device, selector: kAudioDevicePropertyDeviceNameCFString) ?? ""
    let verb = didStart ? "restart" : "started"
    didStart = true
    let floatFlag = format.isFloat ? 1 : 0
    let splitFlag = format.nonInterleaved ? 1 : 0
    let runningFlag = runningNow ? 1 : 0
    report(true, "loopback output \(verb) reason=\(reason) status=\(CaptureDefaultOutput.statusText(startStatus)) device=\(device) uid=\(uid) name=\(name) rate=\(rateText) nominal=\(nominalText) ch=\(channels) bits=\(format.bits) float=\(floatFlag) nonInterleaved=\(splitFlag) running=\(runningFlag)")
  }

  private func stopIO() {
    let proc = procID
    let device = openedDevice
    procID = nil
    openedDevice = 0
    os_unfair_lock_lock(&lock)
    ioStarted = false
    os_unfair_lock_unlock(&lock)
    guard let proc, device != 0 else { return }
    let stopped = AudioDeviceStop(device, proc)
    let destroyed = AudioDeviceDestroyIOProcID(device, proc)
    let stopText = CaptureDefaultOutput.statusText(stopped)
    let destroyText = CaptureDefaultOutput.statusText(destroyed)
    CaptureAudioFileLog.info("loopback output stop status=\(stopText) destroy=\(destroyText) device=\(device)")
  }

  private func report(_ ok: Bool, _ line: String) {
    if ok {
      lastFailureKey = ""
      CaptureAudioFileLog.info(line)
      return
    }
    let now = CACurrentMediaTime()
    if line == lastFailureKey && now - lastFailureLog < 2 { return }
    lastFailureKey = line
    lastFailureLog = now
    CaptureAudioFileLog.error(line)
  }

  private static let listenerProc: AudioObjectPropertyListenerProc = { _, count, addresses, client in
    guard let client else { return noErr }
    let output = Unmanaged<CaptureLoopbackOutput>.fromOpaque(client).takeUnretainedValue()
    for index in 0..<Int(count) {
      output.enqueue(addresses[index])
    }
    return noErr
  }

  private func enqueue(_ address: AudioObjectPropertyAddress) {
    queue.async { [weak self] in
      self?.handle(address)
    }
  }

  private func handle(_ address: AudioObjectPropertyAddress) {
    guard wantedFlag() else { return }
    let resolved = resolvedSnapshot()
    guard let notice = notice(for: address.mSelector, resolved: resolved) else { return }
    let rateText = String(format: "%.0f", resolved.sampleRate)
    let floatFlag = resolved.isFloat ? 1 : 0
    var detail = "device=\(resolved.deviceID) alive=\(resolved.alive ? 1 : 0) running=\(resolved.running ? 1 : 0) rate=\(rateText) ch=\(resolved.channels) bits=\(resolved.bits) float=\(floatFlag) bytes=\(resolved.bytesPerFrame)"
    if address.mSelector == kAudioHardwarePropertyDefaultOutputDevice || address.mSelector == kAudioHardwarePropertyDefaultSystemOutputDevice {
      detail += " default=\(defaultOutputID()) saved=\(resolved.deviceID)"
    }
    CaptureAudioFileLog.info("loopback output event \(notice.name) \(detail)")
    if !CaptureOutputWatch.routeEffects(for: notice).isEmpty {
      CaptureAudioFileLog.error("loopback output event \(notice.name) ignored an audio route change")
      return
    }
    let recently = lastRestart > 0 && CACurrentMediaTime() - lastRestart < 1
    switch CaptureOutputWatch.step(notice: notice, applied: applied, resolved: resolved, rebuiltRecently: recently) {
    case .keep:
      CaptureAudioFileLog.info("loopback output event \(notice.name) unchanged")
    case .restart(let reason):
      restart(reason: reason)
    }
  }

  private func notice(for selector: AudioObjectPropertySelector, resolved: CaptureOutputWatch.Snapshot) -> CaptureOutputWatch.Notice? {
    switch selector {
    case kAudioDevicePropertyDeviceIsRunning:
      return .running(resolved.running)
    case kAudioDevicePropertyDeviceIsAlive:
      return .alive(resolved.alive)
    case kAudioDevicePropertyNominalSampleRate:
      return .nominalSampleRate(resolved.sampleRate)
    case kAudioDevicePropertyStreamFormat:
      return .streamFormat(sampleRate: resolved.sampleRate, channels: resolved.channels)
    case kAudioHardwarePropertyDevices:
      return .devicesChanged
    case kAudioHardwarePropertyDefaultOutputDevice:
      return .defaultOutputChanged
    case kAudioHardwarePropertyDefaultSystemOutputDevice:
      return .defaultSystemOutputChanged
    default:
      return nil
    }
  }

  private func resolvedSnapshot() -> CaptureOutputWatch.Snapshot {
    guard let uid = savedUID, let device = CaptureSystemOutput.deviceID(forUID: uid), device != 0 else {
      return CaptureOutputWatch.Snapshot(deviceID: 0, alive: false, running: false, sampleRate: 0, channels: 0)
    }
    let alive = readUInt32(device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal) == 1
    let running = readUInt32(device, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 1
    let stream = readStreamFormat(device)
    let nominal = readNominal(device)
    let rate = stream.mSampleRate > 0 ? stream.mSampleRate : nominal
    let flags = stream.mFormatFlags
    return CaptureOutputWatch.Snapshot(
      deviceID: device,
      alive: alive,
      running: running,
      sampleRate: rate,
      channels: Int(stream.mChannelsPerFrame),
      bits: Int(stream.mBitsPerChannel),
      isFloat: flags & kAudioFormatFlagIsFloat != 0,
      bytesPerFrame: Int(stream.mBytesPerFrame),
      nonInterleaved: flags & kAudioFormatFlagIsNonInterleaved != 0
    )
  }

  private func installSystemListeners() {
    let system = AudioObjectID(kAudioObjectSystemObject)
    addListener(object: system, selector: kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
    addListener(object: system, selector: kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
    addListener(object: system, selector: kAudioHardwarePropertyDefaultSystemOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
  }

  private func syncDeviceListeners(_ device: AudioDeviceID) {
    if device == listenedDevice && device != 0 { return }
    removeDeviceListeners()
    guard device != 0 else { return }
    addListener(object: device, selector: kAudioDevicePropertyDeviceIsRunning, scope: kAudioObjectPropertyScopeGlobal)
    addListener(object: device, selector: kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal)
    addListener(object: device, selector: kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal)
    addListener(object: device, selector: kAudioDevicePropertyStreamFormat, scope: kAudioDevicePropertyScopeOutput)
    listenedDevice = device
  }

  private func addListener(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) {
    if installed.contains(where: { $0.object == object && $0.selector == selector && $0.scope == scope }) {
      return
    }
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectAddPropertyListener(object, &address, Self.listenerProc, Unmanaged.passUnretained(self).toOpaque())
    if status == noErr {
      installed.append(InstalledListener(object: object, selector: selector, scope: scope))
    } else if let notice = notice(for: selector, resolved: applied) {
      report(false, "loopback output listen \(notice.name) status=\(CaptureDefaultOutput.statusText(status)) device=\(object)")
    }
  }

  private func removeDeviceListeners() {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let gone = installed.filter { $0.object != system }
    installed.removeAll { $0.object != system }
    for item in gone {
      remove(item)
    }
    listenedDevice = 0
  }

  private func removeListeners() {
    let copy = installed
    installed.removeAll()
    listenedDevice = 0
    for item in copy {
      remove(item)
    }
  }

  private func remove(_ item: InstalledListener) {
    var address = AudioObjectPropertyAddress(
      mSelector: item.selector,
      mScope: item.scope,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListener(item.object, &address, Self.listenerProc, Unmanaged.passUnretained(self).toOpaque())
  }

  private static let ioProc: AudioDeviceIOProc = { _, _, _, _, output, _, client in
    guard let client else { return noErr }
    let player = Unmanaged<CaptureLoopbackOutput>.fromOpaque(client).takeUnretainedValue()
    player.render(output)
    return noErr
  }

  private func render(_ output: UnsafeMutablePointer<AudioBufferList>) {
    os_unfair_lock_lock(&lock)
    let format = playbackFormat
    let level = gain
    os_unfair_lock_unlock(&lock)
    guard format.valid else {
      zero(output)
      return
    }
    let frames = frameCount(output, format: format)
    guard frames > 0 else {
      zero(output)
      return
    }
    zero(output)
    var done = 0
    var sum: Float = 0
    var counted = 0
    var underrun = 0
    let step = CaptureLoopbackMix.sourceRate / max(format.sampleRate, 1)
    let divisor = max(Int(step + 0.999999), 1)
    while done < frames {
      let maxChunk = max(1, (scratchFrames - 2) / divisor)
      let chunk = min(chunkLimit, maxChunk, frames - done)
      let piece = renderChunk(chunk, format: format, gain: level, output: output, frameOffset: done)
      sum += piece.sum
      counted += piece.count
      underrun += piece.underrun
      done += chunk
    }
    noteCallbackLevel(sum: sum, count: counted, underrun: underrun)
    os_unfair_lock_lock(&lock)
    lastCallback = CACurrentMediaTime()
    os_unfair_lock_unlock(&lock)
  }

  private func renderChunk(
    _ chunk: Int,
    format: PlaybackFormat,
    gain: Float,
    output: UnsafeMutablePointer<AudioBufferList>,
    frameOffset: Int
  ) -> (sum: Float, count: Int, underrun: Int) {
    os_unfair_lock_lock(&lock)
    let start = phase
    let step = CaptureLoopbackMix.sourceRate / max(format.sampleRate, 1)
    let end = start + Double(chunk) * step
    let needed = min(scratchFrames, max(0, Int(end) + 2))
    let copied = copyOutLocked(frames: needed)
    let tail = mixLocked(copied: copied, chunk: chunk, format: format, phase: start)
    discardLocked(tail.consumed)
    phase = tail.phase
    let underrun = tail.underrunFrames
    os_unfair_lock_unlock(&lock)
    writeDevice(mixed, frames: chunk, format: format, gain: gain, output: output, frameOffset: frameOffset)
    var sum: Float = 0
    let left = min(max(format.left, 0), max(format.channels - 1, 0))
    for frame in 0..<chunk {
      let sample = mixed[frame * format.channels + left] * gain
      sum += sample * sample
    }
    return (sum, chunk, underrun)
  }

  private func mixLocked(copied: Int, chunk: Int, format: PlaybackFormat, phase: Double) -> CaptureLoopbackMix.Tail {
    CaptureLoopbackMix.render(
      source: scratch,
      sourceFrames: copied,
      output: mixed,
      outputFrames: chunk,
      deviceRate: format.sampleRate,
      channels: format.channels,
      left: format.left,
      right: format.right,
      phase: phase
    )
  }

  private func noteCallbackLevel(sum: Float, count: Int, underrun: Int) {
    rmsSum += sum
    rmsCount += count
    underrunWindow += underrun
    underrunTotal += underrun
    let now = CACurrentMediaTime()
    if lastRMSLog == 0 {
      lastRMSLog = now
      return
    }
    if now - lastRMSLog < 1 { return }
    lastRMSLog = now
    let mean = sqrt(rmsSum / Float(max(rmsCount, 1)))
    rmsSum = 0
    rmsCount = 0
    let window = underrunWindow
    underrunWindow = 0
    let total = underrunTotal
    let rms = String(format: "%.4f", mean)
    CaptureAudioFileLog.info("loopback out rms=\(rms) underrun=\(window) total=\(total)")
  }

  private func frameCount(_ output: UnsafeMutablePointer<AudioBufferList>, format: PlaybackFormat) -> Int {
    let buffers = UnsafeMutableAudioBufferListPointer(output)
    guard let first = buffers.first, format.bits > 0 else { return 0 }
    if format.nonInterleaved {
      let bytesPerSample = max(format.bytesPerSample, 1)
      return Int(first.mDataByteSize) / bytesPerSample
    }
    let stride = format.bytesPerFrame > 0 ? format.bytesPerFrame : max(format.bits / 8, 1) * max(format.channels, 1)
    guard stride > 0 else { return 0 }
    return Int(first.mDataByteSize) / stride
  }

  private func writeDevice(
    _ samples: UnsafePointer<Float>,
    frames: Int,
    format: PlaybackFormat,
    gain: Float,
    output: UnsafeMutablePointer<AudioBufferList>,
    frameOffset: Int
  ) {
    let buffers = UnsafeMutableAudioBufferListPointer(output)
    let channels = format.channels
    guard channels > 0, frames > 0 else { return }
    if format.isFloat && format.bits == 32 {
      if format.nonInterleaved {
        let limit = min(buffers.count, channels)
        for channel in 0..<limit {
          guard let data = buffers[channel].mData else { continue }
          let dest = data.assumingMemoryBound(to: Float.self)
          for frame in 0..<frames {
            dest[frameOffset + frame] = samples[frame * channels + channel] * gain
          }
        }
        return
      }
      guard let data = buffers.first?.mData else { return }
      let dest = data.assumingMemoryBound(to: Float.self)
      let base = frameOffset * channels
      let count = frames * channels
      for index in 0..<count {
        dest[base + index] = samples[index] * gain
      }
      return
    }
    if format.nonInterleaved {
      let limit = min(buffers.count, channels)
      let stride = max(format.bytesPerSample, 1)
      for channel in 0..<limit {
        guard let data = buffers[channel].mData else { continue }
        for frame in 0..<frames {
          let dest = data.advanced(by: (frameOffset + frame) * stride)
          storeInteger(samples[frame * channels + channel] * gain, at: dest, format: format)
        }
      }
      return
    }
    guard let data = buffers.first?.mData else { return }
    let stride = max(format.bytesPerSample, 1)
    let base = frameOffset * channels
    for index in 0..<(frames * channels) {
      storeInteger(samples[index] * gain, at: data.advanced(by: (base + index) * stride), format: format)
    }
  }

  private func storeInteger(_ sample: Float, at dest: UnsafeMutableRawPointer, format: PlaybackFormat) {
    let clipped = min(max(sample, -1), 1)
    if format.bits == 16 {
      var word = UInt16(bitPattern: quantize16(clipped))
      if format.bigEndian { word = word.bigEndian }
      memcpy(dest, &word, 2)
      return
    }
    if format.bits == 24 {
      let peak: Float = 8388607
      let floor: Float = -8388608
      let scaled = max(min(clipped * peak, peak), floor)
      let full = Int32(scaled)
      if format.bytesPerSample == 3 {
        let raw = UInt32(bitPattern: full)
        let low = raw & 0xff
        let mid = (raw >> 8) & 0xff
        let high = (raw >> 16) & 0xff
        var word: UInt32 = format.bigEndian ? (high | (mid << 8) | (low << 16)) : (raw & 0x00ffffff)
        memcpy(dest, &word, 3)
        return
      }
      let bits24 = UInt32(bitPattern: full) & 0x00ffffff
      var word = format.alignedHigh ? (bits24 << 8) : bits24
      if format.bigEndian { word = word.bigEndian }
      memcpy(dest, &word, 4)
      return
    }
    var word = UInt32(bitPattern: quantize32(clipped))
    if format.bigEndian { word = word.bigEndian }
    memcpy(dest, &word, min(max(format.bytesPerSample, 1), 4))
  }

  private func quantize16(_ sample: Float) -> Int16 {
    let clipped = min(max(sample, -1), 1)
    return Int16(max(min(clipped * 32767, 32767), -32768))
  }

  private func quantize32(_ sample: Float) -> Int32 {
    let clipped = min(max(Double(sample), -1), 1)
    let scaled = clipped * 2147483647.0
    return Int32(max(min(scaled, 2147483647.0), -2147483648.0))
  }

  private func zero(_ output: UnsafeMutablePointer<AudioBufferList>) {
    let buffers = UnsafeMutableAudioBufferListPointer(output)
    for buffer in buffers {
      guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
      memset(data, 0, Int(buffer.mDataByteSize))
    }
  }

  private func appendLocked(_ samples: UnsafePointer<Float>, frames: Int) {
    var incoming = samples
    var count = frames
    if count >= ringCapacity {
      incoming = samples + (count - ringCapacity) * 2
      count = ringCapacity
      ringRead = 0
      ringCount = 0
      phase = 0
    } else if ringCount + count > ringCapacity {
      discardLocked(ringCount + count - ringCapacity)
    }
    var left = count
    var cursor = incoming
    var write = (ringRead + ringCount) % ringCapacity
    while left > 0 {
      let run = min(left, ringCapacity - write)
      memcpy(ring + write * 2, cursor, run * 2 * MemoryLayout<Float>.size)
      cursor += run * 2
      left -= run
      write = (write + run) % ringCapacity
    }
    ringCount += count
  }

  private func copyOutLocked(frames: Int) -> Int {
    let count = min(max(frames, 0), ringCount)
    guard count > 0 else { return 0 }
    var left = count
    var read = ringRead
    var offset = 0
    while left > 0 {
      let run = min(left, ringCapacity - read)
      memcpy(scratch + offset, ring + read * 2, run * 2 * MemoryLayout<Float>.size)
      offset += run * 2
      left -= run
      read = (read + run) % ringCapacity
    }
    return count
  }

  private func discardLocked(_ frames: Int) {
    let count = min(max(frames, 0), ringCount)
    guard count > 0 else { return }
    ringRead = (ringRead + count) % ringCapacity
    ringCount -= count
    if phase <= Double(count) {
      phase = 0
    } else {
      phase -= Double(count)
    }
  }

  private func sampleBytes(_ format: AudioStreamBasicDescription) -> Int {
    let channels = Int(format.mChannelsPerFrame)
    let bytesPerFrame = Int(format.mBytesPerFrame)
    let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    if nonInterleaved { return bytesPerFrame }
    if channels > 0, bytesPerFrame > 0, bytesPerFrame % channels == 0 {
      return bytesPerFrame / channels
    }
    return max(Int(format.mBitsPerChannel) / 8, 0)
  }

  /// Float32, signed 16/32, and signed 24 (packed in 3 bytes or a 32-bit word).
  /// DisplayPort devices often come back as 16- or 24-bit after a mode switch.
  private func playable(_ format: AudioStreamBasicDescription) -> Bool {
    guard format.mChannelsPerFrame > 0, format.mSampleRate > 0, format.mFormatID == kAudioFormatLinearPCM else { return false }
    let flags = format.mFormatFlags
    let bits = Int(format.mBitsPerChannel)
    let bytes = sampleBytes(format)
    if flags & kAudioFormatFlagIsFloat != 0 {
      return bits == 32 && bytes == 4
    }
    guard flags & kAudioFormatFlagIsSignedInteger != 0 else { return false }
    if bits == 16 && bytes == 2 { return true }
    if bits == 32 && bytes == 4 { return true }
    if bits == 24 && (bytes == 3 || bytes == 4) { return true }
    return false
  }

  private func readStreamFormat(_ device: AudioDeviceID) -> AudioStreamBasicDescription {
    var format = AudioStreamBasicDescription()
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format)
    if status != noErr { return AudioStreamBasicDescription() }
    return format
  }

  private func readNominal(_ device: AudioDeviceID) -> Double {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
    return status == noErr ? value : 0
  }

  private func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    return status == noErr ? value : 0
  }

  private func defaultOutputID() -> AudioDeviceID {
    readUInt32(
      AudioObjectID(kAudioObjectSystemObject),
      kAudioHardwarePropertyDefaultOutputDevice,
      kAudioObjectPropertyScopeGlobal
    )
  }

  private func setStereoLayout(_ device: AudioDeviceID) -> OSStatus {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyPreferredChannelLayout,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    let size = MemoryLayout<AudioChannelLayout>.stride
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
    defer { raw.deallocate() }
    memset(raw, 0, size)
    raw.assumingMemoryBound(to: AudioChannelLayout.self).pointee.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), raw)
  }

  private func setStereoPair(_ device: AudioDeviceID) -> OSStatus {
    var pair: [UInt32] = [1, 2]
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    return AudioObjectSetPropertyData(
      device,
      &address,
      0,
      nil,
      UInt32(MemoryLayout<UInt32>.size * pair.count),
      &pair
    )
  }

  private func readStereoPair(_ device: AudioDeviceID) -> [UInt32] {
    var pair = [UInt32](repeating: 0, count: 2)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<UInt32>.size * pair.count)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &pair)
    if status != noErr { return [1, 2] }
    return pair
  }

  private func setFloatFormat(_ device: AudioDeviceID, rate: Double, channels: Int) -> OSStatus {
    var format = AudioStreamBasicDescription()
    let count = UInt32(max(channels, 1))
    format.mSampleRate = rate
    format.mFormatID = kAudioFormatLinearPCM
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked
    format.mBitsPerChannel = 32
    format.mChannelsPerFrame = count
    format.mFramesPerPacket = 1
    format.mBytesPerFrame = count * 4
    format.mBytesPerPacket = format.mBytesPerFrame
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    return AudioObjectSetPropertyData(
      device,
      &address,
      0,
      nil,
      UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
      &format
    )
  }
}
