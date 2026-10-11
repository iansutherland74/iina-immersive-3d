//
//  LiveCaptionEngine.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Live auto subtitles. libmpv does not export decoded PCM. A local file is
//  decoded with the FFmpeg already linked into IINA. A network or live stream
//  is taken from mpv's demuxer cache, so the provider is not opened again.
//  whisper.cpp runs in-process. Each line is stamped with the audio PTS, not
//  the time the text arrived. A file or movie is read ahead of the playhead
//  and playback is not held back. A live channel cannot be read from the
//  future, so the demuxer cache holds the picture and the sound. Turning
//  captions off seeks a held channel back to the live edge. Depth is estimated
//  from the frame mpv has already drawn, so it stays on that same delayed
//  picture. Only caption text leaves the Mac, and only when a translation API
//  key is set.

import Cocoa
import Darwin
import os

#if canImport(Translation)
import Translation
#endif

extension Notification.Name {
  static let liveCaptionStatusChanged = Notification.Name("IINALiveCaptionStatusChanged")
}

/// Unified-log line for the caption engine. IINA's file logger drops every
/// message when logging is off, which is the default, so this does not use it.
private let liveCaptionLog = os.Logger(subsystem: "com.colliderli.iina", category: "LiveCaptions")

private func liveCaptionInfo(_ message: String) {
  liveCaptionLog.info("\(message, privacy: .public)")
}

private func liveCaptionError(_ message: String) {
  liveCaptionLog.error("\(message, privacy: .public)")
}

enum LiveCaptionLanguage {
  static let speech: [(String, String)] = [
    ("auto", "Auto-detect"),
    ("en", "English"),
    ("es", "Spanish"),
    ("fr", "French"),
    ("de", "German"),
    ("it", "Italian"),
    ("pt", "Portuguese"),
    ("nl", "Dutch"),
    ("pl", "Polish"),
    ("ru", "Russian"),
    ("uk", "Ukrainian"),
    ("tr", "Turkish"),
    ("ar", "Arabic"),
    ("hi", "Hindi"),
    ("zh", "Chinese"),
    ("ja", "Japanese"),
    ("ko", "Korean"),
    ("sv", "Swedish"),
    ("da", "Danish"),
    ("fi", "Finnish"),
    ("no", "Norwegian"),
    ("cs", "Czech"),
    ("el", "Greek"),
    ("he", "Hebrew"),
    ("id", "Indonesian"),
    ("vi", "Vietnamese"),
    ("th", "Thai"),
    ("ro", "Romanian")
  ]

  static var targets: [(String, String)] {
    [("original", "Same as speech")] + speech.filter { $0.0 != "auto" }
  }
}

enum LiveCaptionStore {
  static var directory: URL {
    let url = Utility.appSupportDirUrl.appendingPathComponent("Models/whisper", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func file(for model: Preference.LiveCaptionModel) -> URL {
    let name = model == .small ? "ggml-small.bin" : "ggml-base.bin"
    return directory.appendingPathComponent(name)
  }

  static func remoteURL(for model: Preference.LiveCaptionModel) -> URL {
    let name = model == .small ? "ggml-small.bin" : "ggml-base.bin"
    return URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(name)")!
  }

  static func isInstalled(_ model: Preference.LiveCaptionModel) -> Bool {
    let url = file(for: model)
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
    return size > 1_000_000
  }
}

struct CaptionCue {
  var start: Double
  var end: Double
  var text: String
}

struct CaptionChunk {
  var samples: [Float]
  var start: Double
}

struct CaptionPace {
  var window: Double
  var hop: Double
  var beam: Int
  var threads: Int

  static func current() -> CaptionPace {
    let choice: Preference.LiveCaptionLatency = Preference.enum(for: .liveCaptionLatency)
    switch choice {
    case .low:
      return CaptionPace(window: 3, hop: 1.5, beam: 1, threads: 4)
    case .balanced:
      return CaptionPace(window: 5, hop: 2.5, beam: 3, threads: 4)
    case .accuracy:
      return CaptionPace(window: 8, hop: 4, beam: 5, threads: 6)
    }
  }
}

final class LiveCaptionController {
  static let shared = LiveCaptionController()

  private let queue = DispatchQueue(label: "com.colliderli.iina.live-caption", qos: .userInitiated)
  private let preferences = Preference.Observer()
  private let overlay = LiveCaptionOverlay()
  private let source = CaptionSource()
  private let whisper = WhisperBridge()
  private var generation = 0
  private var running = false
  private weak var core: PlayerCore?
  private var activeURL: URL?
  private var displayTimer: Timer?
  private var lastText = ""
  private var lastSBS = false
  private var lastChrome = false
  private var mpvTrackID: Int?
  private var previousSID: Int?
  private var usingOSD = false
  private var savedSubVisibility: Bool?
  private var lastRaw = ""
  private var lastTranslated = ""
  private var observing = false
  private var cues: [CaptionCue] = []
  private var assSignature = ""
  private var shownCueSignature = ""
  private var measuredWork = 5.0
  private var measuredInference = 1.5
  private var timingSamples = 0
  private var appliedLiveDelay = 5.0
  private var reportedLookahead = 0.0
  private var savedCache: SavedCache?
  private var holdingPlayback = false
  private var holdStarted = Date.distantPast
  private var gaveUpHold = false
  private var delayApplyScheduled = false
  private var savedCaptionSubVisibility: Bool?
  private var triedFlatTrack = false
  private var lastOSD = ""
  private var audioMisses = 0
  private var loggedQuiet = false
  private var loggedEmpty = false
  private var loggedTime = false
  private let subtitleURL = FileManager.default.temporaryDirectory.appendingPathComponent("iina-live-caption.ass")

  private(set) var statusText = "Live captions are off."
  private(set) var syncText = "Files and movies are read ahead. A live channel is held back unless that delay is turned off."
  private var lastBanner: String?

  private struct SavedCache {
    var cache: String?
    var cacheSecs: Double?
    var readahead: Double?
    var cachePause: Bool?
    var cachePauseInitial: Bool?
    var cachePauseWait: Double?
    var wePaused: Bool
  }

  private init() {}

  func startObserving() {
    guard !observing else { return }
    observing = true
    preferences.add(.liveCaptionEnabled) { [weak self] _ in
      DispatchQueue.main.async {
        self?.applyEnabled()
      }
    }
    let refresh = { [weak self] in
      DispatchQueue.main.async {
        self?.maintainLiveDelay()
        self?.refreshSyncText()
      }
    }
    preferences.add(.liveCaptionSync) { _ in refresh() }
    preferences.add(.liveCaptionLiveDelayAuto) { _ in refresh() }
    // Dragging the slider writes the default on every tick. Applying that to
    // mpv on the same turn freezes the knob, so the apply waits until the
    // current mouse event has drawn.
    preferences.add(.liveCaptionLiveDelay) { [weak self] _ in
      self?.scheduleDelayApply()
    }
  }

  func noteFileStarted(core: PlayerCore) {
    startObserving()
    self.core = core
    guard Preference.bool(for: .liveCaptionEnabled) else {
      stop(jumpToLive: false)
      return
    }
    start()
  }

  func noteFileEnded() {
    stop(jumpToLive: false)
  }

  /// Shown on the live banner while a live channel is being held back. Nil for a file, a movie, or catch-up.
  var bannerText: String? {
    guard Preference.bool(for: .liveCaptionEnabled), running, playbackShouldWait() else { return nil }
    let seconds = max(1, Int(appliedLiveDelay.rounded()))
    return "Subtitles synced, live +\(seconds)s"
  }

  func attachIfNeeded() {
    guard running else { return }
    overlay.attachIfNeeded()
  }

  func setStatus(_ text: String, osd: String? = nil) {
    let apply = {
      if self.statusText != text {
        self.statusText = text
        liveCaptionInfo(text)
        NotificationCenter.default.post(name: .liveCaptionStatusChanged, object: nil)
      }
      if let osd {
        self.presentStatusOSD(osd)
      }
    }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async(execute: apply)
    }
  }

  private func noteMissingAudio() {
    audioMisses += 1
    let state = source.diagnostic()
    if audioMisses == 1 || audioMisses == 4 {
      liveCaptionInfo("waiting for audio (\(state))")
    }
    if let failure = source.failure() {
      setStatus(failure.message, osd: "Live captions: error: \(failure.osd)")
      return
    }
    if audioMisses >= 4 {
      if source.bufferedSeconds() >= 0.5 {
        setStatus("Audio is buffered, but the playhead is outside that range. \(state)", osd: "Live captions: error: playhead outside audio")
      } else if source.isCacheThin() {
        setStatus("No audio has arrived from the player. \(state)", osd: "Live captions: error: no audio from the player")
      } else {
        setStatus("No audio has arrived for captions. \(state)", osd: "Live captions: error: no audio captured")
      }
    } else {
      presentStatusOSD("Live captions: listening")
    }
  }

  /// Small top-of-picture line. Real captions use the subtitle track or overlay 7.
  private func presentStatusOSD(_ line: String) {
    let draw = {
      let captionVisible = !self.displayedText.isEmpty
      let keep = line.contains("error:") || line.contains("loading")
      if captionVisible && !keep {
        if !self.lastOSD.isEmpty {
          self.clearStatusOSD()
        }
        return
      }
      if line == self.lastOSD { return }
      self.lastOSD = line
      liveCaptionInfo(line)
      let body = "{\\an8\\fs28\\bord2}" + self.escapeASS(line)
      let code = self.overlayCommand(id: 8, format: "ass-events", data: self.assEvent(body))
      if code < 0 {
        liveCaptionError("status osd-overlay failed \(code)")
      }
    }
    if Thread.isMainThread {
      draw()
    } else {
      DispatchQueue.main.async(execute: draw)
    }
  }

  private func clearStatusOSD() {
    lastOSD = ""
    _ = overlayCommand(id: 8, format: "none", data: "")
  }

  /// osd-overlay is a named command. The string form returns -4 because id,
  /// res_x, and res_y are int64, and the only text format is ass-events.
  private func overlayCommand(id: Int, format: String, data: String) -> Int32 {
    if !Thread.isMainThread {
      var code = MPV_ERROR_UNINITIALIZED.rawValue
      DispatchQueue.main.sync {
        code = self.overlayCommand(id: id, format: format, data: data)
      }
      return code
    }
    guard mpvIsUsable(), let core else { return MPV_ERROR_UNINITIALIZED.rawValue }
    let payload: [String: Any?] = [
      "name": "osd-overlay",
      "id": id,
      "format": format,
      "data": data,
      "res_x": 1920,
      "res_y": 1080,
      "z": 0
    ]
    return core.mpv.commandNode(payload)
  }

  private func assEvent(_ body: String) -> String {
    "Dialogue: 0,0:00:00.00,9:59:59.99,Default,,0,0,0,," + body
  }

  /// Coalesce live-delay edits so a drag updates the label immediately and
  /// mpv receives one cache change for the value the knob stopped on.
  private func scheduleDelayApply() {
    let enqueue = {
      guard !self.delayApplyScheduled else { return }
      self.delayApplyScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.delayApplyScheduled = false
        self.maintainLiveDelay()
        self.refreshSyncText()
      }
    }
    if Thread.isMainThread {
      enqueue()
    } else {
      DispatchQueue.main.async(execute: enqueue)
    }
  }

  private func applyEnabled() {
    guard Preference.bool(for: .liveCaptionEnabled) else {
      stop(jumpToLive: true)
      return
    }
    guard !PlayerCore.playerCores.isEmpty else { return }
    let active = PlayerCore.active
    guard active.info.state.active, active.info.currentURL != nil else { return }
    core = active
    start()
  }

  private func start() {
    guard let core, core.mpv != nil, let url = core.info.currentURL else {
      liveCaptionError("engine did not start: player or URL is missing")
      setStatus("Live captions could not start because playback is not ready.", osd: "Live captions: error: playback is not ready")
      return
    }
    if running, activeURL == url { return }
    let replacing = running
    stop(jumpToLive: false, reason: replacing ? "new file" : "playback stopped")
    generation += 1
    let token = generation
    running = true
    activeURL = url
    lastRaw = ""
    lastTranslated = ""
    lastText = ""
    cues.removeAll()
    assSignature = ""
    shownCueSignature = ""
    gaveUpHold = false
    audioMisses = 0
    loggedQuiet = false
    loggedEmpty = false
    loggedTime = false
    triedFlatTrack = false
    let agent = core.mpv.getString("user-agent")
    let time = core.mpv.getDouble(MPVProperty.timePos)
    let kind = url.isFileURL ? "file" : "network"
    liveCaptionInfo("engine start \(kind)")
    source.open(url: url, userAgent: agent, at: time.isFinite ? time : 0)
    installTimer()
    overlay.attachIfNeeded()
    let pace = CaptionPace.current()
    setStatus("Listening. Captions lag the picture by about \(Int(pace.window)) seconds, plus model time.", osd: "Live captions: listening")
    schedule(generation: token, delay: 0.4)
  }

  private func stop(jumpToLive: Bool, reason: String = "playback stopped") {
    let wasRunning = running
    generation += 1
    running = false
    activeURL = nil
    restorePlaybackDelay(jumpToLive: jumpToLive)
    if wasRunning {
      whisper.requestAbort(reason)
    }
    source.close()
    cues.removeAll()
    assSignature = ""
    shownCueSignature = ""
    displayTimer?.invalidate()
    displayTimer = nil
    lastText = ""
    lastSBS = false
    clearDisplayedCaption()
    overlay.remove()
    if Preference.bool(for: .liveCaptionEnabled) {
      setStatus("Live captions are on. They start when a file, channel, or movie is playing.")
    } else {
      setStatus("Live captions are off.")
    }
    refreshSyncText()
  }

  private func installTimer() {
    displayTimer?.invalidate()
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.tick()
    }
    displayTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func schedule(generation token: Int, delay: Double) {
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, self.generation == token else { return }
      self.step(generation: token)
      guard self.generation == token else { return }
      self.schedule(generation: token, delay: CaptionPace.current().hop)
    }
  }

  private func tick() {
    guard running else { return }
    maintainLiveDelay()
    refreshSyncText()
    redisplay()
  }

  private func step(generation token: Int) {
    guard token == generation else { return }
    let pace = CaptionPace.current()
    let model: Preference.LiveCaptionModel = Preference.enum(for: .liveCaptionModel)
    guard LiveCaptionStore.isInstalled(model) else {
      let name = model == .small ? "Small" : "Base"
      publish(notice: "Live captions: download the \(name) model in Settings → Subtitles.", token: token)
      setStatus("\(name) model is not downloaded. It stays on this Mac, under Application Support.", osd: "Live captions: error: \(name) model is not downloaded")
      return
    }
    guard whisper.ensureLoaded(model: model) else {
      publish(notice: "Live captions could not load whisper.cpp.", token: token)
      return
    }
    guard let time = mediaTime(), time.isFinite else {
      if !loggedTime {
        loggedTime = true
        liveCaptionError("playhead time is not ready")
      }
      return
    }
    loggedTime = false
    let waiting = playbackShouldWait()
    let ahead = (!waiting && !source.isLiveEdge) ? lookaheadLead() : 0
    reportedLookahead = ahead
    source.follow(playhead: time, window: pace.window, ahead: ahead)
    guard let audio = source.samples(playhead: time, window: pace.window) else {
      noteMissingAudio()
      return
    }
    let missed = audioMisses
    audioMisses = 0
    if missed >= 4 {
      presentStatusOSD("Live captions: listening")
    }
    let level = rms(audio.samples)
    let chunkSeconds = Double(audio.samples.count) / 16000
    liveCaptionInfo(String(format: "chunk rms %.4f samples %d start %.2f dur %.2f", level, audio.samples.count, audio.start, chunkSeconds))
    if level < 0.008 {
      if !loggedQuiet {
        loggedQuiet = true
        liveCaptionInfo("audio is below the speech threshold")
      }
      presentStatusOSD("Live captions: listening")
      return
    }
    loggedQuiet = false
    whisper.clearAbort()
    let sourceLanguage = Preference.string(for: .liveCaptionSourceLanguage) ?? "auto"
    let target = Preference.string(for: .liveCaptionTargetLanguage) ?? "original"
    let translateToEnglish = target == "en" && sourceLanguage != "en"
    let started = Date()
    guard let raw = whisper.transcribe(
      audio.samples,
      language: sourceLanguage,
      translate: translateToEnglish,
      beam: pace.beam,
      threads: pace.threads
    ) else {
      return
    }
    let inference = Date().timeIntervalSince(started)
    guard token == generation else { return }
    let duration = Double(audio.samples.count) / 16000
    var parsed = cues(from: raw, audioStart: audio.start, audioDuration: duration)
    guard !parsed.isEmpty else {
      if !loggedEmpty {
        loggedEmpty = true
        liveCaptionInfo("whisper returned no words segments \(whisper.lastSegments())")
      }
      presentStatusOSD("Live captions: listening")
      return
    }
    loggedEmpty = false
    parsed = parsed.map { cue in
      var next = cue
      let translated = translate(cue.text, sourceLanguage: sourceLanguage, target: target, alreadyEnglish: translateToEnglish)
      next.text = translated
      return next
    }
    let earliest = parsed.map(\.start).min() ?? audio.start
    noteTiming(inference: inference, span: max(0, audio.start + duration - earliest))
    let signature = parsed.map(\.text).joined(separator: "\n")
    if signature == lastRaw && !usesTimedCues() {
      return
    }
    lastRaw = signature
    lastTranslated = parsed.last?.text ?? ""
    publish(cues: parsed, token: token)
  }

  private func publish(cues incoming: [CaptionCue], token: Int) {
    guard token == generation else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.generation == token else { return }
      self.ingest(incoming)
      self.redisplay()
    }
  }

  private func publish(notice: String, token: Int) {
    guard token == generation else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.generation == token else { return }
      self.lastText = notice
      self.cues = [CaptionCue(start: 0, end: 36000, text: notice)]
      self.redisplay()
    }
  }

  private func ingest(_ incoming: [CaptionCue]) {
    for cue in incoming where !cue.text.isEmpty {
      let duplicate = cues.contains { existing in
        existing.text == cue.text && abs(existing.start - cue.start) < 1.2
      }
      if !duplicate {
        cues.append(cue)
      }
    }
    cues.sort { $0.start < $1.start }
    if cues.count > 24 {
      cues.removeFirst(cues.count - 24)
    }
  }

  private func redisplay() {
    guard running else { return }
    let timed = usesTimedCues()
    if let now = mediaTime() {
      cues.removeAll { $0.end < now - 6 && $0.end < 30000 }
    }
    let now = mediaTime() ?? 0
    let text = visibleText(at: now, timed: timed)
    let signature = cues.map { "\(Int($0.start * 100))-\(Int($0.end * 100))-\($0.text)" }.joined(separator: "|")
    let sbs = IPTVLiveOverlayController.duplicatesEyes
    let chrome = GlassesEyeControls.shared.shown
    let textChanged = text != displayedText
    let modeChanged = sbs != lastSBS
    let chromeChanged = chrome != lastChrome
    let cuesChanged = signature != shownCueSignature
    if !textChanged && !modeChanged && !chromeChanged && !cuesChanged { return }
    let wasSBS = lastSBS
    lastSBS = sbs
    lastChrome = chrome
    lastText = text
    displayedText = text
    shownCueSignature = signature
    if sbs {
      if !wasSBS {
        suppressMPVCaption()
        hideShiftedSubtitles()
      }
      overlay.setText(text)
      overlay.attachIfNeeded()
    } else {
      if wasSBS {
        restoreShiftedSubtitles()
      }
      overlay.setText("")
      if textChanged || modeChanged || cuesChanged {
        showFlatCaption(syncing: timed)
      }
    }
    if !lastOSD.isEmpty {
      presentStatusOSD(lastOSD)
    }
  }

  /// A file, movie, or catch-up is timed to the audio. A live channel is too, once the
  /// picture is held back. With that delay turned off, the latest line shows when it is ready.
  private func usesTimedCues() -> Bool {
    if source.isLiveEdge && !playbackShouldWait() { return false }
    return true
  }

  private func visibleText(at time: Double, timed: Bool) -> String {
    guard timed else { return cues.last?.text ?? "" }
    return cues.last { $0.start - 0.12 <= time && time < $0.end + 0.2 }?.text ?? ""
  }

  private var displayedText = ""

  private func mediaTime() -> Double? {
    guard let core, core.mpv != nil else { return nil }
    var value = Double.nan
    let read = {
      guard core.info.state.active else { return }
      value = core.mpv.getDouble(MPVProperty.timePos)
    }
    if Thread.isMainThread {
      read()
    } else {
      DispatchQueue.main.sync(execute: read)
    }
    return value.isFinite ? value : nil
  }

  private func mpvIsUsable() -> Bool {
    guard !Immersive3DController.shared.isShuttingDown else { return false }
    guard let core, core.mpv != nil, core.info.state.active else { return false }
    return true
  }

  private func showFlatCaption(syncing: Bool) {
    guard mpvIsUsable(), let core else { return }
    let signature = cues.map { "\(Int($0.start * 100))-\(Int($0.end * 100))-\($0.text)" }.joined(separator: "|")
    let changed = signature != assSignature
    if changed {
      if syncing {
        writeASS(cues)
      } else if let text = cues.last?.text, !text.isEmpty {
        writeASS([CaptionCue(start: 0, end: 36000, text: text)])
      } else {
        writeASS([])
      }
      assSignature = signature
    }
    let hadTrack = mpvTrackID != nil && !usingOSD
    if mpvTrackID == nil || usingOSD {
      attachFlatTrack(core)
    }
    if changed, !usingOSD, let track = mpvTrackID {
      var code: Int32 = 0
      core.mpv.command(.subReload, args: [String(track)], checkError: false) { code = $0 }
      if code < 0 {
        liveCaptionError("sub-reload \(code) for track \(track)")
        usingOSD = true
      } else if !hadTrack {
        liveCaptionInfo("live caption track \(track) loaded")
      }
    }
    if usingOSD || mpvTrackID == nil {
      let text = displayedText
      if text.isEmpty {
        let code = overlayCommand(id: 7, format: "none", data: "")
        if code < 0 {
          liveCaptionError("caption osd-overlay failed \(code)")
        }
      } else {
        let line = "{\\an2\\fs48\\bord3}" + escapeASS(text)
        let code = overlayCommand(id: 7, format: "ass-events", data: assEvent(line))
        if code < 0 {
          liveCaptionError("caption osd-overlay failed \(code)")
        }
      }
    }
  }

  /// sub-add's select flag can leave the previous sid in place. Only a track
  /// titled "Live captions" counts. Otherwise the words are drawn with osd-overlay.
  private func attachFlatTrack(_ core: PlayerCore) {
    if previousSID == nil {
      previousSID = core.mpv.getInt("sid")
    }
    var added = findLiveCaptionSID(core)
    if added == nil && !triedFlatTrack {
      triedFlatTrack = true
      var code: Int32 = -1
      core.mpv.command(.subAdd, args: [subtitleURL.mpvStr, "select", "Live captions", "und"], checkError: false) { code = $0 }
      added = findLiveCaptionSID(core)
      if code < 0 {
        liveCaptionError("sub-add failed \(code)")
      }
    }
    guard let added, added > 0 else {
      usingOSD = true
      mpvTrackID = nil
      liveCaptionError("no Live captions subtitle track; drawing with osd-overlay")
      return
    }
    let selected = core.mpv.getInt("sid")
    if selected != added {
      core.mpv.setInt("sid", added)
    }
    if savedCaptionSubVisibility == nil {
      savedCaptionSubVisibility = core.mpv.getFlag(MPVOption.Subtitles.subVisibility)
    }
    core.mpv.setFlag(MPVOption.Subtitles.subVisibility, true)
    mpvTrackID = added
    usingOSD = false
    liveCaptionInfo("selected live caption track \(added) (previous sid \(previousSID ?? 0), visibility on)")
  }

  private func findLiveCaptionSID(_ core: PlayerCore) -> Int? {
    let count = core.mpv.getInt(MPVProperty.trackListCount)
    guard count > 0 else { return nil }
    var found: Int?
    for index in 0..<count {
      guard core.mpv.getString(MPVProperty.trackListNType(index)) == "sub" else { continue }
      guard core.mpv.getString(MPVProperty.trackListNTitle(index)) == "Live captions" else { continue }
      let id = core.mpv.getInt(MPVProperty.trackListNId(index))
      if id > 0 { found = id }
    }
    return found
  }

  private func suppressMPVCaption() {
    guard mpvIsUsable(), let core else { return }
    if let track = mpvTrackID {
      core.mpv.command(.subRemove, args: [String(track)], checkError: false)
      mpvTrackID = nil
    }
    let code = overlayCommand(id: 7, format: "none", data: "")
    if code < 0 {
      liveCaptionError("caption osd-overlay failed \(code)")
    }
    usingOSD = false
  }

  /// mpv subtitles are inside the picture the stereo shader shifts. Hide that
  /// track while the per-eye line is on screen, then put the previous visibility back.
  private func hideShiftedSubtitles() {
    guard mpvIsUsable(), let core, savedSubVisibility == nil else { return }
    savedSubVisibility = core.mpv.getFlag(MPVOption.Subtitles.subVisibility)
    core.mpv.setFlag(MPVOption.Subtitles.subVisibility, false)
  }

  private func restoreShiftedSubtitles() {
    guard mpvIsUsable(), let core, let saved = savedSubVisibility else { return }
    core.mpv.setFlag(MPVOption.Subtitles.subVisibility, saved)
    savedSubVisibility = nil
  }

  private func clearDisplayedCaption() {
    displayedText = ""
    guard mpvIsUsable() else {
      mpvTrackID = nil
      previousSID = nil
      savedSubVisibility = nil
      savedCaptionSubVisibility = nil
      triedFlatTrack = false
      usingOSD = false
      lastOSD = ""
      try? FileManager.default.removeItem(at: subtitleURL)
      return
    }
    suppressMPVCaption()
    clearStatusOSD()
    guard let core else {
      previousSID = nil
      savedCaptionSubVisibility = nil
      return
    }
    if let previous = previousSID, previous > 0 {
      core.mpv.setInt("sid", previous)
    }
    previousSID = nil
    restoreShiftedSubtitles()
    if let saved = savedCaptionSubVisibility {
      core.mpv.setFlag(MPVOption.Subtitles.subVisibility, saved)
      savedCaptionSubVisibility = nil
    }
    try? FileManager.default.removeItem(at: subtitleURL)
  }

  private func writeASS(_ lines: [CaptionCue]) {
    let events = lines.map { cue in
      "Dialogue: 0,\(assTime(cue.start)),\(assTime(cue.end)),Default,,0,0,0,,\(escapeASS(cue.text))"
    }.joined(separator: "\n")
    let body = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080
    WrapStyle: 0
    ScaledBorderAndShadow: yes

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica,52,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,-1,0,0,0,100,100,0,0,1,3,0,2,48,48,56,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    \(events)
    """
    do {
      try body.data(using: .utf8)?.write(to: subtitleURL, options: .atomic)
    } catch {
      liveCaptionError("could not write caption file: \(error.localizedDescription)")
    }
  }

  private func assTime(_ seconds: Double) -> String {
    let clamped = max(0, seconds)
    let totalCs = Int((clamped * 100).rounded())
    let cs = totalCs % 100
    let total = totalCs / 100
    let s = total % 60
    let m = (total / 60) % 60
    let h = total / 3600
    return String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
  }

  private func escapeASS(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "{", with: "\\{")
      .replacingOccurrences(of: "}", with: "\\}")
      .replacingOccurrences(of: "\n", with: "\\N")
  }

  private func clean(_ raw: String) -> String {
    var text = raw.replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
    while let start = text.range(of: "<|"), let end = text.range(of: "|>", range: start.upperBound..<text.endIndex) {
      text.removeSubrange(start.lowerBound..<end.upperBound)
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let folded = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;:"))
    let junk: Set<String> = [
      "", "you", "thank you", "thanks for watching", "thank you for watching",
      "subtitles by the amara.org community", "www.youtube.com"
    ]
    if junk.contains(folded) { return "" }
    if text.count > 400 {
      text = String(text.prefix(400))
    }
    return text
  }

  private func cues(from raw: String, audioStart: Double, audioDuration: Double) -> [CaptionCue] {
    var parsed: [CaptionCue] = []
    for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
      let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3, let t0 = Double(parts[0]), let t1 = Double(parts[1]) else { continue }
      let text = clean(String(parts[2]))
      guard !text.isEmpty else { continue }
      let start = audioStart + t0 / 100
      var end = audioStart + max(t0, t1) / 100
      if end < start + 0.8 { end = start + 1.6 }
      parsed.append(CaptionCue(start: start, end: end, text: text))
    }
    if parsed.isEmpty {
      let text = clean(raw.replacingOccurrences(of: "\t", with: " "))
      if !text.isEmpty {
        parsed.append(CaptionCue(start: audioStart, end: audioStart + max(1.6, audioDuration), text: text))
      }
    }
    return parsed
  }

  private func lookaheadLead() -> Double {
    min(8, max(0.8, measuredInference + 0.35))
  }

  private func noteTiming(inference: Double, span: Double) {
    let sample = max(0.2, inference + span)
    if timingSamples == 0 {
      measuredWork = sample
      measuredInference = inference
    } else {
      measuredWork = measuredWork * 0.7 + sample * 0.3
      measuredInference = measuredInference * 0.7 + inference * 0.3
    }
    timingSamples += 1
  }

  /// An IPTV live channel, and any other unseekable stream, cannot be decoded
  /// from the future, so the picture waits. A file or a movie is read ahead
  /// instead and is never held back, even if a live-channel session is still
  /// set. The delay setting only turns this hold off.
  private func playbackShouldWait() -> Bool {
    guard Preference.bool(for: .liveCaptionEnabled), Preference.bool(for: .liveCaptionSync) else { return false }
    if activeURL?.isFileURL == true || source.isLocalFile { return false }
    let decision = { () -> Bool? in
      guard let session = IPTVLiveOverlayController.shared.session else { return nil }
      if session.catchup != nil { return false }
      if session.item.kind == .live { return true }
      return false
    }
    let known: Bool?
    if Thread.isMainThread {
      known = decision()
    } else {
      var value: Bool?
      DispatchQueue.main.sync { value = decision() }
      known = value
    }
    if let known { return known }
    return source.isLiveEdge && source.isOpenEnded
  }

  private func desiredLiveDelay() -> Double {
    let configured = min(12, max(2, Preference.double(for: .liveCaptionLiveDelay)))
    guard Preference.bool(for: .liveCaptionLiveDelayAuto), timingSamples > 0 else { return configured }
    return min(12, max(configured, measuredWork + 0.35))
  }

  private func maintainLiveDelay() {
    guard running, mpvIsUsable(), let core else { return }
    guard playbackShouldWait() else {
      if savedCache != nil || holdingPlayback {
        let jump = source.isLiveEdge && activeURL?.isFileURL != true
        restorePlaybackDelay(jumpToLive: jump)
      }
      return
    }
    let delay = desiredLiveDelay()
    if savedCache == nil || abs(delay - appliedLiveDelay) > 0.05 {
      let configured = min(12, max(2, Preference.double(for: .liveCaptionLiveDelay)))
      liveCaptionInfo(String(format: "applying live delay %.1f s (slider %.1f s)", delay, configured))
    }
    appliedLiveDelay = delay
    let hold = delay + 1.5
    if savedCache == nil {
      savedCache = SavedCache(
        cache: core.mpv.getString(MPVOption.Cache.cache),
        cacheSecs: mpvDouble(MPVOption.Cache.cacheSecs, core),
        readahead: mpvDouble(MPVOption.Demuxer.demuxerReadaheadSecs, core),
        cachePause: mpvFlag(MPVOption.Cache.cachePause, core),
        cachePauseInitial: mpvFlag(MPVOption.Cache.cachePauseInitial, core),
        cachePauseWait: mpvDouble(MPVOption.Cache.cachePauseWait, core),
        wePaused: false
      )
    }
    core.mpv.setString(MPVOption.Cache.cache, "yes")
    core.mpv.setDouble(MPVOption.Cache.cacheSecs, hold)
    core.mpv.setDouble(MPVOption.Demuxer.demuxerReadaheadSecs, hold)
    core.mpv.setFlag(MPVOption.Cache.cachePause, true)
    core.mpv.setDouble(MPVOption.Cache.cachePauseWait, min(delay, 8))
    let cached = core.mpv.getDouble(MPVProperty.demuxerCacheDuration)
    let filled = cached.isFinite && cached >= delay * 0.85
    if !filled && !gaveUpHold {
      if !holdingPlayback {
        let alreadyPaused = core.mpv.getFlag(MPVOption.PlaybackControl.pause)
        if !alreadyPaused {
          core.mpv.setFlag(MPVOption.PlaybackControl.pause, true)
          if var saved = savedCache {
            saved.wePaused = true
            savedCache = saved
          }
          holdingPlayback = true
          holdStarted = Date()
        } else {
          gaveUpHold = true
        }
      } else if Date().timeIntervalSince(holdStarted) >= delay + 2 {
        releaseHold(core)
        gaveUpHold = true
      }
    } else if holdingPlayback {
      releaseHold(core)
    }
  }

  private func releaseHold(_ core: PlayerCore) {
    guard holdingPlayback else { return }
    holdingPlayback = false
    if var saved = savedCache, saved.wePaused {
      core.mpv.setFlag(MPVOption.PlaybackControl.pause, false)
      saved.wePaused = false
      savedCache = saved
    }
  }

  private func restorePlaybackDelay(jumpToLive: Bool) {
    holdingPlayback = false
    gaveUpHold = false
    guard !Immersive3DController.shared.isShuttingDown, let saved = savedCache, let core, core.mpv != nil else {
      savedCache = nil
      return
    }
    if saved.wePaused, core.info.state.active {
      core.mpv.setFlag(MPVOption.PlaybackControl.pause, false)
    }
    if jumpToLive, core.info.state.active {
      seekToLiveEdge(core)
    }
    if let cache = saved.cache {
      core.mpv.setString(MPVOption.Cache.cache, cache)
    }
    if let cacheSecs = saved.cacheSecs {
      core.mpv.setDouble(MPVOption.Cache.cacheSecs, cacheSecs)
    }
    if let readahead = saved.readahead {
      core.mpv.setDouble(MPVOption.Demuxer.demuxerReadaheadSecs, readahead)
    }
    if let cachePause = saved.cachePause {
      core.mpv.setFlag(MPVOption.Cache.cachePause, cachePause)
    }
    if let cachePauseInitial = saved.cachePauseInitial {
      core.mpv.setFlag(MPVOption.Cache.cachePauseInitial, cachePauseInitial)
    }
    if let cachePauseWait = saved.cachePauseWait {
      core.mpv.setDouble(MPVOption.Cache.cachePauseWait, cachePauseWait)
    }
    savedCache = nil
  }

  /// The demuxer head is the newest packet. Seeking there drops the hold and returns to the live edge.
  private func seekToLiveEdge(_ core: PlayerCore) {
    let pos = core.mpv.getDouble(MPVProperty.timePos)
    if let edge = mpvDouble(MPVProperty.demuxerCacheTime, core), edge.isFinite, pos.isFinite, edge > pos + 0.25 {
      core.mpv.command(.seek, args: [String(edge), "absolute"], checkError: false)
      return
    }
    let cached = core.mpv.getDouble(MPVProperty.demuxerCacheDuration)
    if cached.isFinite, cached > 0.25 {
      core.mpv.command(.seek, args: [String(cached), "relative"], checkError: false)
    }
  }

  private func mpvDouble(_ name: String, _ core: PlayerCore) -> Double? {
    guard let text = core.mpv.getString(name) else { return nil }
    return Double(text)
  }

  private func mpvFlag(_ name: String, _ core: PlayerCore) -> Bool? {
    switch core.mpv.getString(name) {
    case "yes": return true
    case "no": return false
    default: return nil
    }
  }

  private func refreshSyncText() {
    let text = describeSync()
    let banner = bannerText
    guard text != syncText || banner != lastBanner else { return }
    syncText = text
    lastBanner = banner
    NotificationCenter.default.post(name: .liveCaptionStatusChanged, object: nil)
    IPTVLiveOverlayController.shared.redraw()
  }

  private func describeSync() -> String {
    if playbackShouldWait() {
      let seconds = max(1, Int(appliedLiveDelay.rounded()))
      if holdingPlayback {
        return "Subtitles synced, live +\(seconds)s. Playback is moving back from the live edge. Depth stays on this frame."
      }
      return "Subtitles synced, live +\(seconds)s. Picture, sound, and depth are this far behind the broadcast."
    }
    if !Preference.bool(for: .liveCaptionSync) && source.isLiveEdge {
      return "Live delay is off, so this channel stays at the live edge. The line can arrive after the words."
    }
    if source.isLiveEdge {
      return "This item is not a live channel and could not be read ahead, so the line can arrive after the words."
    }
    return String(format: "Reading %.1f s ahead. Playback is not delayed. Whisper is taking about %.1f s.", reportedLookahead, measuredInference)
  }

  private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var acc: Float = 0
    for value in samples {
      acc += value * value
    }
    return sqrt(acc / Float(samples.count))
  }

  private func translate(_ text: String, sourceLanguage: String, target: String, alreadyEnglish: Bool) -> String {
    guard !text.isEmpty else { return "" }
    if target == "original" || target == sourceLanguage { return text }
    if alreadyEnglish || (target == "en" && sourceLanguage == "en") { return text }
    if let system = systemTranslate(text, source: sourceLanguage, target: target), !system.isEmpty {
      setStatus("Translated on this Mac with the system translator.")
      return system
    }
    if let remote = apiTranslate(text, source: sourceLanguage, target: target), !remote.isEmpty {
      return remote
    }
    if target != "en" {
      setStatus("Showing the recognized language. This macOS version has no system translator for this pair, and no translation API key is saved. Whisper itself only translates into English.")
    }
    return text
  }

  private func systemTranslate(_ text: String, source: String, target: String) -> String? {
    #if canImport(Translation)
    guard #available(macOS 26.0, *) else { return nil }
    let semaphore = DispatchSemaphore(value: 0)
    var output: String?
    DispatchQueue.main.async {
      Task {
        guard #available(macOS 26.0, *) else {
          semaphore.signal()
          return
        }
        output = await LiveCaptionTranslator.system(text, source: source, target: target)
        semaphore.signal()
      }
    }
    if semaphore.wait(timeout: .now() + 6) == .timedOut {
      return nil
    }
    return output
    #else
    return nil
    #endif
  }

  private func apiTranslate(_ text: String, source: String, target: String) -> String? {
    guard let key = try? KeychainAccess.read(username: "api-key", forService: .liveCaptionTranslate).password,
          !key.isEmpty else {
      return nil
    }
    let endpoint = Preference.string(for: .liveCaptionTranslateEndpoint) ?? "https://api-free.deepl.com/v2/translate"
    guard let url = URL(string: endpoint), let host = url.host, url.scheme == "https" else {
      setStatus("Translation URL must be https.")
      return nil
    }
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.httpMethod = "POST"
    if host.contains("deepl.com") {
      request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      let body = "text=\(formEncode(text))&target_lang=\(formEncode(deeplCode(target)))"
      request.httpBody = body.data(using: .utf8)
    } else {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      let payload: [String: String] = ["text": text, "source": source, "target": target]
      request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
    }
    let semaphore = DispatchSemaphore(value: 0)
    var translated: String?
    URLSession.shared.dataTask(with: request) { data, response, _ in
      defer { semaphore.signal() }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200..<300).contains(status), let data else { return }
      translated = Self.parseTranslation(data)
    }.resume()
    if semaphore.wait(timeout: .now() + 8) == .timedOut {
      setStatus("Translation request timed out. The caption stays in the recognized language.")
      return nil
    }
    if translated == nil {
      setStatus("Translation request failed. The caption stays in the recognized language. The key was not logged.")
    }
    return translated
  }

  private func deeplCode(_ code: String) -> String {
    switch code {
    case "en": return "EN"
    case "pt": return "PT-PT"
    case "no": return "NB"
    case "zh": return "ZH"
    default: return code.uppercased()
    }
  }

  private func formEncode(_ text: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
  }

  private static func parseTranslation(_ data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) else {
      let plain = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let plain, !plain.isEmpty, plain.count < 800 { return plain }
      return nil
    }
    if let root = json as? [String: Any] {
      if let text = root["text"] as? String, !text.isEmpty { return text }
      if let list = root["translations"] as? [[String: Any]], let text = list.first?["text"] as? String, !text.isEmpty {
        return text
      }
    }
    return nil
  }
}

#if canImport(Translation)
@available(macOS 26.0, *)
enum LiveCaptionTranslator {
  static func system(_ text: String, source: String, target: String) async -> String? {
    guard source != "auto", source != "original", !target.isEmpty else { return nil }
    let sourceLanguage = Locale.Language(identifier: source)
    let targetLanguage = Locale.Language(identifier: target)
    let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
    do {
      let response = try await session.translate(text)
      let value = response.targetText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    } catch {
      return nil
    }
  }
}
#endif

final class LiveCaptionDownloads: NSObject, URLSessionDownloadDelegate {
  static let shared = LiveCaptionDownloads()
  private var session: URLSession!
  private var task: URLSessionDownloadTask?
  private var model: Preference.LiveCaptionModel = .base

  private override init() {
    super.init()
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForResource = 60 * 30
    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }

  func downloadSelected() {
    let selected: Preference.LiveCaptionModel = Preference.enum(for: .liveCaptionModel)
    model = selected
    task?.cancel()
    if LiveCaptionStore.isInstalled(selected) {
      LiveCaptionController.shared.setStatus("\(selected == .small ? "Small" : "Base") is already downloaded.")
      return
    }
    let name = selected == .small ? "Small (~500 MB)" : "Base (~150 MB)"
    LiveCaptionController.shared.setStatus("Downloading \(name). This is the speech model, not a build step.")
    var request = URLRequest(url: LiveCaptionStore.remoteURL(for: selected))
    request.setValue("IINA-Immersive-3D", forHTTPHeaderField: "User-Agent")
    task = session.downloadTask(with: request)
    task?.resume()
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    let name = model == .small ? "Small" : "Base"
    if totalBytesExpectedToWrite > 0 {
      let percent = Int((Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100)
      LiveCaptionController.shared.setStatus("Downloading \(name)… \(percent)%")
    } else {
      let mb = Double(totalBytesWritten) / 1_000_000
      LiveCaptionController.shared.setStatus(String(format: "Downloading %@… %.0f MB", name, mb))
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    let destination = LiveCaptionStore.file(for: model)
    let name = model == .small ? "Small" : "Base"
    do {
      try? FileManager.default.removeItem(at: destination)
      do {
        try FileManager.default.moveItem(at: location, to: destination)
      } catch {
        try FileManager.default.copyItem(at: location, to: destination)
      }
      let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      if size < 1_000_000 {
        try? FileManager.default.removeItem(at: destination)
        LiveCaptionController.shared.setStatus("\(name) download was too small and was discarded.")
        return
      }
      LiveCaptionController.shared.setStatus("\(name) model saved. The next caption window will load it. A few seconds of delay remains.")
    } catch {
      LiveCaptionController.shared.setStatus("Could not save the \(name) model.")
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error else { return }
    let cancelled = (error as NSError).code == NSURLErrorCancelled
    if cancelled { return }
    LiveCaptionController.shared.setStatus("Model download failed. Playback is unchanged.")
  }
}

final class WhisperBridge {
  private typealias LoadFn = @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
  private typealias TranscribeFn = @convention(c) (UnsafePointer<Float>, Int32, UnsafePointer<CChar>?, Int32, Int32, Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
  private typealias FreeFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
  private typealias AbortFn = @convention(c) (Int32) -> Void
  private typealias SegmentsFn = @convention(c) () -> Int32
  private typealias CStringFn = @convention(c) () -> UnsafePointer<CChar>?

  private let lock = NSLock()
  private var handle: UnsafeMutableRawPointer?
  private var loadFn: LoadFn?
  private var transcribeFn: TranscribeFn?
  private var freeFn: FreeFn?
  private var abortFn: AbortFn?
  private var segmentsFn: SegmentsFn?
  private var errorFn: CStringFn?
  private var backendFn: CStringFn?
  private var infoFn: CStringFn?
  private var loadedPath = ""
  private var reported = false

  func requestAbort(_ reason: String) {
    liveCaptionInfo("whisper abort requested: \(reason)")
    openIfNeeded()
    lock.lock()
    let abort = abortFn
    lock.unlock()
    abort?(1)
  }

  func clearAbort() {
    openIfNeeded()
    lock.lock()
    let abort = abortFn
    lock.unlock()
    abort?(0)
  }

  func lastSegments() -> Int {
    lock.lock()
    let segments = segmentsFn
    lock.unlock()
    guard let segments else { return -1 }
    return Int(segments())
  }

  func ensureLoaded(model: Preference.LiveCaptionModel) -> Bool {
    openIfNeeded()
    guard loadFn != nil else {
      LiveCaptionController.shared.setStatus(
        "libiina_whisper.dylib is not in the app. other/download_libs.sh builds it. Model weights are separate.",
        osd: "Live captions: error: whisper library missing"
      )
      return false
    }
    let path = LiveCaptionStore.file(for: model).path
    if path == loadedPath { return true }
    let name = URL(fileURLWithPath: path).lastPathComponent
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    liveCaptionInfo("loading model \(name) \(size) bytes")
    LiveCaptionController.shared.setStatus("Loading the Whisper model.", osd: "Live captions: loading model")
    let rc = path.withCString { loadFn!($0, 1) }
    if rc != 0 {
      let message = lastError()
      liveCaptionError("model load failed \(rc): \(message)")
      LiveCaptionController.shared.setStatus(
        "Could not load the Whisper model (\(message)).",
        osd: "Live captions: error: \(message)"
      )
      loadedPath = ""
      return false
    }
    loadedPath = path
    if !reported {
      reported = true
      let backend = cString(backendFn)
      let info = cString(infoFn)
      liveCaptionInfo("backend \(backend). \(info)")
      LiveCaptionController.shared.setStatus(
        "Whisper is loaded (\(backend)). Speech stays on this Mac. A caption still lags by a few seconds, and Small costs more CPU and GPU than Base.",
        osd: "Live captions: listening"
      )
    }
    return true
  }

  func transcribe(_ samples: [Float], language: String, translate: Bool, beam: Int, threads: Int) -> String? {
    guard let transcribeFn, !samples.isEmpty else { return nil }
    var out: UnsafeMutablePointer<CChar>?
    let rc: Int32 = samples.withUnsafeBufferPointer { buffer in
      language.withCString { lang in
        transcribeFn(buffer.baseAddress!, Int32(buffer.count), lang, translate ? 1 : 0, Int32(beam), Int32(threads), &out)
      }
    }
    defer {
      if let out {
        freeFn?(out)
      }
    }
    let segments = lastSegments()
    guard rc == 0, let out else {
      if rc == 4 {
        liveCaptionInfo("whisper aborted segments \(segments)")
        return nil
      }
      let message = lastError()
      liveCaptionError("whisper rc \(rc): \(message)")
      LiveCaptionController.shared.setStatus(
        "Speech recognition failed (\(message)).",
        osd: "Live captions: error: \(message)"
      )
      return nil
    }
    liveCaptionInfo("whisper segments \(segments) language \(language)")
    return String(cString: out)
  }

  private func lastError() -> String {
    guard let errorFn, let pointer = errorFn() else { return "unknown" }
    let text = String(cString: pointer)
    return text.isEmpty ? "unknown" : text
  }

  private func cString(_ fn: CStringFn?) -> String {
    guard let fn, let pointer = fn() else { return "" }
    return String(cString: pointer)
  }

  private func openIfNeeded() {
    lock.lock()
    if handle != nil {
      lock.unlock()
      return
    }
    let bundled = Bundle.main.privateFrameworksURL?.appendingPathComponent("libiina_whisper.dylib")
    let besideExecutable = Bundle.main.executableURL?
      .deletingLastPathComponent()
      .appendingPathComponent("../Frameworks/libiina_whisper.dylib")
      .standardized
    let candidates = [bundled, besideExecutable].compactMap { $0 }
    let url = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    guard let url else {
      lock.unlock()
      let tried = candidates.map(\.path).joined(separator: ", ")
      liveCaptionError("libiina_whisper.dylib is not in the app. Looked in \(tried)")
      LiveCaptionController.shared.setStatus(
        "libiina_whisper.dylib is not in the app.",
        osd: "Live captions: error: whisper library missing"
      )
      return
    }
    dlerror()
    guard let opened = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
      let reason = dlerror().map { String(cString: $0) } ?? "dlopen failed"
      lock.unlock()
      liveCaptionError("dlopen \(url.path) failed: \(reason)")
      LiveCaptionController.shared.setStatus(
        "Could not open the Whisper library. \(reason)",
        osd: "Live captions: error: \(reason)"
      )
      return
    }
    handle = opened
    loadFn = function("iina_whisper_load")
    transcribeFn = function("iina_whisper_transcribe")
    freeFn = function("iina_whisper_free_text")
    abortFn = function("iina_whisper_set_abort")
    segmentsFn = function("iina_whisper_last_segments")
    errorFn = function("iina_whisper_last_error")
    backendFn = function("iina_whisper_backend")
    infoFn = function("iina_whisper_system_info")
    let missing = [
      loadFn == nil ? "load" : nil,
      transcribeFn == nil ? "transcribe" : nil
    ].compactMap { $0 }
    lock.unlock()
    if missing.isEmpty {
      liveCaptionInfo("opened \(url.lastPathComponent) from \(url.deletingLastPathComponent().path)")
    } else {
      liveCaptionError("opened \(url.path) but missing symbols: \(missing.joined(separator: ", "))")
    }
  }

  private func function<T>(_ name: String) -> T? {
    guard let handle, let symbol = dlsym(handle, name) else { return nil }
    return unsafeBitCast(symbol, to: T.self)
  }
}

final class CaptionPCM {
  private let lock = NSLock()
  private var origin: Double = 0
  private var samples: [Float] = []
  private let rate = 16000.0
  private(set) var aligned = true

  var startTime: Double {
    lock.lock()
    defer { lock.unlock() }
    return origin
  }

  func reset(at time: Double, aligned: Bool) {
    lock.lock()
    origin = time
    samples.removeAll(keepingCapacity: true)
    self.aligned = aligned
    lock.unlock()
  }

  func append(_ chunk: [Float], at time: Double) {
    guard !chunk.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    if samples.isEmpty {
      origin = time
      samples = chunk
      return
    }
    let end = origin + Double(samples.count) / rate
    if time > end + 0.45 || time + 0.05 < origin {
      origin = time
      samples = chunk
      return
    }
    if time >= end - 0.02 {
      samples.append(contentsOf: chunk)
    } else if time + Double(chunk.count) / rate > end + 0.02 {
      let skip = max(0, Int((end - time) * rate))
      if skip < chunk.count {
        samples.append(contentsOf: chunk[skip...])
      }
    }
    let maxCount = Int(rate * 45)
    if samples.count > maxCount {
      let drop = samples.count - maxCount
      samples.removeFirst(drop)
      origin += Double(drop) / rate
    }
  }

  func coveredUntil() -> Double {
    lock.lock()
    defer { lock.unlock() }
    return origin + Double(samples.count) / rate
  }

  func slice(from start: Double, to end: Double) -> CaptionChunk? {
    lock.lock()
    defer { lock.unlock() }
    guard aligned, end > start else { return nil }
    let have = origin + Double(samples.count) / rate
    if end > have + 0.35 || start + 0.05 < origin { return nil }
    let a = max(0, Int((start - origin) * rate))
    let b = min(samples.count, Int((end - origin) * rate))
    guard b - a >= 8000 else { return nil }
    let actual = origin + Double(a) / rate
    return CaptionChunk(samples: Array(samples[a..<b]), start: actual)
  }

  func latest(seconds: Double) -> CaptionChunk? {
    lock.lock()
    defer { lock.unlock() }
    let need = Int(rate * seconds)
    guard samples.count >= max(8000, need / 2) else { return nil }
    let count = min(samples.count, need)
    let actual = origin + Double(samples.count - count) / rate
    return CaptionChunk(samples: Array(samples.suffix(count)), start: actual)
  }
}

final class CaptionSource {
  struct Failure {
    var message: String
    var osd: String
  }

  let pcm = CaptionPCM()
  private let queue = DispatchQueue(label: "com.colliderli.iina.live-caption-audio", qos: .userInitiated)
  private var decoder: OpaquePointer?
  private var mode: Mode = .closed
  private var closed = true
  private var openEnded = false
  private var liveEdge = false
  private var localFile = false
  private var cacheThin = false
  private var mediaDuration = Double.infinity
  private var failureStatus: String?
  private var failureOSD: String?
  private var loggedFailure = false
  private var requestedStart = 0.0
  private var requestedEnd = 0.0
  private var playhead = 0.0
  private let stateLock = NSLock()

  var isLiveEdge: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return liveEdge
  }

  var isOpenEnded: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return openEnded
  }

  var isLocalFile: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return localFile
  }

  private func setCapture(live: Bool, openEnded: Bool, localFile: Bool, duration: Double) {
    stateLock.lock()
    liveEdge = live
    self.openEnded = openEnded
    self.localFile = localFile
    mediaDuration = duration
    stateLock.unlock()
  }

  private enum Mode: String {
    case closed
    case file
    case cache
    case failed
  }

  func diagnostic() -> String {
    var text = ""
    queue.sync {
      let coveredStart = self.pcm.startTime
      let coveredEnd = self.pcm.coveredUntil()
      let aligned = self.pcm.aligned ? "yes" : "no"
      text = "mode=\(self.mode.rawValue) requested=\(self.seconds(self.requestedStart))-\(self.seconds(self.requestedEnd)) covered=\(self.seconds(coveredStart))-\(self.seconds(coveredEnd)) playhead=\(self.seconds(self.playhead)) aligned=\(aligned)"
      if self.cacheThin {
        text += " cache=thin"
      }
      if let failure = self.failureOSD {
        text += " failure=\(failure)"
      }
    }
    return text
  }

  func failure() -> Failure? {
    var result: Failure?
    queue.sync {
      if let message = self.failureStatus, let osd = self.failureOSD {
        result = Failure(message: message, osd: osd)
      }
    }
    return result
  }

  func bufferedSeconds() -> Double {
    var span = 0.0
    queue.sync {
      span = max(0, self.pcm.coveredUntil() - self.pcm.startTime)
    }
    return span
  }

  func isCacheThin() -> Bool {
    var thin = false
    queue.sync { thin = self.cacheThin }
    return thin
  }

  func open(url: URL, userAgent: String?, at time: Double) {
    queue.async {
      self.closeOnQueue()
      self.closed = false
      self.playhead = time.isFinite ? time : 0
      if url.isFileURL {
        self.openLocal(url)
      } else {
        if let userAgent, !userAgent.isEmpty {
          liveCaptionInfo("network captions use the open player connection")
        }
        liveCaptionInfo("network audio comes from the player cache")
        self.beginCache(localFile: false)
      }
    }
  }

  func close() {
    queue.async {
      self.closeOnQueue()
    }
  }

  /// Decode enough audio that the playhead window can be cut. `ahead` only
  /// extends the read. It does not move the window off the playhead.
  func follow(playhead: Double, window: Double, ahead: Double) {
    queue.async {
      guard !self.closed, self.mode != .failed else { return }
      let position = playhead.isFinite ? max(0, playhead) : 0
      self.playhead = position
      if self.mode == .file {
        self.followFile(playhead: position, window: window, ahead: ahead)
      } else if self.mode == .cache {
        self.followCache(playhead: position, window: window, ahead: ahead)
      }
    }
  }

  /// A chunk runs when the playhead sits inside the buffer, even if the
  /// lookahead past that playhead is not filled yet.
  func samples(playhead: Double, window: Double) -> CaptionChunk? {
    var result: CaptionChunk?
    queue.sync {
      let position = playhead.isFinite ? max(0, playhead) : self.playhead
      self.playhead = position
      let origin = self.pcm.startTime
      let have = self.pcm.coveredUntil()
      let requestedStart = position
      let requestedEnd = position + window
      self.requestedStart = requestedStart
      self.requestedEnd = requestedEnd
      let overlapStart = max(requestedStart, origin)
      let overlapEnd = min(requestedEnd, have)
      let overlap = overlapEnd - overlapStart
      let inside = position >= origin - 0.3 && position <= have + 0.15
      liveCaptionInfo("window requested \(self.seconds(requestedStart))-\(self.seconds(requestedEnd)) covered \(self.seconds(origin))-\(self.seconds(have)) playhead \(self.seconds(position)) overlap \(self.seconds(max(0, overlap)))")
      guard self.mode != .failed, self.mode != .closed, self.pcm.aligned, inside, overlap >= 0.5 else { return }
      result = self.pcm.slice(from: overlapStart, to: overlapEnd)
      if result == nil {
        liveCaptionInfo("window covered but slice rejected")
      }
    }
    return result
  }

  private func seconds(_ value: Double) -> String {
    guard value.isFinite else { return "nan" }
    return String(format: "%.2f", value)
  }

  private func openLocal(_ url: URL) {
    var error = [CChar](repeating: 0, count: 512)
    let opened = url.path.withCString { iina_caption_open($0, &error, Int32(error.count)) }
    guard let opened else {
      let message = String(cString: error)
      if message.contains("no audio") {
        liveCaptionError("file audio open failed: \(message)")
        self.fail(message: "This item has no audio track, so there is nothing to caption.", osd: "no audio track", terminal: true)
        return
      }
      liveCaptionError("file audio open failed: \(message); reading the player cache")
      self.beginCache(localFile: true)
      return
    }
    decoder = opened
    mode = .file
    let duration = iina_caption_duration(opened)
    let finite = duration.isFinite && duration > 1
    setCapture(live: false, openEnded: false, localFile: true, duration: finite ? duration : .infinity)
    clearFailure()
    pcm.reset(at: 0, aligned: true)
    liveCaptionInfo("decoding file audio with libav")
  }

  private func beginCache(localFile: Bool) {
    // Assume a network item is live until the duration read lands. Reading
    // mpv here with main.sync deadlocks: open() is queued from the main
    // thread, and that thread is still inside start().
    mode = .cache
    setCapture(live: !localFile, openEnded: !localFile, localFile: localFile, duration: .infinity)
    pcm.reset(at: 0, aligned: true)
    clearFailure()
    liveCaptionInfo(localFile ? "cache audio for a local file" : "cache audio for a network stream")
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard !Immersive3DController.shared.isShuttingDown else { return }
      guard !PlayerCore.playerCores.isEmpty, PlayerCore.active.mpv != nil, PlayerCore.active.info.state.active else { return }
      let duration = PlayerCore.active.mpv.getDouble(MPVProperty.duration)
      let finite = duration.isFinite && duration > 1 && duration < 86400
      self.queue.async {
        guard !self.closed, self.mode == .cache else { return }
        self.setCapture(live: !finite && !localFile, openEnded: !finite && !localFile, localFile: localFile, duration: finite ? duration : .infinity)
        liveCaptionInfo(finite || localFile ? "cache audio for a finite item" : "cache audio for a live stream")
      }
    }
  }

  private func followFile(playhead: Double, window: Double, ahead: Double) {
    guard decoder != nil else { return }
    let origin = pcm.startTime
    let have = pcm.coveredUntil()
    let need = playhead + window
    let coversPlayhead = origin <= playhead + 0.3 && have >= playhead + 0.5
    let coversWindow = coversPlayhead && have + 0.2 >= need
    if coversWindow { return }
    let start = coversPlayhead ? max(0, have - 0.25) : max(0, playhead - 0.2)
    let seconds = max(window, (playhead + window + ahead) - start)
    if !coversPlayhead && origin > playhead + 0.3 {
      liveCaptionInfo("retarget file audio to playhead \(self.seconds(playhead)) (buffer started at \(self.seconds(origin)))")
    }
    readDecoder(start: start, seconds: min(30, seconds + 0.4), dumpStart: nil)
  }

  private func followCache(playhead: Double, window: Double, ahead: Double) {
    let origin = pcm.startTime
    let have = pcm.coveredUntil()
    if origin <= playhead + 0.3 && have + 0.2 >= playhead + window {
      cacheThin = false
      return
    }
    let request = CacheDump()
    let want = window + max(0, ahead) + 0.4
    DispatchQueue.main.sync {
      guard !self.closed else { return }
      guard !Immersive3DController.shared.isShuttingDown else { return }
      guard !PlayerCore.playerCores.isEmpty else { return }
      let core = PlayerCore.active
      guard core.mpv != nil, core.info.state.active else { return }
      let position = core.mpv.getDouble(MPVProperty.timePos)
      let cacheDuration = core.mpv.getDouble(MPVProperty.demuxerCacheDuration)
      let cacheTime = core.mpv.getDouble(MPVProperty.demuxerCacheTime)
      let play = position.isFinite ? position : playhead
      let cacheEnd = cacheTime.isFinite ? cacheTime : play + (cacheDuration.isFinite ? cacheDuration : 0)
      let span = cacheDuration.isFinite ? max(0, cacheDuration) : max(0, cacheEnd - play)
      let cacheStart = max(0, cacheEnd - span)
      request.span = span
      if span < 0.4 || cacheEnd - cacheStart < 0.4 {
        request.usable = true
        return
      }
      var dumpEnd = min(cacheEnd, play + want)
      var dumpStart = max(cacheStart, play - 0.2)
      if dumpEnd - dumpStart < 0.4 {
        dumpStart = cacheStart
        dumpEnd = min(cacheEnd, dumpStart + want)
      }
      if dumpEnd - dumpStart < 0.4 {
        request.usable = true
        return
      }
      let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("iina-live-caption-\(UUID().uuidString).mkv")
      try? FileManager.default.removeItem(atPath: path)
      request.path = path
      request.start = dumpStart
      request.end = dumpEnd
      var code: Int32 = 0
      core.mpv.command(.dumpCache, args: [
        String(format: "%.3f", dumpStart),
        String(format: "%.3f", dumpEnd),
        path
      ], checkError: false) { code = $0 }
      request.code = code
      request.ran = true
      request.usable = true
    }
    guard request.usable else { return }
    if !request.ran {
      cacheThin = true
      liveCaptionInfo("player cache thin span \(self.seconds(request.span))")
      return
    }
    cacheThin = false
    defer { try? FileManager.default.removeItem(atPath: request.path) }
    if request.code < 0 {
      liveCaptionError("player cache export failed \(request.code)")
      fail(message: "Live captions could not read the player cache (\(request.code)).", osd: "player cache failed", terminal: false)
      return
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: request.path)[.size] as? NSNumber)?.intValue ?? 0
    if size < 1000 {
      cacheThin = true
      liveCaptionInfo("player cache export was empty")
      return
    }
    readDump(path: request.path, dumpStart: request.start, dumpEnd: request.end)
  }

  private func readDump(path: String, dumpStart: Double, dumpEnd: Double) {
    var error = [CChar](repeating: 0, count: 512)
    let opened = path.withCString { iina_caption_open($0, &error, Int32(error.count)) }
    guard let opened else {
      let message = String(cString: error)
      liveCaptionError("cache audio open failed: \(message)")
      if message.contains("no audio") {
        fail(message: "This item has no audio track, so there is nothing to caption.", osd: "no audio track", terminal: true)
      } else {
        fail(message: "Captions could not decode audio from the player (\(message)).", osd: "audio decode failed", terminal: false)
      }
      return
    }
    decoder = opened
    let seconds = max(0.5, dumpEnd - dumpStart)
    readDecoder(start: 0, seconds: min(30, seconds + 0.3), dumpStart: dumpStart)
    iina_caption_close(opened)
    if decoder == opened {
      decoder = nil
    }
  }

  private func readDecoder(start: Double, seconds: Double, dumpStart: Double?) {
    guard let decoder else { return }
    var error = [CChar](repeating: 0, count: 512)
    var decoded = IINACaptionPCM()
    let rc = iina_caption_read(decoder, start, seconds, &decoded, &error, Int32(error.count))
    defer { iina_caption_pcm_free(&decoded) }
    guard rc == 0, let pointer = decoded.samples, decoded.count > 0 else {
      let message = String(cString: error)
      liveCaptionError("audio read failed \(rc): \(message)")
      if message.contains("no audio") || rc == 2 {
        fail(message: "This item has no audio track, so there is nothing to caption.", osd: "no audio track", terminal: true)
      }
      return
    }
    let samples = Array(UnsafeBufferPointer(start: pointer, count: Int(decoded.count)))
    let decodedStart = decoded.start
    let origin: Double
    if let dumpStart {
      if abs(decodedStart - dumpStart) < 3 {
        origin = decodedStart
      } else {
        origin = dumpStart + max(0, decodedStart)
      }
    } else {
      origin = decodedStart
    }
    let level = captionLevel(samples)
    liveCaptionInfo("decoded samples \(samples.count) origin \(self.seconds(origin)) rms \(String(format: "%.4f", level)) rate \(decoded.source_rate) ch \(decoded.channels)")
    clearFailure()
    pcm.append(samples, at: origin)
  }

  private func captionLevel(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var acc: Float = 0
    for value in samples {
      acc += value * value
    }
    return sqrt(acc / Float(samples.count))
  }

  private func fail(message: String, osd: String, terminal: Bool) {
    failureStatus = message
    failureOSD = osd
    if terminal {
      mode = .failed
    }
    if !loggedFailure {
      loggedFailure = true
      liveCaptionError(message)
    }
  }

  private func clearFailure() {
    failureStatus = nil
    failureOSD = nil
    loggedFailure = false
    cacheThin = false
  }

  private func closeOnQueue() {
    closed = true
    mode = .closed
    setCapture(live: false, openEnded: false, localFile: false, duration: .infinity)
    if let decoder {
      iina_caption_close(decoder)
    }
    decoder = nil
    cacheThin = false
    failureStatus = nil
    failureOSD = nil
    loggedFailure = false
    pcm.reset(at: 0, aligned: true)
  }
}

private final class CacheDump {
  var start = 0.0
  var end = 0.0
  var span = 0.0
  var code: Int32 = 0
  var path = ""
  var ran = false
  var usable = false
}

private extension NSValueTransformerName {
  static let liveCaptionDelayText = NSValueTransformerName("LiveCaptionDelayText")
}

/// Slider seconds to a short label such as "5 s". The binding reads this on
/// every continuous tick, so the number moves with the knob.
@objc(LiveCaptionDelayText)
final class LiveCaptionDelayText: ValueTransformer {
  override class func transformedValueClass() -> AnyClass { NSString.self }

  override class func allowsReverseTransformation() -> Bool { false }

  override func transformedValue(_ value: Any?) -> Any? {
    let seconds = (value as? NSNumber)?.doubleValue ?? 0
    return LiveCaptionDelayText.label(seconds)
  }

  static func label(_ seconds: Double) -> String {
    let tenths = (min(12, max(2, seconds)) * 10).rounded() / 10
    if abs(tenths - tenths.rounded()) < 0.05 {
      return "\(Int(tenths.rounded())) s"
    }
    return String(format: "%.1f s", tenths)
  }
}

final class LiveCaptionSettingsView: NSView {
  private let status = NSTextField(wrappingLabelWithString: "")
  private let syncLabel = NSTextField(wrappingLabelWithString: "")
  private var sourcePopup: NSPopUpButton!
  private var targetPopup: NSPopUpButton!
  private let keyField = NSSecureTextField()
  private var keyDirty = false
  private var delaySlider: NSSlider!
  private let delayValueLabel = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    LiveCaptionController.shared.startObserving()

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      stack.widthAnchor.constraint(equalToConstant: 420)
    ])

    sourcePopup = popup(LiveCaptionLanguage.speech, action: #selector(sourceChanged(_:)))
    targetPopup = popup(LiveCaptionLanguage.targets, action: #selector(targetChanged(_:)))
    select(sourcePopup, code: Preference.string(for: .liveCaptionSourceLanguage) ?? "auto")
    select(targetPopup, code: Preference.string(for: .liveCaptionTargetLanguage) ?? "original")

    let endpoint = NSTextField()
    endpoint.translatesAutoresizingMaskIntoConstraints = false
    endpoint.placeholderString = "https://api-free.deepl.com/v2/translate"
    endpoint.bind(.value, to: UserDefaults.standard, withKeyPath: Preference.Key.liveCaptionTranslateEndpoint.rawValue)
    endpoint.widthAnchor.constraint(equalToConstant: 400).isActive = true

    keyField.translatesAutoresizingMaskIntoConstraints = false
    keyField.placeholderString = keySaved() ? "Key saved in Keychain" : "Translation API key"
    keyField.widthAnchor.constraint(equalToConstant: 400).isActive = true
    NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: NSControl.textDidChangeNotification, object: keyField)
    NotificationCenter.default.addObserver(self, selector: #selector(keyEdited), name: NSControl.textDidEndEditingNotification, object: keyField)

    let download = NSButton(title: "Download selected model", target: self, action: #selector(downloadModel))
    download.bezelStyle = .rounded

    status.translatesAutoresizingMaskIntoConstraints = false
    status.preferredMaxLayoutWidth = 400
    status.textColor = .secondaryLabelColor
    status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    delaySlider = NSSlider(value: Preference.double(for: .liveCaptionLiveDelay), minValue: 2, maxValue: 12, target: self, action: #selector(delayChanged(_:)))
    delaySlider.isContinuous = true
    delaySlider.translatesAutoresizingMaskIntoConstraints = false
    delaySlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    delaySlider.widthAnchor.constraint(equalToConstant: 400).isActive = true

    delayValueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    delayValueLabel.alignment = .left
    delayValueLabel.setContentHuggingPriority(.required, for: .horizontal)
    delayValueLabel.stringValue = LiveCaptionDelayText.label(delaySlider.doubleValue)
    ValueTransformer.setValueTransformer(LiveCaptionDelayText(), forName: .liveCaptionDelayText)
    delayValueLabel.bind(.value, to: delaySlider!, withKeyPath: "doubleValue", options: [
      .continuouslyUpdatesValue: true,
      .valueTransformerName: NSValueTransformerName.liveCaptionDelayText
    ])

    let auto = NSButton(checkboxWithTitle: "Auto-tune the live buffer to the measured transcription time", target: self, action: #selector(autoChanged(_:)))
    auto.state = Preference.bool(for: .liveCaptionLiveDelayAuto) ? .on : .off

    syncLabel.translatesAutoresizingMaskIntoConstraints = false
    syncLabel.preferredMaxLayoutWidth = 400
    syncLabel.textColor = .secondaryLabelColor
    syncLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    refreshStatus()

    let note = NSTextField(wrappingLabelWithString: "A local file is decoded ahead of the playhead, and playback is not held back. A network or live stream uses audio the player has already buffered, so the provider is not opened a second time. A live channel holds the picture in mpv's cache (about 4–6 seconds unless transcription takes longer). A file never takes that hold. Changing channel detects again. Turning captions off jumps that channel back to live. Delay live TV, above, turns the hold off and leaves the channel at the live edge. The banner shows Subtitles synced, live +Ns while the hold is on. Depth is computed from the frame already on screen, so it waits with that picture. Each line uses the audio time, not the time the text arrived. Base is lighter; Small uses more CPU and GPU on an M2. Whisper translates into English only. Other languages use the macOS 26 system translator when that language is installed, or the API key (caption text only). On earlier macOS, without a key, the line stays in the recognized language. Place ggml-base-encoder.mlmodelc or ggml-small-encoder.mlmodelc next to the ggml file to use the Core ML encoder; otherwise Metal or the CPU runs the model. This was not timed on a Mac.")
    note.preferredMaxLayoutWidth = 400
    note.textColor = .secondaryLabelColor
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    stack.addArrangedSubview(labeled("Source language", sourcePopup))
    stack.addArrangedSubview(labeled("Target language", targetPopup))
    stack.addArrangedSubview(liveDelayControl())
    stack.addArrangedSubview(auto)
    stack.addArrangedSubview(syncLabel)
    stack.addArrangedSubview(download)
    stack.addArrangedSubview(status)
    stack.addArrangedSubview(labeled("Translation URL", endpoint))
    stack.addArrangedSubview(labeled("API key", keyField))
    stack.addArrangedSubview(note)

    NotificationCenter.default.addObserver(self, selector: #selector(refreshStatus), name: .liveCaptionStatusChanged, object: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func popup(_ pairs: [(String, String)], action: Selector) -> NSPopUpButton {
    let button = NSPopUpButton()
    button.target = self
    button.action = action
    for pair in pairs {
      button.addItem(withTitle: pair.1)
      button.lastItem?.representedObject = pair.0
    }
    return button
  }

  private func select(_ button: NSPopUpButton, code: String) {
    for item in button.itemArray where (item.representedObject as? String) == code {
      button.select(item)
      return
    }
  }

  private func labeled(_ title: String, _ control: NSView) -> NSView {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .secondaryLabelColor
    let stack = NSStackView(views: [label, control])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    return stack
  }

  private func keySaved() -> Bool {
    guard let value = try? KeychainAccess.read(username: "api-key", forService: .liveCaptionTranslate).password else {
      return false
    }
    return !value.isEmpty
  }

  @objc private func sourceChanged(_ sender: NSPopUpButton) {
    let code = sender.selectedItem?.representedObject as? String ?? "auto"
    Preference.set(code, for: .liveCaptionSourceLanguage)
  }

  @objc private func targetChanged(_ sender: NSPopUpButton) {
    let code = sender.selectedItem?.representedObject as? String ?? "original"
    Preference.set(code, for: .liveCaptionTargetLanguage)
  }

  private func liveDelayControl() -> NSView {
    let caption = NSTextField(labelWithString: "Live buffer (seconds)")
    caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    caption.textColor = .secondaryLabelColor
    let header = NSStackView(views: [caption, delayValueLabel])
    header.orientation = .horizontal
    header.alignment = .firstBaseline
    header.spacing = 8
    let column = NSStackView(views: [header, delaySlider])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 2
    return column
  }

  @objc private func delayChanged(_ sender: NSSlider) {
    let seconds = min(12, max(2, sender.doubleValue))
    delayValueLabel.stringValue = LiveCaptionDelayText.label(seconds)
    Preference.set(seconds, for: .liveCaptionLiveDelay)
  }

  @objc private func autoChanged(_ sender: NSButton) {
    Preference.set(sender.state == .on, for: .liveCaptionLiveDelayAuto)
  }

  @objc private func downloadModel() {
    LiveCaptionDownloads.shared.downloadSelected()
  }

  @objc private func keyChanged() {
    keyDirty = true
  }

  @objc private func keyEdited() {
    guard keyDirty else { return }
    keyDirty = false
    let value = keyField.stringValue
    if value.isEmpty {
      try? KeychainAccess.delete(username: "api-key", forService: .liveCaptionTranslate)
      keyField.placeholderString = "Translation API key"
    } else {
      do {
        try KeychainAccess.write(username: "api-key", password: value, forService: .liveCaptionTranslate)
        keyField.stringValue = ""
        keyField.placeholderString = "Key saved in Keychain"
      } catch {
        LiveCaptionController.shared.setStatus("Could not save the translation key.")
      }
    }
  }

  @objc private func refreshStatus() {
    status.stringValue = LiveCaptionController.shared.statusText
    syncLabel.stringValue = LiveCaptionController.shared.syncText
  }
}
