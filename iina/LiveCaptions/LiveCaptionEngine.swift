//
//  LiveCaptionEngine.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Live auto subtitles. libmpv does not export decoded PCM. A lavfi asplit
//  graph inside mpv cannot hand samples to the host, and replacing the audio
//  output would mute playback. This engine decodes the same URL again with
//  AVFoundation, keeps that audio aligned to mpv's time-pos when the asset can
//  be seeked, and runs whisper.cpp in-process. Live IPTV is a second read of
//  that URL and can sit a few seconds off the picture. Only caption text leaves
//  the Mac, and only when a translation API key is set.

import AVFoundation
import AudioToolbox
import Cocoa
import Darwin
import MediaToolbox

#if canImport(Translation)
import Translation
#endif

extension Notification.Name {
  static let liveCaptionStatusChanged = Notification.Name("IINALiveCaptionStatusChanged")
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
  private let subtitleURL = FileManager.default.temporaryDirectory.appendingPathComponent("iina-live-caption.ass")

  private(set) var statusText = "Live captions are off."

  private init() {}

  func startObserving() {
    guard !observing else { return }
    observing = true
    preferences.add(.liveCaptionEnabled) { [weak self] _ in
      DispatchQueue.main.async {
        self?.applyEnabled()
      }
    }
  }

  func noteFileStarted(core: PlayerCore) {
    startObserving()
    self.core = core
    guard Preference.bool(for: .liveCaptionEnabled) else {
      stop()
      return
    }
    start()
  }

  func noteFileEnded() {
    stop()
  }

  func attachIfNeeded() {
    guard running else { return }
    overlay.attachIfNeeded()
  }

  func setStatus(_ text: String) {
    let apply = {
      self.statusText = text
      NotificationCenter.default.post(name: .liveCaptionStatusChanged, object: nil)
    }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async(execute: apply)
    }
  }

  private func applyEnabled() {
    guard Preference.bool(for: .liveCaptionEnabled) else {
      stop()
      return
    }
    guard !PlayerCore.playerCores.isEmpty else { return }
    let active = PlayerCore.active
    guard active.info.state.active, active.info.currentURL != nil else { return }
    core = active
    start()
  }

  private func start() {
    guard let core, core.mpv != nil, let url = core.info.currentURL else { return }
    if running, activeURL == url { return }
    stop()
    generation += 1
    let token = generation
    running = true
    activeURL = url
    lastRaw = ""
    lastTranslated = ""
    lastText = ""
    let agent = core.mpv.getString("user-agent")
    let time = core.mpv.getDouble(MPVProperty.timePos)
    source.open(url: url, userAgent: agent, at: time.isFinite ? time : 0)
    installTimer()
    overlay.attachIfNeeded()
    let pace = CaptionPace.current()
    setStatus("Listening. Captions lag the picture by about \(Int(pace.window)) seconds, plus model time.")
    schedule(generation: token, delay: 0.4)
  }

  private func stop() {
    generation += 1
    running = false
    activeURL = nil
    whisper.setAbort(1)
    source.close()
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
  }

  private func installTimer() {
    displayTimer?.invalidate()
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.redisplay()
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

  private func step(generation token: Int) {
    guard token == generation else { return }
    let pace = CaptionPace.current()
    let model: Preference.LiveCaptionModel = Preference.enum(for: .liveCaptionModel)
    guard LiveCaptionStore.isInstalled(model) else {
      let name = model == .small ? "Small" : "Base"
      publish("Live captions: download the \(name) model in Settings → Subtitles.", token: token)
      setStatus("\(name) model is not downloaded. It stays on this Mac, under Application Support.")
      return
    }
    guard whisper.ensureLoaded(model: model) else {
      publish("Live captions could not load whisper.cpp.", token: token)
      return
    }
    guard let time = mediaTime(), time.isFinite else { return }
    source.follow(time: time, window: pace.window)
    let samples = source.samples(endingAt: time, window: pace.window)
    guard let samples, samples.count >= 8000 else { return }
    if rms(samples) < 0.008 {
      publish("", token: token)
      return
    }
    whisper.setAbort(0)
    let sourceLanguage = Preference.string(for: .liveCaptionSourceLanguage) ?? "auto"
    let target = Preference.string(for: .liveCaptionTargetLanguage) ?? "original"
    let translateToEnglish = target == "en" && sourceLanguage != "en"
    guard let raw = whisper.transcribe(
      samples,
      language: sourceLanguage,
      translate: translateToEnglish,
      beam: pace.beam,
      threads: pace.threads
    ) else {
      return
    }
    guard token == generation else { return }
    let cleaned = clean(raw)
    if cleaned == lastRaw {
      publish(lastTranslated, token: token)
      return
    }
    lastRaw = cleaned
    let translated = translate(cleaned, sourceLanguage: sourceLanguage, target: target, alreadyEnglish: translateToEnglish)
    lastTranslated = translated
    publish(translated, token: token)
  }

  private func publish(_ text: String, token: Int) {
    guard token == generation else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.generation == token else { return }
      self.lastText = text
      self.redisplay()
    }
  }

  private func redisplay() {
    guard running else { return }
    let sbs = IPTVLiveOverlayController.duplicatesEyes
    let chrome = GlassesEyeControls.shared.shown
    let textChanged = lastText != displayedText
    let modeChanged = sbs != lastSBS
    let chromeChanged = chrome != lastChrome
    if !textChanged && !modeChanged && !chromeChanged { return }
    let wasSBS = lastSBS
    lastSBS = sbs
    lastChrome = chrome
    displayedText = lastText
    if sbs {
      if !wasSBS {
        suppressMPVCaption()
        hideShiftedSubtitles()
      }
      overlay.setText(lastText)
      overlay.attachIfNeeded()
    } else {
      if wasSBS {
        restoreShiftedSubtitles()
      }
      overlay.setText("")
      if textChanged || modeChanged {
        showFlatCaption(lastText)
      }
    }
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

  private func showFlatCaption(_ text: String) {
    guard mpvIsUsable(), let core else { return }
    writeASS(text)
    if mpvTrackID == nil && !usingOSD {
      if previousSID == nil {
        previousSID = core.mpv.getInt("sid")
      }
      var code: Int32 = 0
      core.mpv.command(.subAdd, args: [subtitleURL.mpvStr, "select", "Live captions", "und"], checkError: false) { code = $0 }
      let sid = core.mpv.getInt("sid")
      if code >= 0 && sid > 0 {
        mpvTrackID = sid
        usingOSD = false
      } else {
        usingOSD = true
      }
    }
    if let track = mpvTrackID, !usingOSD {
      core.mpv.command(.subReload, args: [String(track)], checkError: false)
    }
    if usingOSD || mpvTrackID == nil {
      if text.isEmpty {
        core.mpv.command(.osdOverlay, args: ["7", "none", "", "0", "0", "0"], checkError: false)
      } else {
        let line = "{\\an2\\fs48\\bord3}" + escapeASS(text)
        core.mpv.command(.osdOverlay, args: ["7", "ass", line, "1920", "1080", "0"], checkError: false)
      }
    }
  }

  private func suppressMPVCaption() {
    guard mpvIsUsable(), let core else { return }
    if let track = mpvTrackID {
      core.mpv.command(.subRemove, args: [String(track)], checkError: false)
      mpvTrackID = nil
    }
    core.mpv.command(.osdOverlay, args: ["7", "none", "", "0", "0", "0"], checkError: false)
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
      usingOSD = false
      try? FileManager.default.removeItem(at: subtitleURL)
      return
    }
    suppressMPVCaption()
    guard let core else {
      previousSID = nil
      return
    }
    if let previous = previousSID, previous > 0 {
      core.mpv.setInt("sid", previous)
    }
    previousSID = nil
    restoreShiftedSubtitles()
    try? FileManager.default.removeItem(at: subtitleURL)
  }

  private func writeASS(_ text: String) {
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
    Dialogue: 0,0:00:00.00,9:59:59.99,Default,,0,0,0,,\(escapeASS(text))
    """
    try? body.data(using: .utf8)?.write(to: subtitleURL, options: .atomic)
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
      setStatus("Showing the recognized language. macOS 13 has no system translator for this pair, and no translation API key is saved. Whisper itself only translates into English.")
    }
    return text
  }

  private func systemTranslate(_ text: String, source: String, target: String) -> String? {
    #if canImport(Translation)
    guard #available(macOS 15.0, *) else { return nil }
    let semaphore = DispatchSemaphore(value: 0)
    var output: String?
    DispatchQueue.main.async {
      Task {
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
@available(macOS 15.0, *)
enum LiveCaptionTranslator {
  static func system(_ text: String, source: String, target: String) async -> String? {
    let sourceLanguage: Locale.Language? = (source == "auto" || source == "original") ? nil : Locale.Language(identifier: source)
    let session = TranslationSession(installedSource: sourceLanguage, target: Locale.Language(identifier: target))
    do {
      let response = try await session.translate(text)
      let value = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
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
    let destination = LiveCaptionStore.file(for: selected)
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
  private typealias CStringFn = @convention(c) () -> UnsafePointer<CChar>?

  private let lock = NSLock()
  private var handle: UnsafeMutableRawPointer?
  private var loadFn: LoadFn?
  private var transcribeFn: TranscribeFn?
  private var freeFn: FreeFn?
  private var abortFn: AbortFn?
  private var errorFn: CStringFn?
  private var backendFn: CStringFn?
  private var infoFn: CStringFn?
  private var loadedPath = ""
  private var reported = false

  func setAbort(_ flag: Int32) {
    openIfNeeded()
    lock.lock()
    let abort = abortFn
    lock.unlock()
    abort?(flag)
  }

  func ensureLoaded(model: Preference.LiveCaptionModel) -> Bool {
    openIfNeeded()
    guard loadFn != nil else {
      LiveCaptionController.shared.setStatus("libiina_whisper.dylib is not in the app. other/download_libs.sh builds it. Model weights are separate.")
      return false
    }
    let path = LiveCaptionStore.file(for: model).path
    if path == loadedPath { return true }
    let rc = path.withCString { loadFn!($0, 1) }
    if rc != 0 {
      let message = lastError()
      LiveCaptionController.shared.setStatus("Could not load the Whisper model (\(message)).")
      loadedPath = ""
      return false
    }
    loadedPath = path
    if !reported {
      reported = true
      let backend = cString(backendFn)
      let info = cString(infoFn)
      Logger.log("Live captions backend \(backend). \(info)", level: .warning)
      LiveCaptionController.shared.setStatus("Whisper is loaded (\(backend)). Speech stays on this Mac. A caption still lags by a few seconds, and Small costs more CPU and GPU than Base.")
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
    guard rc == 0, let out else {
      if rc == 4 { return nil }
      let message = lastError()
      LiveCaptionController.shared.setStatus("Speech recognition failed (\(message)).")
      return nil
    }
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
    guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("libiina_whisper.dylib"),
          FileManager.default.fileExists(atPath: url.path) else {
      lock.unlock()
      return
    }
    guard let opened = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
      lock.unlock()
      let reason: String
      if let err = dlerror() {
        reason = String(cString: err)
      } else {
        reason = "dlopen failed"
      }
      LiveCaptionController.shared.setStatus("Could not open the Whisper library. \(reason)")
      return
    }
    handle = opened
    loadFn = function("iina_whisper_load")
    transcribeFn = function("iina_whisper_transcribe")
    freeFn = function("iina_whisper_free_text")
    abortFn = function("iina_whisper_set_abort")
    errorFn = function("iina_whisper_last_error")
    backendFn = function("iina_whisper_backend")
    infoFn = function("iina_whisper_system_info")
    lock.unlock()
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

  func slice(from start: Double, to end: Double) -> [Float]? {
    lock.lock()
    defer { lock.unlock() }
    guard aligned, end > start else { return nil }
    let have = origin + Double(samples.count) / rate
    if end > have + 0.08 || start + 0.05 < origin { return nil }
    let a = max(0, Int((start - origin) * rate))
    let b = min(samples.count, Int((end - origin) * rate))
    guard b - a >= 8000 else { return nil }
    return Array(samples[a..<b])
  }

  func latest(seconds: Double) -> [Float]? {
    lock.lock()
    defer { lock.unlock() }
    let need = Int(rate * seconds)
    guard samples.count >= max(8000, need / 2) else { return nil }
    let count = min(samples.count, need)
    return Array(samples.suffix(count))
  }
}

final class CaptionSource {
  let pcm = CaptionPCM()
  private let queue = DispatchQueue(label: "com.colliderli.iina.live-caption-audio", qos: .userInitiated)
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  private var asset: AVURLAsset?
  private var track: AVAssetTrack?
  private var tap: MutedAudioTap?
  private var mode: Mode = .closed
  private var closed = true
  private var retargeting = false

  private enum Mode {
    case closed
    case reader
    case tap
  }

  func open(url: URL, userAgent: String?, at time: Double) {
    queue.async {
      self.closeOnQueue()
      self.closed = false
      var options: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: false]
      if let userAgent, !userAgent.isEmpty, !url.isFileURL {
        options["AVURLAssetHTTPHeaderFieldsKey"] = ["User-Agent": userAgent]
      }
      let asset = AVURLAsset(url: url, options: options)
      self.asset = asset
      asset.loadValuesAsynchronously(forKeys: ["tracks", "playable", "duration"]) {
        self.queue.async {
          guard !self.closed else { return }
          self.finishOpen(asset: asset, url: url, userAgent: userAgent, at: time)
        }
      }
    }
  }

  func close() {
    queue.async {
      self.closeOnQueue()
    }
  }

  func follow(time: Double, window: Double) {
    queue.async {
      guard !self.closed else { return }
      if self.mode == .reader {
        let covered = self.pcm.coveredUntil()
        if time + 1 < self.pcm.startTime || time > covered + max(6, window) {
          self.restartReader(at: max(0, time - 0.4))
        }
        self.pump(target: time)
      }
    }
  }

  func samples(endingAt time: Double, window: Double) -> [Float]? {
    var result: [Float]?
    queue.sync {
      if self.mode == .tap || !self.pcm.aligned {
        result = self.pcm.latest(seconds: window)
      } else {
        result = self.pcm.slice(from: max(0, time - window), to: time)
      }
    }
    return result
  }

  private func finishOpen(asset: AVURLAsset, url: URL, userAgent: String?, at time: Double) {
    var error: NSError?
    let status = asset.statusOfValue(forKey: "tracks", error: &error)
    guard status == .loaded else {
      LiveCaptionController.shared.setStatus("Could not read an audio track from this item.")
      return
    }
    let tracks = asset.tracks(withMediaType: .audio)
    guard let track = tracks.first else {
      LiveCaptionController.shared.setStatus("This item has no audio track, so there is nothing to caption.")
      return
    }
    self.track = track
    let duration = asset.duration.seconds
    let seekable = url.isFileURL || (duration.isFinite && duration > 1)
    if seekable && startReader(asset: asset, track: track, at: max(0, time - 0.4)) {
      mode = .reader
      Logger.log("Live captions are decoding the same media again, aligned to the player clock.", level: .warning)
      return
    }
    mode = .tap
    pcm.reset(at: 0, aligned: false)
    DispatchQueue.main.async {
      guard !self.closed else { return }
      let player = MutedAudioTap(pcm: self.pcm)
      self.tap = player
      player.start(url: url, userAgent: userAgent)
    }
    Logger.log("Live captions opened a second read because this item could not be seeked.", level: .warning)
    LiveCaptionController.shared.setStatus("Live source: captions come from a second read of the stream, so they can sit a few seconds off the picture.")
  }

  private func startReader(asset: AVAsset, track: AVAssetTrack, at start: Double) -> Bool {
    reader?.cancelReading()
    reader = nil
    output = nil
    guard let reader = try? AVAssetReader(asset: asset) else { return false }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
      AVSampleRateKey: 16000,
      AVNumberOfChannelsKey: 1
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = true
    guard reader.canAdd(output) else { return false }
    reader.add(output)
    let startTime = CMTime(seconds: max(0, start), preferredTimescale: 16000)
    reader.timeRange = CMTimeRange(start: startTime, duration: CMTime.positiveInfinity)
    guard reader.startReading() else { return false }
    self.reader = reader
    self.output = output
    pcm.reset(at: max(0, start), aligned: true)
    return true
  }

  private func restartReader(at time: Double) {
    guard !retargeting, let asset, let track else { return }
    retargeting = true
    if startReader(asset: asset, track: track, at: time) {
      mode = .reader
    }
    retargeting = false
  }

  private func pump(target: Double) {
    guard mode == .reader, let output, let reader, reader.status == .reading else { return }
    var pulls = 0
    var exhausted = false
    while pulls < 24 && !exhausted && pcm.coveredUntil() < target + 0.15 {
      autoreleasepool {
        guard let sample = output.copyNextSampleBuffer() else {
          exhausted = true
          return
        }
        pulls += 1
        self.append(sample)
      }
    }
  }

  private func append(_ sample: CMSampleBuffer) {
    let count = CMSampleBufferGetNumSamples(sample)
    guard count > 0, let block = CMSampleBufferGetDataBuffer(sample) else { return }
    var length = 0
    var pointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
    guard status == noErr, let pointer else { return }
    let bytes = count * MemoryLayout<Float>.size
    guard length >= bytes else { return }
    var floats = [Float](repeating: 0, count: count)
    floats.withUnsafeMutableBytes { dest in
      memcpy(dest.baseAddress, pointer, bytes)
    }
    var pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
    if !pts.isFinite {
      pts = pcm.coveredUntil()
    }
    pcm.append(floats, at: pts)
  }

  private func closeOnQueue() {
    closed = true
    mode = .closed
    reader?.cancelReading()
    reader = nil
    output = nil
    asset = nil
    track = nil
    let player = tap
    tap = nil
    pcm.reset(at: 0, aligned: true)
    if let player {
      DispatchQueue.main.async {
        player.stop()
      }
    }
  }
}

final class MutedAudioTap: NSObject {
  let pcm: CaptionPCM
  private let player = AVPlayer()
  private var item: AVPlayerItem?
  private var started = false
  private var stopped = false
  private var format = AudioStreamBasicDescription()
  private var mpvAtStart = 0.0
  private var skewSet = false
  private var runningPTS = 0.0

  init(pcm: CaptionPCM) {
    self.pcm = pcm
    super.init()
  }

  func start(url: URL, userAgent: String?) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.start(url: url, userAgent: userAgent) }
      return
    }
    var options: [String: Any] = [:]
    if let userAgent, !userAgent.isEmpty, !url.isFileURL {
      options["AVURLAssetHTTPHeaderFieldsKey"] = ["User-Agent": userAgent]
    }
    let asset = AVURLAsset(url: url, options: options)
    let item = AVPlayerItem(asset: asset)
    self.item = item
    item.addObserver(self, forKeyPath: "status", options: [.initial, .new], context: nil)
    player.volume = 0
    player.isMuted = true
    if !PlayerCore.playerCores.isEmpty, PlayerCore.active.mpv != nil {
      let time = PlayerCore.active.mpv.getDouble(MPVProperty.timePos)
      if time.isFinite { mpvAtStart = time }
    }
    player.replaceCurrentItem(with: item)
    player.play()
  }

  func stop() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.stop() }
      return
    }
    stopped = true
    if let item {
      item.removeObserver(self, forKeyPath: "status", context: nil)
    }
    player.pause()
    player.replaceCurrentItem(with: nil)
    self.item = nil
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    guard keyPath == "status", !stopped, !started, let item, item.status == .readyToPlay else { return }
    if Thread.isMainThread {
      installTap(on: item)
    } else {
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.stopped, !self.started else { return }
        self.installTap(on: item)
      }
    }
  }

  private func installTap(on item: AVPlayerItem) {
    guard let track = item.asset.tracks(withMediaType: .audio).first else { return }
    var callbacks = MTAudioProcessingTapCallbacks()
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0
    callbacks.clientInfo = Unmanaged.passUnretained(self).toOpaque()
    callbacks.`init` = captionTapInit
    callbacks.prepare = captionTapPrepare
    callbacks.process = captionTapProcess
    var tap: MTAudioProcessingTap?
    var callbackCopy = callbacks
    let status = withUnsafePointer(to: &callbackCopy) { pointer in
      MTAudioProcessingTapCreate(kCFAllocatorDefault, pointer, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
    }
    guard status == noErr, let tap else { return }
    let params = AVMutableAudioMixInputParameters(track: track)
    params.audioTapProcessor = tap
    let mix = AVMutableAudioMix()
    mix.inputParameters = [params]
    item.audioMix = mix
    for entry in item.tracks where entry.assetTrack?.mediaType == .video {
      entry.isEnabled = false
    }
    started = true
  }

  fileprivate func prepare(_ format: AudioStreamBasicDescription) {
    self.format = format
  }

  fileprivate func process(frames: CMItemCount, list: UnsafeMutablePointer<AudioBufferList>, time: CMTime) {
    if stopped || frames <= 0 { return }
    let mono = monoSamples(frames: Int(frames), list: list)
    guard !mono.isEmpty else { return }
    let rate = format.mSampleRate > 0 ? format.mSampleRate : 48000
    let resampled = resample(mono, from: rate, to: 16000)
    var pts = time.seconds
    if !pts.isFinite {
      pts = runningPTS
      runningPTS += Double(mono.count) / rate
    }
    if !skewSet {
      skewSet = true
      pcm.reset(at: mpvAtStart, aligned: false)
      pcm.append(resampled, at: mpvAtStart)
      return
    }
    pcm.append(resampled, at: pts)
  }

  private func monoSamples(frames: Int, list: UnsafeMutablePointer<AudioBufferList>) -> [Float] {
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    let channels = max(1, Int(format.mChannelsPerFrame))
    let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    if nonInterleaved {
      var mixed = [Float](repeating: 0, count: frames)
      var used = 0
      for buffer in buffers {
        let channel = convert(buffer, frames: frames, channels: 1, isFloat: isFloat)
        guard channel.count >= frames else { continue }
        for index in 0..<frames {
          mixed[index] += channel[index]
        }
        used += 1
      }
      guard used > 0 else { return [] }
      if used > 1 {
        for index in 0..<frames {
          mixed[index] /= Float(used)
        }
      }
      return mixed
    }
    guard let buffer = buffers.first else { return [] }
    return convert(buffer, frames: frames, channels: channels, isFloat: isFloat)
  }

  private func convert(_ buffer: AudioBuffer, frames: Int, channels: Int, isFloat: Bool) -> [Float] {
    guard let data = buffer.mData, frames > 0, channels > 0 else { return [] }
    if isFloat && format.mBitsPerChannel == 32 {
      let count = frames * channels
      guard buffer.mDataByteSize >= UInt32(count * MemoryLayout<Float>.size) else { return [] }
      var raw = [Float](repeating: 0, count: count)
      raw.withUnsafeMutableBytes { dest in
        memcpy(dest.baseAddress, data, count * MemoryLayout<Float>.size)
      }
      if channels == 1 { return raw }
      var mono = [Float](repeating: 0, count: frames)
      for index in 0..<frames {
        var sum: Float = 0
        for channel in 0..<channels {
          sum += raw[index * channels + channel]
        }
        mono[index] = sum / Float(channels)
      }
      return mono
    }
    if !isFloat && format.mBitsPerChannel == 16 {
      let count = frames * channels
      guard buffer.mDataByteSize >= UInt32(count * MemoryLayout<Int16>.size) else { return [] }
      var raw = [Int16](repeating: 0, count: count)
      raw.withUnsafeMutableBytes { dest in
        memcpy(dest.baseAddress, data, count * MemoryLayout<Int16>.size)
      }
      var mono = [Float](repeating: 0, count: frames)
      let scale = Float(1.0 / 32768.0)
      for index in 0..<frames {
        var sum: Float = 0
        for channel in 0..<channels {
          sum += Float(raw[index * channels + channel]) * scale
        }
        mono[index] = sum / Float(channels)
      }
      return mono
    }
    return []
  }

  private func resample(_ input: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
    guard inputRate > 0, !input.isEmpty else { return [] }
    if abs(inputRate - outputRate) < 1 { return input }
    let ratio = inputRate / outputRate
    let count = Int(Double(input.count) / ratio)
    guard count > 1 else { return input }
    var output = [Float](repeating: 0, count: count)
    let last = input.count - 1
    for index in 0..<count {
      let position = Double(index) * ratio
      let left = min(last, Int(position))
      let right = min(last, left + 1)
      let fraction = Float(position - Double(left))
      output[index] = input[left] * (1 - fraction) + input[right] * fraction
    }
    return output
  }
}

private func captionTapInit(
  tap: MTAudioProcessingTap,
  clientInfo: UnsafeMutableRawPointer?,
  tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
  tapStorageOut.pointee = clientInfo
}

private func captionTapPrepare(
  tap: MTAudioProcessingTap,
  maxFrames: CMItemCount,
  processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
  let me = Unmanaged<MutedAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
  me.prepare(processingFormat.pointee)
}

private func captionTapProcess(
  tap: MTAudioProcessingTap,
  numberFrames: CMItemCount,
  flags: MTAudioProcessingTapFlags,
  bufferList: UnsafeMutablePointer<AudioBufferList>,
  numberFramesOut: UnsafeMutablePointer<CMItemCount>,
  flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
  var timeRange = CMTimeRange()
  let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut, &timeRange, numberFramesOut)
  guard status == noErr else {
    numberFramesOut.pointee = 0
    return
  }
  let me = Unmanaged<MutedAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
  me.process(frames: numberFramesOut.pointee, list: bufferList, time: timeRange.start)
}

final class LiveCaptionSettingsView: NSView {
  private let status = NSTextField(wrappingLabelWithString: "")
  private var sourcePopup: NSPopUpButton!
  private var targetPopup: NSPopUpButton!
  private let keyField = NSSecureTextField()
  private var keyDirty = false

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
    refreshStatus()

    let note = NSTextField(wrappingLabelWithString: "The player decodes the same URL a second time. libmpv does not provide its PCM, and a lavfi graph cannot export it without replacing playback. Expect a few seconds of delay. Base is lighter; Small uses more CPU and GPU on an M2. Whisper translates into English only. Other languages use the macOS 15 system translator when that language is installed, or the API key (caption text only). On macOS 13 without a key, the line stays in the recognized language. Place ggml-base-encoder.mlmodelc or ggml-small-encoder.mlmodelc next to the ggml file to use the Core ML encoder; otherwise Metal or the CPU runs the model. This was not timed on a Mac.")
    note.preferredMaxLayoutWidth = 400
    note.textColor = .secondaryLabelColor
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    stack.addArrangedSubview(labeled("Source language", sourcePopup))
    stack.addArrangedSubview(labeled("Target language", targetPopup))
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
  }
}
