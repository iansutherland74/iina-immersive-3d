//
//  CaptureAudioRoute.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Installs the bundled HAL plugin, points the system output at it while a
//  capture is running, and puts the previous output back. The player's device
//  is pinned first so IINA does not play into the loopback.

import AVFoundation
import AudioToolbox
import Cocoa
import CoreAudio
import os

enum CaptureOutputRestoreFile {
  static func url() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base
      .appendingPathComponent("com.colliderli.iina", isDirectory: true)
      .appendingPathComponent("capture-output-restore.txt")
  }

  static func write(_ uid: String) {
    let file = url()
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try uid.write(to: file, atomically: true, encoding: .utf8)
    } catch {
      browserCaptureLog.error("could not save the previous output")
    }
  }

  static func read() -> String? {
    guard let text = try? String(contentsOf: url(), encoding: .utf8) else { return nil }
    let uid = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return uid.isEmpty ? nil : uid
  }

  static func delete() {
    try? FileManager.default.removeItem(at: url())
  }
}

enum CaptureSystemOutput {
  static func ourDeviceInstalled() -> Bool {
    deviceID(forUID: CaptureOutputRoute.virtualUID) != nil
  }

  static func currentOutputUID() -> String? {
    let id = defaultOutputID()
    guard id != 0, let uid = copyString(id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
    return uid
  }

  /// Sets the default output and the default system output, then reads both back.
  /// A `noErr` that did not stick is a failure. The OSStatus and the device ids are logged.
  static func setOutputUID(_ uid: String) -> Bool {
    let translated = translate(uid)
    let id = translated.id ?? deviceIDByScanning(uid)
    guard let id, id != 0 else {
      let status = CaptureDefaultOutput.statusText(translated.status)
      captureAudioNote("could not change the default output uid=\(uid) status=\(status) device=0", error: true)
      return false
    }
    if translated.id == nil {
      captureAudioNote("TranslateUIDToDevice missed \(uid) status=\(CaptureDefaultOutput.statusText(translated.status)); using device \(id)", error: true)
    }
    let selectors: [(AudioObjectPropertySelector, String)] = [
      (kAudioHardwarePropertyDefaultOutputDevice, "DefaultOutputDevice"),
      (kAudioHardwarePropertyDefaultSystemOutputDevice, "DefaultSystemOutputDevice")
    ]
    var writes: [CaptureDefaultOutput.Write] = []
    for (selector, name) in selectors {
      let status = writeSystemDevice(selector, id)
      let readBack = readSystemDevice(selector)
      writes.append(CaptureDefaultOutput.Write(status: status, readBack: readBack))
      if status != noErr || readBack != id {
        let text = CaptureDefaultOutput.statusText(status)
        captureAudioNote("could not change the default output uid=\(uid) device=\(id) \(name) status=\(text) readBack=\(readBack)", error: true)
      }
    }
    let ok = CaptureDefaultOutput.accepted(deviceID: id, writes: writes)
    if ok {
      captureAudioNote("default output is \(uid) device=\(id) status=0")
    }
    return ok
  }

  /// IINA Capture Audio's output scalar and mute. A scalar of 0 makes every
  /// ReadInput silent, so the glasses play nothing even when the browser is loud.
  static func ensureLoopbackAudible(device: AudioDeviceID) -> String {
    guard device != 0 else { return "loopback device volume=none" }
    let controls = outputControls(device)
    var scalar: Float?
    var mute: UInt32?
    var volumeControl: AudioObjectID?
    var muteControl: AudioObjectID?
    for control in controls {
      let kind = classID(control)
      if kind == kAudioVolumeControlClassID, scalar == nil, let value = scalarVolume(of: control) {
        scalar = value
        volumeControl = control
      } else if kind == kAudioMuteControlClassID, mute == nil, let value = muteValue(of: control) {
        mute = value
        muteControl = control
      }
    }
    guard scalar != nil || mute != nil else { return "loopback device volume=none" }
    let shown = scalar ?? 1
    let muted = (mute ?? 0) != 0
    var line = String(format: "loopback device volume=%.4f mute=%d", shown, muted ? 1 : 0)
    if let volumeControl, let restored = CaptureDeviceGain.restoredScalar(shown) {
      let status = setScalarVolume(of: volumeControl, scalar: restored)
      line += " set to 1 status=\(CaptureDefaultOutput.statusText(status))"
    }
    if let muteControl, CaptureDeviceGain.shouldClearMute(muted) {
      let status = setMute(of: muteControl, muted: false)
      line += " cleared mute status=\(CaptureDefaultOutput.statusText(status))"
    }
    return line
  }

  private static func outputControls(_ device: AudioDeviceID) -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyControlList,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
  }

  private static func classID(_ object: AudioObjectID) -> AudioClassID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyClass,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value = AudioClassID(0)
    var size = UInt32(MemoryLayout<AudioClassID>.size)
    AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    return value
  }

  private static func scalarVolume(of control: AudioObjectID) -> Float? {
    readFloat(control, selector: kAudioLevelControlPropertyScalarValue)
  }

  private static func setScalarVolume(of control: AudioObjectID, scalar: Float) -> OSStatus {
    writeValue(control, selector: kAudioLevelControlPropertyScalarValue, value: scalar)
  }

  private static func muteValue(of control: AudioObjectID) -> UInt32? {
    readUInt32(control, selector: kAudioBooleanControlPropertyValue)
  }

  private static func setMute(of control: AudioObjectID, muted: Bool) -> OSStatus {
    writeValue(control, selector: kAudioBooleanControlPropertyValue, value: muted ? UInt32(1) : UInt32(0))
  }

  private static func readFloat(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> Float? {
    for scope in [kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyScopeOutput] {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
      )
      var value: Float32 = 0
      var size = UInt32(MemoryLayout<Float32>.size)
      if AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr {
        return value
      }
    }
    return nil
  }

  private static func readUInt32(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
    for scope in [kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyScopeOutput] {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
      )
      var value: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      if AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr {
        return value
      }
    }
    return nil
  }

  private static func writeValue<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector, value: T) -> OSStatus {
    var value = value
    var last = kAudioHardwareUnknownPropertyError
    for scope in [kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyScopeOutput] {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
      )
      last = withUnsafePointer(to: &value) { pointer in
        AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), pointer)
      }
      if last == noErr { return last }
    }
    return last
  }

  static func firstRealOutputUID() -> String? {
    devices().first { device in
      device.uid != CaptureOutputRoute.virtualUID && !CaptureAudioPolicy.looksVirtual(name: device.name, uid: device.uid)
    }?.uid
  }

  static func waitForOurDevice(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if ourDeviceInstalled() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return ourDeviceInstalled()
  }

  static func deviceID(forUID uid: String) -> AudioDeviceID? {
    if let id = translate(uid).id { return id }
    return deviceIDByScanning(uid)
  }

  /// The qualifier is a CFStringRef. Its size is a pointer, not the Swift class layout.
  private static func translate(_ uid: String) -> (id: AudioDeviceID?, status: OSStatus) {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var name = uid as CFString
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      UInt32(MemoryLayout<UnsafeRawPointer>.size),
      &name,
      &size,
      &device
    )
    guard status == noErr, device != 0 else { return (nil, status) }
    return (device, status)
  }

  private static func deviceIDByScanning(_ uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return nil }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids) == noErr else { return nil }
    for id in ids where copyString(id, selector: kAudioDevicePropertyDeviceUID) == uid {
      return id
    }
    return nil
  }

  private static func writeSystemDevice(_ selector: AudioObjectPropertySelector, _ device: AudioDeviceID) -> OSStatus {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value = device
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &value)
  }

  private static func readSystemDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return device
  }

  private static func defaultOutputID() -> AudioDeviceID {
    readSystemDevice(kAudioHardwarePropertyDefaultOutputDevice)
  }

  private static func devices() -> [(name: String, uid: String)] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids) == noErr else { return [] }
    return ids.compactMap { id in
      guard hasOutputStream(id),
            let name = copyString(id, selector: kAudioDevicePropertyDeviceNameCFString),
            let uid = copyString(id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
      return (name, uid)
    }
  }

  private static func hasOutputStream(_ device: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
    return size >= UInt32(MemoryLayout<AudioStreamID>.size)
  }

  /// Device name and UID are +1 CFStrings. The buffer is one pointer.
  private static func copyString(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
    guard status == noErr, let name else { return nil }
    return name.takeRetainedValue() as String
  }
}

func captureAudioNote(_ line: String, error: Bool = false) {
  CaptureAudioFileLog.append(line)
  if error {
    browserCaptureLog.error("\(line, privacy: .public)")
  } else {
    browserCaptureLog.info("\(line, privacy: .public)")
  }
}

enum CaptureAudioInstaller {
  static let installedPath = "/Library/Audio/Plug-Ins/HAL/IINACaptureAudio.driver"

  static func bundledDriverURL() -> URL? {
    Bundle.main.url(forResource: "IINACaptureAudio", withExtension: "driver")
  }

  static func install() -> Bool {
    guard let source = bundledDriverURL() else {
      browserCaptureLog.error("IINA Capture Audio is not in the app bundle")
      return false
    }
    let shell = "mkdir -p /Library/Audio/Plug-Ins/HAL && rm -rf \(shellQuote(installedPath)) && cp -R \(shellQuote(source.path)) \(shellQuote(installedPath)) && chmod -R a+rX \(shellQuote(installedPath)) && (launchctl kickstart -kp system/com.apple.audio.coreaudiod || killall coreaudiod)"
    guard runAdministratorShell(shell) else { return false }
    return CaptureSystemOutput.waitForOurDevice(timeout: 4)
  }

  static func uninstall() -> Bool {
    let shell = "rm -rf \(shellQuote(installedPath)) && (launchctl kickstart -kp system/com.apple.audio.coreaudiod || killall coreaudiod)"
    return runAdministratorShell(shell)
  }

  private static func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func runAdministratorShell(_ shell: String) -> Bool {
    let escaped = shell
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else {
      return false
    }
    var error: NSDictionary?
    _ = script.executeAndReturnError(&error)
    if let error {
      let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
      if number == -128 {
        browserCaptureLog.info("the admin prompt for IINA Capture Audio was cancelled")
      } else {
        browserCaptureLog.error("IINA Capture Audio install failed")
      }
      return false
    }
    return true
  }
}

enum CaptureAudioRouteController {
  private static let lock = NSLock()
  private static var state = CaptureOutputRoute.State()

  /// Called before mpv opens a device. A crash during capture leaves every app
  /// playing into the loopback; this puts the saved output back.
  static func recoverIfNeeded() {
    let saved = CaptureOutputRestoreFile.read()
    let plan = CaptureOutputRoute.recover(state: CaptureOutputRoute.State(crashUID: saved))
    guard !plan.effects.isEmpty else { return }
    var restored = false
    for effect in plan.effects {
      switch effect {
      case .setSystemOutput(let uid):
        restored = CaptureSystemOutput.setOutputUID(uid)
        if !restored, let fallback = CaptureSystemOutput.firstRealOutputUID(), fallback != uid {
          restored = CaptureSystemOutput.setOutputUID(fallback)
        }
      case .deleteCrashFile:
        break
      case .writeCrashFile, .setMPVDevice:
        break
      }
    }
    if restored {
      CaptureOutputRestoreFile.delete()
      lock.lock()
      state = CaptureOutputRoute.State()
      lock.unlock()
      captureAudioNote("restored the default output after a capture crash status=0")
    }
  }

  @available(macOS 12.3, *)
  static func beginIfEnabled() -> CaptureOutputRoute.BeginResult {
    guard BrowserCaptureManager.shared.isRunning else {
      return .refused(.notCapturing)
    }
    let plan = lockedEngage()
    switch plan.began {
    case .routed:
      guard apply(plan.effects) else {
        end()
        return .refused(.missingDevice)
      }
      if case .routed(let saved, _) = plan.state.phase {
        guard BrowserCaptureManager.shared.startRoutedAudio(realUID: saved.outputUID) else {
          end()
          return .refused(.missingDevice)
        }
      }
      captureAudioNote("routed browser audio through IINA Capture Audio")
      return .routed
    case .already:
      lock.lock()
      let current = state
      lock.unlock()
      if case .routed(let saved, _) = current.phase {
        BrowserCaptureManager.shared.startRoutedAudio(realUID: saved.outputUID)
      }
      return .already
    case .refused:
      return plan.began
    }
  }

  @available(macOS 12.3, *)
  static func end() {
    lock.lock()
    let plan = CaptureOutputRoute.end(state: state)
    state = plan.state
    lock.unlock()
    guard !plan.effects.isEmpty else { return }
    BrowserCaptureManager.shared.stopRoutedAudio()
    if apply(plan.effects) {
      captureAudioNote("restored the default output after browser capture status=0")
    } else {
      captureAudioNote("the default output was not restored after browser capture", error: true)
    }
  }

  private static func lockedEngage() -> CaptureOutputRoute.Plan {
    let enabled = BrowserCaptureSettings.shared.wantsAudio
    let installed = CaptureSystemOutput.ourDeviceInstalled()
    let current = CaptureOutputRoute.Snapshot(
      outputUID: CaptureSystemOutput.currentOutputUID() ?? "",
      mpvDevice: currentMPVDevice()
    )
    lock.lock()
    let plan = CaptureOutputRoute.engage(
      state: state,
      capturing: true,
      enabled: enabled,
      installed: installed,
      current: current,
      fallbackRealUID: CaptureSystemOutput.firstRealOutputUID()
    )
    if plan.began == .routed {
      state = plan.state
    }
    lock.unlock()
    return plan
  }

  private static func currentMPVDevice() -> String {
    guard !PlayerCore.playerCores.isEmpty else { return "auto" }
    return PlayerCore.active.mpv.getString(MPVProperty.audioDevice) ?? "auto"
  }

  @discardableResult
  private static func apply(_ effects: [CaptureOutputRoute.Effect]) -> Bool {
    var outputOK = true
    for effect in effects {
      switch effect {
      case .writeCrashFile(let uid):
        CaptureOutputRestoreFile.write(uid)
      case .deleteCrashFile:
        if outputOK {
          CaptureOutputRestoreFile.delete()
        }
      case .setMPVDevice(let name):
        guard !PlayerCore.playerCores.isEmpty else { continue }
        for core in PlayerCore.playerCores {
          core.setAudioDevice(name)
        }
      case .setSystemOutput(let uid):
        if !CaptureSystemOutput.setOutputUID(uid) {
          outputOK = false
        }
      }
    }
    return outputOK
  }
}

/// Reads the virtual device's input. The output half of the same IO proc is
/// silence, and the driver adds that silence instead of replacing the browser.
final class CaptureLoopbackReader {
  var onSamples: ((AVAudioPCMBuffer, CFTimeInterval) -> Void)?

  private let queue = DispatchQueue(label: "com.colliderli.iina.capture-loopback", qos: .userInteractive)
  private let slotLock = NSLock()
  private let ioLock = NSLock()
  private var slots: [Slot] = (0..<16).map { _ in Slot() }
  private var device = AudioDeviceID(0)
  private var procID: AudioDeviceIOProcID?
  private var timer: DispatchSourceTimer?
  private var running = false
  private var dropped = 0
  private var lastLevelLog: CFTimeInterval = 0
  private var levelSum: Float = 0
  private var levelCount = 0
  private var loggedSignal = false
  private var startGeneration = 0
  private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)

  private struct Slot {
    var samples = [Float](repeating: 0, count: 4096 * 2)
    var frames = 0
    var host = 0.0
    var full = false
  }

  func start() -> Bool {
    guard CaptureSystemOutput.deviceID(forUID: CaptureOutputRoute.virtualUID) != nil, format != nil else {
      captureAudioNote("loopback reader did not start device=0 status=\(CaptureDefaultOutput.statusText(kAudioHardwareBadDeviceError))", error: true)
      return false
    }
    stop()
    ioLock.lock()
    startGeneration += 1
    let generation = startGeneration
    ioLock.unlock()
    let described = CaptureMicAccess.usageDescriptionPresent(Bundle.main.infoDictionary)
    let authorization = Self.microphoneAuthorization()
    captureAudioNote(
      CaptureMicAccess.logLine(status: authorization, usageDescriptionPresent: described),
      error: CaptureMicAccess.inputWillBeSilence(authorization)
    )
    if CaptureMicAccess.waitForDecision(authorization) {
      guard described else {
        captureAudioNote("loopback mic authorization not requested usageDescription=missing", error: true)
        return startIO(generation: generation)
      }
      captureAudioNote("loopback mic authorization requesting")
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
        let after: CaptureMicAuthorization = granted ? .authorized : .denied
        captureAudioNote(CaptureMicAccess.logLine(status: after, usageDescriptionPresent: true), error: !granted)
        self?.queue.async {
          guard let self else { return }
          if !self.startIO(generation: generation) {
            captureAudioNote("loopback reader did not start after mic authorization", error: true)
          }
        }
      }
      return true
    }
    return startIO(generation: generation)
  }

  private static func microphoneAuthorization() -> CaptureMicAuthorization {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return .authorized
    case .denied:
      return .denied
    case .restricted:
      return .restricted
    case .notDetermined:
      return .notDetermined
    @unknown default:
      return .notDetermined
    }
  }

  /// `false` only when this generation is still current and the device did not
  /// start. A stop that landed during the microphone prompt is not a failure.
  private func startIO(generation: Int) -> Bool {
    ioLock.lock()
    let current = startGeneration == generation
    ioLock.unlock()
    guard current else { return true }
    guard let id = CaptureSystemOutput.deviceID(forUID: CaptureOutputRoute.virtualUID), format != nil else {
      captureAudioNote("loopback reader did not start device=0 status=\(CaptureDefaultOutput.statusText(kAudioHardwareBadDeviceError))", error: true)
      return false
    }
    var created: AudioDeviceIOProcID?
    let status = AudioDeviceCreateIOProcID(id, Self.ioProc, Unmanaged.passUnretained(self).toOpaque(), &created)
    guard status == noErr, let created else {
      captureAudioNote("loopback reader did not start status=\(CaptureDefaultOutput.statusText(status)) device=\(id)", error: true)
      return false
    }
    let started = AudioDeviceStart(id, created)
    guard started == noErr else {
      AudioDeviceDestroyIOProcID(id, created)
      captureAudioNote("loopback reader did not start status=\(CaptureDefaultOutput.statusText(started)) device=\(id)", error: true)
      return false
    }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 0.01, repeating: 0.01)
    timer.setEventHandler { [weak self] in
      self?.drain()
    }
    ioLock.lock()
    if startGeneration != generation {
      ioLock.unlock()
      timer.cancel()
      timer.resume()
      AudioDeviceStop(id, created)
      AudioDeviceDestroyIOProcID(id, created)
      return true
    }
    device = id
    procID = created
    running = true
    dropped = 0
    lastLevelLog = 0
    levelSum = 0
    levelCount = 0
    loggedSignal = false
    self.timer = timer
    timer.resume()
    ioLock.unlock()
    captureAudioNote("loopback reader started device=\(id) uid=\(CaptureOutputRoute.virtualUID) format=48000 Hz 2ch float32")
    captureAudioNote(CaptureSystemOutput.ensureLoopbackAudible(device: id))
    return true
  }

  func stop() {
    ioLock.lock()
    startGeneration += 1
    let proc = procID
    let dev = device
    procID = nil
    running = false
    let pending = timer
    timer = nil
    ioLock.unlock()
    pending?.cancel()
    if let proc {
      AudioDeviceStop(dev, proc)
      AudioDeviceDestroyIOProcID(dev, proc)
    }
    slotLock.lock()
    for index in slots.indices {
      slots[index].full = false
    }
    slotLock.unlock()
  }

  private static let ioProc: AudioDeviceIOProc = { _, _, input, _, output, _, client in
    guard let client else { return noErr }
    let reader = Unmanaged<CaptureLoopbackReader>.fromOpaque(client).takeUnretainedValue()
    reader.handle(input: input, output: output)
    return noErr
  }

  private func handle(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
    let outputs = UnsafeMutableAudioBufferListPointer(output)
    for buffer in outputs {
      if let data = buffer.mData {
        memset(data, 0, Int(buffer.mDataByteSize))
      }
    }
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard let first = inputs.first, let data = first.mData else { return }
    if first.mNumberChannels >= 2 {
      let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
      store(frames: frames) { destination in
        memcpy(destination, data, frames * 2 * MemoryLayout<Float>.size)
      }
      return
    }
    guard inputs.count >= 2, let right = inputs[1].mData else { return }
    let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
    let left = data
    store(frames: frames) { destination in
      let samples = destination.assumingMemoryBound(to: Float.self)
      let leftSamples = left.assumingMemoryBound(to: Float.self)
      let rightSamples = right.assumingMemoryBound(to: Float.self)
      for index in 0..<frames {
        samples[index * 2] = leftSamples[index]
        samples[index * 2 + 1] = rightSamples[index]
      }
    }
  }

  private func store(frames: Int, write: (UnsafeMutableRawPointer) -> Void) {
    guard frames > 0, frames <= 4096 else {
      slotLock.lock()
      dropped += 1
      slotLock.unlock()
      return
    }
    slotLock.lock()
    defer { slotLock.unlock() }
    guard let index = slots.firstIndex(where: { !$0.full }) else {
      dropped += 1
      return
    }
    slots[index].samples.withUnsafeMutableBytes { raw in
      guard let base = raw.baseAddress else { return }
      write(base)
    }
    slots[index].frames = frames
    slots[index].host = CACurrentMediaTime() - Double(frames) / 48000.0
    slots[index].full = true
  }

  private func drain() {
    guard running, let format else { return }
    var ready: [(host: Double, samples: [Float], frames: Int)] = []
    slotLock.lock()
    for index in slots.indices where slots[index].full {
      let frames = slots[index].frames
      ready.append((
        slots[index].host,
        Array(slots[index].samples.prefix(frames * 2)),
        frames
      ))
      slots[index].full = false
    }
    let missed = dropped
    dropped = 0
    slotLock.unlock()
    if missed > 0 {
      captureAudioNote("loopback reader dropped \(missed) buffers", error: true)
    }
    if ready.isEmpty {
      let now = CACurrentMediaTime()
      if lastLevelLog == 0 || now - lastLevelLog >= 1 {
        lastLevelLog = now
        captureAudioNote("loopback in rms=0.0000 samples=none")
      }
    } else {
      noteInputLevel(ready)
    }
    for chunk in ready {
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.frames)) else { continue }
      buffer.frameLength = AVAudioFrameCount(chunk.frames)
      let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData
      guard let destination else { continue }
      chunk.samples.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        memcpy(destination, base, chunk.frames * 2 * MemoryLayout<Float>.size)
      }
      onSamples?(buffer, chunk.host)
    }
  }

  private func noteInputLevel(_ ready: [(host: Double, samples: [Float], frames: Int)]) {
    var sum: Float = 0
    var count = 0
    for chunk in ready {
      let step = max(chunk.samples.count / 256, 1)
      var index = 0
      while index < chunk.samples.count {
        let sample = chunk.samples[index]
        sum += sample * sample
        count += 1
        index += step
      }
    }
    let level = sqrt(sum / Float(max(count, 1)))
    levelSum += level
    levelCount += 1
    let now = CACurrentMediaTime()
    if lastLevelLog != 0 && now - lastLevelLog < 1 { return }
    lastLevelLog = now
    let mean = levelSum / Float(max(levelCount, 1))
    levelSum = 0
    levelCount = 0
    if mean > 0.0001 {
      if !loggedSignal {
        loggedSignal = true
        captureAudioNote(String(format: "loopback in signal rms=%.4f", mean))
      }
      captureAudioNote(String(format: "loopback in rms=%.4f", mean))
    } else {
      captureAudioNote(String(format: "loopback in rms=%.4f samples=silence", mean))
    }
  }
}

/// Plays loopback samples on the real output named in the restore file.
/// AVAudioEngine stays at 48 kHz and does not follow a DisplayPort device that
/// is 44.1 kHz, which is why the glasses were silent.
final class CaptureLoopbackOutput {
  struct Outcome {
    enum Kind {
      case started
      case already
      case failed
    }

    var kind: Kind
    var device: AudioDeviceID
    var status: OSStatus
    var rate: Double
    var channels: Int
    var uid: String
  }

  private let lock = NSLock()
  private var device = AudioDeviceID(0)
  private var procID: AudioDeviceIOProcID?
  private var plan = CapturePlaybackRoute.plan(sampleRate: 48000, channels: 2, bits: 32, isFloat: true, interleaved: true)
  private var ring = [Float](repeating: 0, count: 48000 * 2)
  private var readFrame = 0
  private var writeFrame = 0
  private var storedFrames = 0
  private var resampler = CaptureRateConvert.Stream(fromRate: 48000, toRate: 48000, channels: 2)
  private var gain: Float = 1
  private var activeUID = ""
  private var scratch = [Float](repeating: 0, count: 4096 * 2)

  func setGain(_ value: Float) {
    lock.lock()
    gain = min(max(value, 0), 1)
    lock.unlock()
  }

  func start(uid: String, force: Bool = false) -> Outcome {
    let playback = CapturePlaybackRoute.uid(restore: CaptureOutputRestoreFile.read(), pinned: uid) ?? ""
    guard !playback.isEmpty, let id = CaptureSystemOutput.deviceID(forUID: playback), id != 0 else {
      return Outcome(kind: .failed, device: 0, status: kAudioHardwareBadDeviceError, rate: 0, channels: 0, uid: playback)
    }
    guard var format = Self.outputFormat(of: id) else {
      return Outcome(kind: .failed, device: id, status: kAudioHardwareIllegalOperationError, rate: 0, channels: 0, uid: playback)
    }
    var next = CapturePlaybackRoute.plan(
      sampleRate: format.mSampleRate,
      channels: Int(format.mChannelsPerFrame),
      bits: Int(format.mBitsPerChannel),
      isFloat: format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
      interleaved: format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    )
    if next.encoding == .unsupported {
      let channels = min(max(Int(format.mChannelsPerFrame), 2), 2)
      let status = Self.setFloatFormat(of: id, rate: format.mSampleRate > 0 ? format.mSampleRate : 48000, channels: channels)
      guard status == noErr, let updated = Self.outputFormat(of: id) else {
        return Outcome(kind: .failed, device: id, status: status, rate: format.mSampleRate, channels: Int(format.mChannelsPerFrame), uid: playback)
      }
      format = updated
      next = CapturePlaybackRoute.plan(
        sampleRate: format.mSampleRate,
        channels: Int(format.mChannelsPerFrame),
        bits: Int(format.mBitsPerChannel),
        isFloat: format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
        interleaved: format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
      )
      guard next.encoding != .unsupported else {
        return Outcome(kind: .failed, device: id, status: kAudioHardwareIllegalOperationError, rate: next.sampleRate, channels: next.channels, uid: playback)
      }
    }
    if !force && procID != nil && device == id && plan == next && activeUID == playback {
      return Outcome(kind: .already, device: id, status: noErr, rate: next.sampleRate, channels: next.channels, uid: playback)
    }
    stopProc()
    if plan.sampleRate != next.sampleRate {
      lock.lock()
      storedFrames = 0
      readFrame = 0
      writeFrame = 0
      lock.unlock()
    }
    plan = next
    resampler.reset(fromRate: 48000, toRate: next.sampleRate, channels: 2)
    var created: AudioDeviceIOProcID?
    let createdStatus = AudioDeviceCreateIOProcID(id, Self.ioProc, Unmanaged.passUnretained(self).toOpaque(), &created)
    guard createdStatus == noErr, let created else {
      return Outcome(kind: .failed, device: id, status: createdStatus, rate: next.sampleRate, channels: next.channels, uid: playback)
    }
    let started = AudioDeviceStart(id, created)
    guard started == noErr else {
      AudioDeviceDestroyIOProcID(id, created)
      return Outcome(kind: .failed, device: id, status: started, rate: next.sampleRate, channels: next.channels, uid: playback)
    }
    device = id
    procID = created
    activeUID = playback
    return Outcome(kind: .started, device: id, status: started, rate: next.sampleRate, channels: next.channels, uid: playback)
  }

  func stop() {
    stopProc()
    lock.lock()
    storedFrames = 0
    readFrame = 0
    writeFrame = 0
    lock.unlock()
    resampler.reset(fromRate: 48000, toRate: plan.sampleRate, channels: 2)
  }

  func enqueue(_ buffer: AVAudioPCMBuffer) {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return }
    var interleaved: [Float]
    if let channels = buffer.floatChannelData, !buffer.format.isInterleaved {
      let count = min(Int(buffer.format.channelCount), 2)
      interleaved = [Float](repeating: 0, count: frames * 2)
      let left = channels[0]
      let right = count > 1 ? channels[1] : channels[0]
      for frame in 0..<frames {
        interleaved[frame * 2] = left[frame]
        interleaved[frame * 2 + 1] = right[frame]
      }
    } else if let data = buffer.audioBufferList.pointee.mBuffers.mData {
      interleaved = [Float](repeating: 0, count: frames * 2)
      let source = data.assumingMemoryBound(to: Float.self)
      let channels = max(Int(buffer.format.channelCount), 1)
      for frame in 0..<frames {
        interleaved[frame * 2] = source[frame * channels]
        interleaved[frame * 2 + 1] = channels > 1 ? source[frame * channels + 1] : source[frame * channels]
      }
    } else {
      return
    }
    let converted = resampler.process(interleaved)
    guard converted.count >= 2 else { return }
    lock.lock()
    push(converted)
    lock.unlock()
  }

  private func stopProc() {
    if let procID {
      AudioDeviceStop(device, procID)
      AudioDeviceDestroyIOProcID(device, procID)
      self.procID = nil
    }
  }

  private static let ioProc: AudioDeviceIOProc = { _, _, _, _, output, _, client in
    guard let client else { return noErr }
    let outputDevice = Unmanaged<CaptureLoopbackOutput>.fromOpaque(client).takeUnretainedValue()
    outputDevice.render(output)
    return noErr
  }

  private func render(_ output: UnsafeMutablePointer<AudioBufferList>) {
    let buffers = UnsafeMutableAudioBufferListPointer(output)
    guard let first = buffers.first, let data = first.mData, first.mDataByteSize > 0 else { return }
    let encoding = plan.encoding
    let frames: Int
    switch encoding {
    case .float32Interleaved:
      let channels = max(Int(first.mNumberChannels), 1)
      frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
    case .float32Planar:
      frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
    case .int16Interleaved:
      let channels = max(Int(first.mNumberChannels), 1)
      frames = Int(first.mDataByteSize) / (MemoryLayout<Int16>.size * channels)
    case .unsupported:
      return
    }
    guard frames > 0 else { return }
    let chunk = scratch.count / 2
    var done = 0
    while done < frames {
      let count = min(chunk, frames - done)
      fillScratch(count)
      switch encoding {
      case .float32Interleaved:
        writeInterleavedFloat(data, frames: count, channels: max(Int(first.mNumberChannels), 1), offset: done)
      case .int16Interleaved:
        writeInterleavedInt16(data, frames: count, channels: max(Int(first.mNumberChannels), 1), offset: done)
      case .float32Planar:
        writePlanarFloat(buffers, frames: count, offset: done)
      case .unsupported:
        return
      }
      done += count
    }
  }

  private func fillScratch(_ frames: Int) {
    lock.lock()
    let gained = gain
    let count = min(frames, storedFrames)
    for index in 0..<count {
      let source = readFrame * 2
      scratch[index * 2] = ring[source] * gained
      scratch[index * 2 + 1] = ring[source + 1] * gained
      readFrame = (readFrame + 1) % (ring.count / 2)
    }
    storedFrames -= count
    lock.unlock()
    if count < frames {
      for index in count..<frames {
        scratch[index * 2] = 0
        scratch[index * 2 + 1] = 0
      }
    }
  }

  private func writeInterleavedFloat(_ data: UnsafeMutableRawPointer, frames: Int, channels: Int, offset: Int) {
    let destination = data.assumingMemoryBound(to: Float.self)
    for frame in 0..<frames {
      let at = offset + frame
      destination[at * channels] = scratch[frame * 2]
      if channels > 1 {
        destination[at * channels + 1] = scratch[frame * 2 + 1]
      }
      if channels > 2 {
        for channel in 2..<channels {
          destination[at * channels + channel] = 0
        }
      }
    }
  }

  private func writeInterleavedInt16(_ data: UnsafeMutableRawPointer, frames: Int, channels: Int, offset: Int) {
    let destination = data.assumingMemoryBound(to: Int16.self)
    for frame in 0..<frames {
      let at = offset + frame
      destination[at * channels] = CaptureRateConvert.int16(scratch[frame * 2])
      if channels > 1 {
        destination[at * channels + 1] = CaptureRateConvert.int16(scratch[frame * 2 + 1])
      }
      if channels > 2 {
        for channel in 2..<channels {
          destination[at * channels + channel] = 0
        }
      }
    }
  }

  private func writePlanarFloat(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, offset: Int) {
    guard let left = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
    let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
    for frame in 0..<frames {
      left[offset + frame] = scratch[frame * 2]
      right?[offset + frame] = scratch[frame * 2 + 1]
    }
  }

  private func push(_ interleaved: [Float]) {
    let frames = interleaved.count / 2
    guard frames > 0 else { return }
    let capacity = ring.count / 2
    let incoming = min(frames, capacity)
    let start = (frames - incoming) * 2
    while storedFrames + incoming > capacity {
      readFrame = (readFrame + 1) % capacity
      storedFrames -= 1
    }
    for index in 0..<incoming {
      let destination = writeFrame * 2
      ring[destination] = interleaved[start + index * 2]
      ring[destination + 1] = interleaved[start + index * 2 + 1]
      writeFrame = (writeFrame + 1) % capacity
    }
    storedFrames += incoming
  }

  private static func outputFormat(of device: AudioDeviceID) -> AudioStreamBasicDescription? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format)
    guard status == noErr, format.mSampleRate > 0, format.mChannelsPerFrame > 0 else { return nil }
    return format
  }

  private static func setFloatFormat(of device: AudioDeviceID, rate: Double, channels: Int) -> OSStatus {
    var format = AudioStreamBasicDescription()
    format.mSampleRate = rate
    format.mFormatID = kAudioFormatLinearPCM
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked
    format.mBytesPerPacket = UInt32(channels * MemoryLayout<Float>.size)
    format.mFramesPerPacket = 1
    format.mBytesPerFrame = format.mBytesPerPacket
    format.mChannelsPerFrame = UInt32(channels)
    format.mBitsPerChannel = 32
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format)
  }
}

/// ±500 ms on top of the measured delay. The same control is used in the capture
/// window, the glasses panel, and Settings.
final class CaptureSyncOffsetControl: NSView {
  enum Placement {
    case controls
    case overlay
    case settings
  }

  private let placement: Placement
  private let slider = NSSlider()
  private let label = NSTextField(labelWithString: "")
  private var observers: [NSObjectProtocol] = []

  init(placement: Placement) {
    self.placement = placement
    super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
    slider.minValue = Double(CaptureSyncOffset.minMs)
    slider.maxValue = Double(CaptureSyncOffset.maxMs)
    slider.isContinuous = true
    slider.target = self
    slider.action = #selector(sliderChanged(_:))
    label.font = .systemFont(ofSize: 12)
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    slider.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    addSubview(slider)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.widthAnchor.constraint(equalToConstant: 150),
      slider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
      slider.trailingAnchor.constraint(equalTo: trailingAnchor),
      slider.centerYAnchor.constraint(equalTo: centerYAnchor),
      heightAnchor.constraint(equalToConstant: 28)
    ])
    show(BrowserCaptureSettings.shared.syncOffsetMs)
    applyRoute()
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: CaptureSyncOffset.changedNotification, object: nil, queue: .main) { [weak self] _ in
      self?.show(BrowserCaptureSettings.shared.syncOffsetMs)
    })
    observers.append(center.addObserver(forName: CaptureSyncOffset.routeChangedNotification, object: nil, queue: .main) { [weak self] _ in
      self?.applyRoute()
    })
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 420, height: 28)
  }

  private func show(_ ms: Int) {
    let clamped = CaptureSyncOffset.clamp(ms)
    if Int(slider.doubleValue.rounded()) != clamped {
      slider.doubleValue = Double(clamped)
    }
    label.stringValue = CaptureSyncOffset.label(ms: clamped)
  }

  private func applyRoute() {
    let on = BrowserCaptureSettings.shared.wantsAudio
    switch placement {
    case .controls:
      isHidden = false
      slider.isEnabled = on
      label.textColor = on ? .labelColor : .secondaryLabelColor
    case .overlay:
      isHidden = !on
      slider.isEnabled = on
      label.textColor = .labelColor
    case .settings:
      isHidden = false
      slider.isEnabled = true
      label.textColor = .labelColor
    }
  }

  @objc private func sliderChanged(_ sender: NSSlider) {
    BrowserCaptureSettings.shared.setSyncOffset(ms: Int(sender.doubleValue.rounded()))
  }
}
