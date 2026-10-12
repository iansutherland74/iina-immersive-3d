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

  static func setOutputUID(_ uid: String) -> Bool {
    guard let id = deviceID(forUID: uid), id != 0 else { return false }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var device = id
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &device)
    return status == noErr
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
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let name = uid as CFString
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

  private static func defaultOutputID() -> AudioDeviceID {
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
      browserCaptureLog.info("restored the default output after a capture crash")
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
      browserCaptureLog.info("routed browser audio through IINA Capture Audio")
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
    _ = apply(plan.effects)
    browserCaptureLog.info("restored the default output after browser capture")
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
        CaptureOutputRestoreFile.delete()
      case .setMPVDevice(let name):
        guard !PlayerCore.playerCores.isEmpty else { continue }
        for core in PlayerCore.playerCores {
          core.setAudioDevice(name)
        }
      case .setSystemOutput(let uid):
        if !CaptureSystemOutput.setOutputUID(uid) {
          outputOK = false
          browserCaptureLog.error("could not change the default output")
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
  private var slots: [Slot] = (0..<16).map { _ in Slot() }
  private var device = AudioDeviceID(0)
  private var procID: AudioDeviceIOProcID?
  private var timer: DispatchSourceTimer?
  private var running = false
  private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)

  private struct Slot {
    var samples = [Float](repeating: 0, count: 4096 * 2)
    var frames = 0
    var host = 0.0
    var full = false
  }

  func start() -> Bool {
    guard let id = CaptureSystemOutput.deviceID(forUID: CaptureOutputRoute.virtualUID), let format else { return false }
    stop()
    var created: AudioDeviceIOProcID?
    let status = AudioDeviceCreateIOProcID(id, Self.ioProc, Unmanaged.passUnretained(self).toOpaque(), &created)
    guard status == noErr, let created else { return false }
    guard AudioDeviceStart(id, created) == noErr else {
      AudioDeviceDestroyIOProcID(id, created)
      return false
    }
    device = id
    procID = created
    running = true
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 0.01, repeating: 0.01)
    timer.setEventHandler { [weak self] in
      self?.drain()
    }
    self.timer = timer
    timer.resume()
    _ = format
    return true
  }

  func stop() {
    timer?.cancel()
    timer = nil
    running = false
    if let procID {
      AudioDeviceStop(device, procID)
      AudioDeviceDestroyIOProcID(device, procID)
      self.procID = nil
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
    guard frames > 0, frames <= 4096 else { return }
    slotLock.lock()
    defer { slotLock.unlock() }
    guard let index = slots.firstIndex(where: { !$0.full }) else { return }
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
    slotLock.unlock()
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
}
