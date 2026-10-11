//
//  IPTVLibrary.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Loads M3U playlists and Xtream Codes player_api.php catalogs.
//  Xtream passwords are stored in the Keychain under "IINA IPTV Account".
//  Built stream URLs contain that password because Xtream requires it in the path;
//  playback history is given an iptv:// stand-in instead of the real URL.

import Cocoa

final class IPTVLibrary {
  static let shared = IPTVLibrary()

  private(set) var sources: [IPTVSource] = []
  private var favourites: Set<String> = []
  private let standInLock = NSLock()
  /// Keys are the stream URL and a scheme/host/port/path/query form of it.
  /// The history URL is `iptv://<source-uuid>/<item-id>` and does not contain the password.
  private var standIns: [String: PlaybackAlias] = [:]
  /// The stream most recently handed to the player. fileStarted rebuilds that URL, so this is the fallback when the strings differ.
  private var latestStream: URL?
  private var latestAlias: PlaybackAlias?
  private var progress: [String: IPTVWatchRecord] = [:]
  private var activeWatch: ActiveWatch?
  private var pendingResume: Double?
  private var lastProgressWrite = Date.distantPast
  private let session: URLSession

  private struct ActiveWatch {
    var key: String
    var record: IPTVWatchRecord
  }

  private struct PlaybackAlias: Equatable {
    var historyURL: URL
    var title: String
  }

  private init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 180
    config.httpAdditionalHeaders = ["User-Agent": "IINA IPTV"]
    session = URLSession(configuration: config)
    loadLibrary()
    loadProgress()
  }

  // MARK: - Persistence

  private var directory: URL {
    let url = Utility.appSupportDirUrl.appendingPathComponent("IPTV", isDirectory: true)
    Utility.createDirIfNotExist(url: url)
    return url
  }

  private var libraryURL: URL {
    directory.appendingPathComponent("library.json")
  }

  private var progressURL: URL {
    directory.appendingPathComponent("progress.json")
  }

  private func detailsDirectory() -> URL {
    let url = directory.appendingPathComponent("Details", isDirectory: true)
    Utility.createDirIfNotExist(url: url)
    return url
  }

  private func cacheURL(for id: UUID) -> URL {
    directory.appendingPathComponent("cache-\(id.uuidString).json")
  }

  private func loadLibrary() {
    guard let data = try? Data(contentsOf: libraryURL),
          let file = try? JSONDecoder().decode(IPTVLibraryFile.self, from: data) else { return }
    sources = file.sources
    favourites = Set(file.favourites)
  }

  func saveLibrary() {
    let file = IPTVLibraryFile(sources: sources, favourites: Array(favourites).sorted())
    guard let data = try? JSONEncoder().encode(file) else { return }
    try? data.write(to: libraryURL, options: .atomic)
  }

  func cache(for source: IPTVSource) -> IPTVCatalog? {
    guard let data = try? Data(contentsOf: cacheURL(for: source.id)) else { return nil }
    return try? JSONDecoder().decode(IPTVCatalog.self, from: data)
  }

  func store(cache: IPTVCatalog, for source: IPTVSource) {
    // The generated xmltv.php URL embeds the password. Keep that in memory for the
    // request only; the cache stores the user's own EPG override, or nothing.
    var sanitized = cache
    if source.kind == .xtream && source.epgURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sanitized.epgURL = nil
    }
    guard let data = try? JSONEncoder().encode(sanitized) else { return }
    try? data.write(to: cacheURL(for: source.id), options: .atomic)
  }

  /// Guide address for a fetch. Rebuilds Xtream's xmltv.php from the Keychain so the password is not read back out of the cache.
  func guideURL(for source: IPTVSource, catalog: IPTVCatalog?) -> String? {
    let override = source.epgURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !override.isEmpty { return override }
    if let epg = catalog?.epgURL?.trimmingCharacters(in: .whitespacesAndNewlines), !epg.isEmpty {
      return epg
    }
    guard source.kind == .xtream, let password = password(for: source), !password.isEmpty else { return nil }
    return IPTVXtream.xmltvURL(
      base: IPTVXtream.normalizeServer(source.server),
      username: source.username,
      password: password
    )?.absoluteString
  }

  func upsert(_ source: IPTVSource, password: String?) throws {
    if let index = sources.firstIndex(where: { $0.id == source.id }) {
      sources[index] = source
    } else {
      sources.append(source)
    }
    if let password, !password.isEmpty {
      do {
        try KeychainAccess.write(username: source.id.uuidString, password: password, forService: .iptvAccount)
      } catch {
        throw IPTVError.keychain(error.localizedDescription)
      }
    }
    saveLibrary()
  }

  func delete(_ source: IPTVSource) {
    sources.removeAll { $0.id == source.id }
    favourites = favourites.filter { !$0.hasPrefix(source.id.uuidString + "|") }
    progress = progress.filter { !$0.key.hasPrefix(source.id.uuidString + "|") }
    saveProgress()
    try? KeychainAccess.delete(username: source.id.uuidString, forService: .iptvAccount)
    try? FileManager.default.removeItem(at: cacheURL(for: source.id))
    removeDetailCaches(for: source.id)
    saveLibrary()
  }

  func password(for source: IPTVSource) -> String? {
    guard source.kind == .xtream else { return nil }
    return try? KeychainAccess.read(username: source.id.uuidString, forService: .iptvAccount).password
  }

  func isFavourite(_ item: IPTVItem, source: IPTVSource) -> Bool {
    favourites.contains(favouriteKey(item, source: source))
  }

  func toggleFavourite(_ item: IPTVItem, source: IPTVSource) {
    let key = favouriteKey(item, source: source)
    if favourites.contains(key) {
      favourites.remove(key)
    } else {
      favourites.insert(key)
    }
    saveLibrary()
  }

  private func favouriteKey(_ item: IPTVItem, source: IPTVSource) -> String {
    source.id.uuidString + "|" + item.id
  }

  // MARK: - Playback URL

  func playbackURL(for item: IPTVItem, source: IPTVSource) -> URL? {
    if let absolute = item.absoluteURL, let url = URL(string: absolute), url.scheme != nil {
      return url
    }
    guard source.kind == .xtream,
          let route = item.route,
          let streamID = item.streamID,
          let password = password(for: source) else { return nil }
    let base = IPTVXtream.normalizeServer(source.server)
    let user = IPTVXtream.pathEscape(source.username)
    let pass = IPTVXtream.pathEscape(password)
    let id = IPTVXtream.pathEscape(streamID)
    let ext = IPTVXtream.pathEscape(item.fileExtension ?? (route == "live" ? "m3u8" : "mp4"))
    return URL(string: "\(base)/\(route)/\(user)/\(pass)/\(id).\(ext)")
  }

  /// Timeshift URL for one programme, from the start. Nil when this channel has no archive or the address cannot be built.
  /// The Xtream password is read from the Keychain here and is not written into the catalog.
  func catchupURL(for item: IPTVItem, source: IPTVSource, programme: IPTVProgramme, now: Date = Date()) -> URL? {
    guard let catchup = item.catchup, item.hasArchive else { return nil }
    if catchup.mode == "xtream" {
      guard let streamID = item.streamID, let password = password(for: source), !password.isEmpty else { return nil }
      return IPTVCatchup.xtreamArchiveURL(
        base: IPTVXtream.normalizeServer(source.server),
        username: source.username,
        password: password,
        streamID: streamID,
        programme: programme,
        correctionHours: catchup.correctionHours
      )
    }
    guard let template = catchup.template else { return nil }
    return IPTVCatchup.url(template: template, programme: programme, now: now, correctionHours: catchup.correctionHours)
  }

  /// Remember a title and a password-free history URL for the stream that is about to play.
  /// Movies and episodes also record watch progress. Live and catch-up do not.
  func registerPlayback(stream: URL, source: IPTVSource, item: IPTVItem, title: String? = nil, resumeAt: Double? = nil, seriesItemID: String? = nil, seriesTitle: String? = nil) {
    var components = URLComponents()
    components.scheme = "iptv"
    components.host = source.id.uuidString
    components.path = "/" + item.id
    guard let standIn = components.url else { return }
    let alias = PlaybackAlias(historyURL: standIn, title: title ?? item.name)
    if item.kind == .vod || item.kind == .episode {
      activeWatch = ActiveWatch(
        key: progressKey(source: source, itemID: item.id),
        record: IPTVWatchRecord(
          position: resumeAt ?? 0,
          duration: progress[progressKey(source: source, itemID: item.id)]?.duration ?? 0,
          updated: Date(),
          title: title ?? item.name,
          kind: item.kind.rawValue,
          group: item.group,
          logoURL: item.logoURL,
          route: item.route,
          streamID: item.streamID,
          fileExtension: item.fileExtension,
          absoluteURL: item.absoluteURL,
          seriesItemID: seriesItemID,
          seriesTitle: seriesTitle
        )
      )
      pendingResume = (resumeAt ?? 0) >= IPTVWatch.minimumResume ? resumeAt : nil
    } else {
      activeWatch = nil
      pendingResume = nil
    }
    standInLock.lock()
    for key in Self.aliasKeys(stream) {
      standIns[key] = alias
    }
    standIns[stream.absoluteString] = alias
    latestStream = stream
    latestAlias = alias
    standInLock.unlock()
  }

  func historyStandIn(for url: URL?) -> (url: URL, title: String)? {
    guard let url else { return nil }
    standInLock.lock()
    defer { standInLock.unlock() }
    for key in Self.aliasKeys(url) {
      if let alias = standIns[key] { return (alias.historyURL, alias.title) }
    }
    if let found = standIns[url.absoluteString] { return (found.historyURL, found.title) }
    if let latestStream, let latestAlias, Self.sameStream(latestStream, url) {
      return (latestAlias.historyURL, latestAlias.title)
    }
    return nil
  }

  /// Match a log line or an mpv path that may not be the same string `URL.absoluteString` produced.
  func historyStandIn(matching raw: String) -> (url: URL, title: String)? {
    standInLock.lock()
    if let alias = standIns[raw] {
      standInLock.unlock()
      return (alias.historyURL, alias.title)
    }
    standInLock.unlock()
    if let url = URL(string: raw), let hit = historyStandIn(for: url) { return hit }
    return nil
  }

  /// Channel title when this string is a stream URL we just started; otherwise the string itself.
  func redactedForLog(_ raw: String) -> String {
    let title = historyStandIn(matching: raw)?.title ?? ""
    return title.isEmpty ? raw : title
  }

  func consumeHistoryStandIn(for url: URL?) {
    guard let url else { return }
    standInLock.lock()
    let keys = Self.aliasKeys(url)
    let alias = keys.compactMap { standIns[$0] }.first ?? standIns[url.absoluteString]
    if let alias {
      standIns = standIns.filter { $0.value != alias }
      if latestAlias == alias {
        latestAlias = nil
        latestStream = nil
      }
    }
    standInLock.unlock()
  }

  /// fileStarted rebuilds the URL with percent-encoding, so the absolute string may differ from the one passed to loadfile.
  private static func aliasKeys(_ url: URL) -> [String] {
    let port = url.port.map(String.init) ?? ""
    let normalized = "\(url.scheme ?? "")|\(url.host?.lowercased() ?? "")|\(port)|\(url.path)|\(url.query ?? "")"
    return [url.absoluteString, normalized]
  }

  private static func sameStream(_ registered: URL, _ other: URL) -> Bool {
    if registered.absoluteString == other.absoluteString { return true }
    return registered.scheme == other.scheme
      && registered.host?.lowercased() == other.host?.lowercased()
      && registered.path == other.path
      && registered.port == other.port
      && registered.query == other.query
  }

  // MARK: - Load

  func loadCatalog(for source: IPTVSource, completion: @escaping (Result<IPTVCatalog, Error>) -> Void) {
    switch source.kind {
    case .m3u:
      loadM3U(source, completion: completion)
    case .xtream:
      guard let password = password(for: source), !password.isEmpty else {
        completion(.failure(IPTVError.message("This Xtream login has no password in the Keychain. Edit the source and enter it again.")))
        return
      }
      IPTVXtream.loadCatalog(source: source, password: password, session: session, completion: completion)
    }
  }

  func loadEpisodes(series: IPTVItem, source: IPTVSource, completion: @escaping (Result<[IPTVItem], Error>) -> Void) {
    guard let password = password(for: source), let seriesID = series.streamID else {
      completion(.failure(IPTVError.message("This series has no id.")))
      return
    }
    IPTVXtream.loadEpisodes(series: series, seriesID: seriesID, source: source, password: password, session: session, completion: completion)
  }

  /// Provider details, then TMDB only for fields the provider left empty. A fresh cache is returned immediately.
  func loadTitleDetails(for item: IPTVItem, source: IPTVSource, completion: @escaping (Result<(IPTVTitleDetails, String?), Error>) -> Void) {
    if item.kind == .episode {
      completion(.success((IPTVTitleParser.details(from: item), nil)))
      return
    }
    let key = Preference.string(for: .iptvTMDBAPIKey) ?? ""
    let fingerprint = IPTVTitleParser.fingerprint(for: key)
    if let cached = detailCache(for: item, source: source),
       cached.tmdbFingerprint == fingerprint,
       Date().timeIntervalSince(cached.fetchedAt) < 12 * 60 * 60 {
      completion(.success((cached.details, nil)))
      return
    }
    if let cached = detailCache(for: item, source: source) {
      completion(.success((cached.details, nil)))
    }
    guard let password = password(for: source), !password.isEmpty else {
      if detailCache(for: item, source: source) == nil {
        completion(.failure(IPTVError.message("This Xtream login has no password in the Keychain. Edit the source and enter it again.")))
      }
      return
    }
    let hadCache = detailCache(for: item, source: source) != nil
    IPTVXtream.loadTitle(item: item, source: source, password: password, session: session) { [weak self] result in
      switch result {
      case .failure(let error):
        if !hadCache { completion(.failure(error)) }
      case .success(let details):
        IPTVTMDB.enrich(details, kind: item.kind, apiKey: key, session: self?.session ?? URLSession.shared) { enriched in
          self?.storeDetail(IPTVTitleCacheEntry(fetchedAt: Date(), tmdbFingerprint: fingerprint, details: enriched.details), item: item, source: source)
          completion(.success((enriched.details, enriched.note)))
        }
      }
    }
  }

  func watchProgress(for itemID: String, source: IPTVSource) -> IPTVWatchRecord? {
    progress[progressKey(source: source, itemID: itemID)]
  }

  func continueWatching(source: IPTVSource, kind: IPTVItemKind) -> [IPTVItem] {
    let prefix = source.id.uuidString + "|"
    return progress
      .filter { $0.key.hasPrefix(prefix) && $0.value.kind == kind.rawValue && IPTVWatch.resumeSeconds($0.value) != nil }
      .sorted { $0.value.updated > $1.value.updated }
      .map { entry in
        let itemID = String(entry.key.dropFirst(prefix.count))
        let record = entry.value
        return IPTVItem(
          id: itemID,
          name: record.title,
          group: record.group,
          logoURL: record.logoURL,
          epgID: nil,
          kind: kind,
          absoluteURL: record.absoluteURL,
          route: record.route,
          streamID: record.streamID,
          fileExtension: record.fileExtension
        )
      }
  }

  func seriesIdentity(for itemID: String, source: IPTVSource) -> (id: String, title: String)? {
    guard let record = progress[progressKey(source: source, itemID: itemID)], let seriesID = record.seriesItemID else { return nil }
    return (seriesID, record.seriesTitle ?? record.title)
  }

  func forgetProgress(itemID: String, source: IPTVSource) {
    progress.removeValue(forKey: progressKey(source: source, itemID: itemID))
    saveProgress()
    NotificationCenter.default.post(name: .iptvWatchProgressDidChange, object: nil)
  }

  /// Called from the player while a movie or episode is open. Live streams are ignored.
  func notePlayback(position: Double?, duration: Double?) {
    guard var active = activeWatch, let position, position.isFinite, position >= 5 else { return }
    active.record.position = position
    if let duration, duration.isFinite, duration > 0 {
      active.record.duration = duration
    }
    active.record.updated = Date()
    activeWatch = active
    progress[active.key] = active.record
    let due = Date().timeIntervalSince(lastProgressWrite) >= 5
    if due {
      lastProgressWrite = Date()
      saveProgress()
      NotificationCenter.default.post(name: .iptvWatchProgressDidChange, object: nil)
    }
  }

  func playbackEnded(position: Double?, duration: Double?) {
    guard var active = activeWatch else { return }
    if let position, position.isFinite, position >= 5 {
      active.record.position = position
      if let duration, duration.isFinite, duration > 0 { active.record.duration = duration }
      active.record.updated = Date()
      progress[active.key] = active.record
      saveProgress()
      NotificationCenter.default.post(name: .iptvWatchProgressDidChange, object: nil)
    }
    activeWatch = nil
    pendingResume = nil
  }

  func takeResume(for url: URL?) -> Double? {
    guard let pendingResume, pendingResume >= IPTVWatch.minimumResume else { return nil }
    guard let url, historyStandIn(for: url) != nil, activeWatch != nil else { return nil }
    self.pendingResume = nil
    return pendingResume
  }

  func loadEPG(url: URL, completion: @escaping (Result<IPTVEPG, Error>) -> Void) {
    session.dataTask(with: url) { data, response, error in
      if let error {
        completion(.failure(error))
        return
      }
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        completion(.failure(IPTVError.http(http.statusCode)))
        return
      }
      guard let data else {
        completion(.failure(IPTVError.message("The programme guide was empty.")))
        return
      }
      let epg = IPTVXMLTVParser().parse(data)
      completion(.success(epg))
    }.resume()
  }

  private func loadM3U(_ source: IPTVSource, completion: @escaping (Result<IPTVCatalog, Error>) -> Void) {
    let finish: (String, URL?) -> Void = { text, base in
      let parsed = IPTVPlaylistParser.parse(text, base: base)
      let epg = source.epgURL.trimmingCharacters(in: .whitespaces).isEmpty ? parsed.epgURL : source.epgURL
      completion(.success(IPTVCatalog(epgURL: epg, items: parsed.items)))
    }
    if FileManager.default.fileExists(atPath: source.location) {
      let url = URL(fileURLWithPath: source.location)
      DispatchQueue.global(qos: .userInitiated).async {
        guard let text = Self.readText(url) else {
          DispatchQueue.main.async {
            completion(.failure(IPTVError.message("Could not read \(source.location).")))
          }
          return
        }
        DispatchQueue.main.async {
          finish(text, url)
        }
      }
      return
    }
    guard let url = URL(string: source.location), url.scheme != nil else {
      completion(.failure(IPTVError.badURL(source.location)))
      return
    }
    session.dataTask(with: url) { data, response, error in
      if let error {
        DispatchQueue.main.async { completion(.failure(error)) }
        return
      }
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        DispatchQueue.main.async { completion(.failure(IPTVError.http(http.statusCode))) }
        return
      }
      guard let data, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
        DispatchQueue.main.async { completion(.failure(IPTVError.message("The playlist was not text."))) }
        return
      }
      DispatchQueue.main.async {
        finish(text, url)
      }
    }.resume()
  }

  private static func readText(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
  }

  private func progressKey(source: IPTVSource, itemID: String) -> String {
    source.id.uuidString + "|" + itemID
  }

  private func loadProgress() {
    guard let data = try? Data(contentsOf: progressURL) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    progress = (try? decoder.decode([String: IPTVWatchRecord].self, from: data)) ?? [:]
  }

  private func saveProgress() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    guard let data = try? encoder.encode(progress) else { return }
    try? data.write(to: progressURL, options: .atomic)
  }

  private func detailFile(for item: IPTVItem, source: IPTVSource) -> URL {
    let name = source.id.uuidString + "-" + item.id.replacingOccurrences(of: "/", with: "_")
    return detailsDirectory().appendingPathComponent(name + ".json")
  }

  private func detailCache(for item: IPTVItem, source: IPTVSource) -> IPTVTitleCacheEntry? {
    guard let data = try? Data(contentsOf: detailFile(for: item, source: source)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try? decoder.decode(IPTVTitleCacheEntry.self, from: data)
  }

  private func storeDetail(_ entry: IPTVTitleCacheEntry, item: IPTVItem, source: IPTVSource) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    guard let data = try? encoder.encode(entry) else { return }
    try? data.write(to: detailFile(for: item, source: source), options: .atomic)
  }

  private func removeDetailCaches(for sourceID: UUID) {
    let folder = detailsDirectory()
    let prefix = sourceID.uuidString + "-"
    guard let names = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
    for url in names where url.lastPathComponent.hasPrefix(prefix) {
      try? FileManager.default.removeItem(at: url)
    }
  }
}

enum IPTVXtream {
  static func normalizeServer(_ raw: String) -> String {
    var server = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while server.hasSuffix("/") { server.removeLast() }
    if !server.contains("://") { server = "http://" + server }
    let suffix = "/player_api.php"
    if server.lowercased().hasSuffix(suffix) {
      server = String(server.dropLast(suffix.count))
    }
    return server
  }

  static func pathEscape(_ raw: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
  }

  static func loadCatalog(source: IPTVSource, password: String, session: URLSession, completion: @escaping (Result<IPTVCatalog, Error>) -> Void) {
    let base = normalizeServer(source.server)
    request(base: base, username: source.username, password: password, action: nil, session: session) { result in
      switch result {
      case .failure(let error):
        DispatchQueue.main.async { completion(.failure(error)) }
      case .success(let auth):
        if let info = auth as? [String: Any], let user = info["user_info"] as? [String: Any], !isAuthorized(user) {
          let message = jsonString(user["message"])
          DispatchQueue.main.async { completion(.failure(IPTVError.unauthorized(message))) }
          return
        }
        let group = DispatchGroup()
        var liveCategories: [String: String] = [:]
        var vodCategories: [String: String] = [:]
        var seriesCategories: [String: String] = [:]
        var live: [[String: Any]] = []
        var vod: [[String: Any]] = []
        var series: [[String: Any]] = []
        var failure: Error?
        let lock = NSLock()
        func run(_ action: String, _ body: @escaping (Any) -> Void) {
          group.enter()
          request(base: base, username: source.username, password: password, action: action, session: session) { result in
            defer { group.leave() }
            switch result {
            case .failure(let error):
              lock.lock()
              failure = failure ?? error
              lock.unlock()
            case .success(let value):
              lock.lock()
              body(value)
              lock.unlock()
            }
          }
        }
        run("get_live_categories") { liveCategories = categories($0) }
        run("get_vod_categories") { vodCategories = categories($0) }
        run("get_series_categories") { seriesCategories = categories($0) }
        run("get_live_streams") { live = objects($0) }
        run("get_vod_streams") { vod = objects($0) }
        run("get_series") { series = objects($0) }
        group.notify(queue: .main) {
          if let failure, live.isEmpty && vod.isEmpty && series.isEmpty {
            completion(.failure(failure))
            return
          }
          var items: [IPTVItem] = []
          items.append(contentsOf: live.map { liveItem($0, categories: liveCategories) })
          items.append(contentsOf: vod.map { vodItem($0, categories: vodCategories) })
          items.append(contentsOf: series.map { seriesItem($0, categories: seriesCategories) })
          let epg = source.epgURL.trimmingCharacters(in: .whitespaces).isEmpty
            ? xmltvURL(base: base, username: source.username, password: password)?.absoluteString
            : source.epgURL
          completion(.success(IPTVCatalog(epgURL: epg, items: items)))
        }
      }
    }
  }

  static func loadEpisodes(series: IPTVItem, seriesID: String, source: IPTVSource, password: String, session: URLSession, completion: @escaping (Result<[IPTVItem], Error>) -> Void) {
    let base = normalizeServer(source.server)
    guard var components = URLComponents(string: base + "/player_api.php") else {
      completion(.failure(IPTVError.badURL(base)))
      return
    }
    components.queryItems = [
      URLQueryItem(name: "username", value: source.username),
      URLQueryItem(name: "password", value: password),
      URLQueryItem(name: "action", value: "get_series_info"),
      URLQueryItem(name: "series_id", value: seriesID)
    ]
    guard let url = components.url else {
      completion(.failure(IPTVError.badURL(base)))
      return
    }
    session.dataTask(with: url) { data, response, error in
      let result = decode(data: data, response: response, error: error)
      DispatchQueue.main.async {
        switch result {
        case .failure(let error):
          completion(.failure(error))
        case .success(let value):
          completion(.success(episodes(from: value, series: series)))
        }
      }
    }.resume()
  }

  static func xmltvURL(base: String, username: String, password: String) -> URL? {
    guard var components = URLComponents(string: base + "/xmltv.php") else { return nil }
    components.queryItems = [
      URLQueryItem(name: "username", value: username),
      URLQueryItem(name: "password", value: password)
    ]
    return components.url
  }

  private static func request(base: String, username: String, password: String, action: String?, session: URLSession, completion: @escaping (Result<Any, Error>) -> Void) {
    guard var components = URLComponents(string: base + "/player_api.php") else {
      completion(.failure(IPTVError.badURL(base)))
      return
    }
    var items = [
      URLQueryItem(name: "username", value: username),
      URLQueryItem(name: "password", value: password)
    ]
    if let action { items.append(URLQueryItem(name: "action", value: action)) }
    components.queryItems = items
    guard let url = components.url else {
      completion(.failure(IPTVError.badURL(base)))
      return
    }
    session.dataTask(with: url) { data, response, error in
      completion(decode(data: data, response: response, error: error))
    }.resume()
  }

  private static func decode(data: Data?, response: URLResponse?, error: Error?) -> Result<Any, Error> {
    if let error { return .failure(error) }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      return .failure(IPTVError.http(http.statusCode))
    }
    guard let data, !data.isEmpty else { return .success([]) }
    do {
      return .success(try JSONSerialization.jsonObject(with: data))
    } catch {
      return .failure(IPTVError.notJSON)
    }
  }

  private static func isAuthorized(_ user: [String: Any]) -> Bool {
    switch user["auth"] {
    case let number as NSNumber: return number.intValue == 1
    case let string as String: return string == "1" || string.lowercased() == "true"
    case nil:
      let status = jsonString(user["status"]).lowercased()
      return status.isEmpty || status == "active"
    default: return false
    }
  }

  private static func categories(_ value: Any) -> [String: String] {
    var map: [String: String] = [:]
    for object in objects(value) {
      let id = jsonString(object["category_id"])
      let name = jsonString(object["category_name"])
      if !id.isEmpty { map[id] = name.isEmpty ? "Ungrouped" : name }
    }
    return map
  }

  private static func objects(_ value: Any) -> [[String: Any]] {
    if let array = value as? [[String: Any]] { return array }
    if let array = value as? [Any] { return array.compactMap { $0 as? [String: Any] } }
    return []
  }

  private static func liveItem(_ object: [String: Any], categories: [String: String]) -> IPTVItem {
    let id = jsonString(object["stream_id"])
    let category = jsonString(object["category_id"])
    let direct = emptyToNil(jsonString(object["direct_source"]))
    return IPTVItem(
      id: "live-\(id)",
      name: display(object["name"], fallback: "Channel \(id)"),
      group: categories[category] ?? "Ungrouped",
      logoURL: emptyToNil(jsonString(object["stream_icon"])),
      epgID: emptyToNil(jsonString(object["epg_channel_id"])),
      kind: .live,
      absoluteURL: direct,
      route: "live",
      streamID: id,
      fileExtension: "m3u8",
      catchup: xtreamArchive(object)
    )
  }

  /// `tv_archive` of 1 (number or string) and a positive `tv_archive_duration` in days.
  /// The timeshift path is built at playback, so the password is not stored on the item.
  private static func xtreamArchive(_ object: [String: Any]) -> IPTVArchive? {
    let flag = jsonString(object["tv_archive"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard flag == "1" || flag == "true" else { return nil }
    guard let days = IPTVCatchup.positiveDays(jsonString(object["tv_archive_duration"])) else { return nil }
    return IPTVArchive(mode: "xtream", days: days, template: nil, correctionHours: 0)
  }

  private static func vodItem(_ object: [String: Any], categories: [String: String]) -> IPTVItem {
    let id = jsonString(object["stream_id"])
    let category = jsonString(object["category_id"])
    let ext = emptyToNil(jsonString(object["container_extension"])) ?? "mp4"
    let meta = IPTVTitleParser.metadata(fromList: object)
    let direct = emptyToNil(jsonString(object["direct_source"]))
    return IPTVItem(
      id: "vod-\(id)",
      name: display(object["name"], fallback: "Title \(id)"),
      group: categories[category] ?? "Ungrouped",
      logoURL: meta.posterURL ?? emptyToNil(jsonString(object["stream_icon"])),
      epgID: nil,
      kind: .vod,
      absoluteURL: direct.flatMap { URL(string: $0)?.scheme == nil ? nil : $0 },
      route: "movie",
      streamID: id,
      fileExtension: ext,
      plot: meta.plot,
      rating: meta.rating,
      releaseDate: meta.releaseDate,
      genre: meta.genre,
      cast: meta.cast,
      director: meta.director,
      tmdbID: meta.tmdbID,
      backdropURL: meta.backdropURL,
      trailerURL: meta.trailerURL,
      durationText: meta.durationText
    )
  }

  private static func seriesItem(_ object: [String: Any], categories: [String: String]) -> IPTVItem {
    let id = jsonString(object["series_id"])
    let category = jsonString(object["category_id"])
    let meta = IPTVTitleParser.metadata(fromList: object)
    return IPTVItem(
      id: "series-\(id)",
      name: display(object["name"], fallback: "Series \(id)"),
      group: categories[category] ?? "Ungrouped",
      logoURL: meta.posterURL ?? emptyToNil(jsonString(object["cover"])),
      epgID: nil,
      kind: .series,
      absoluteURL: nil,
      route: nil,
      streamID: id,
      fileExtension: nil,
      plot: meta.plot,
      rating: meta.rating,
      releaseDate: meta.releaseDate,
      genre: meta.genre,
      cast: meta.cast,
      director: meta.director,
      tmdbID: meta.tmdbID,
      backdropURL: meta.backdropURL,
      trailerURL: meta.trailerURL,
      durationText: meta.durationText
    )
  }

  private static func episodes(from value: Any, series: IPTVItem) -> [IPTVItem] {
    guard let root = value as? [String: Any] else { return [] }
    let seasons = root["episodes"] as? [String: Any] ?? [:]
    var items: [IPTVItem] = []
    for key in seasons.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
      let rows = (seasons[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
      for row in rows {
        let id = jsonString(row["id"])
        let episode = jsonString(row["episode_num"])
        let seasonNumber = Int(key) ?? Int(jsonString(row["season"])) ?? 0
        let title = display(row["title"], fallback: "Episode \(episode)")
        let ext = emptyToNil(jsonString(row["container_extension"])) ?? "mp4"
        let seasonLabel = seasonNumber > 0 ? String(format: "Season %d", seasonNumber) : "Episodes"
        let prefix = seasonNumber > 0 ? String(format: "S%02dE%02d ", seasonNumber, Int(episode) ?? 0) : ""
        items.append(IPTVItem(
          id: "episode-\(id)",
          name: prefix + title,
          group: seasonLabel,
          logoURL: series.logoURL,
          epgID: nil,
          kind: .episode,
          absoluteURL: nil,
          route: "series",
          streamID: id,
          fileExtension: ext
        ))
      }
    }
    return items
  }

  private static func jsonString(_ value: Any?) -> String {
    switch value {
    case let string as String: return string
    case let number as NSNumber: return number.stringValue
    default: return ""
    }
  }

  private static func display(_ value: Any?, fallback: String) -> String {
    let text = jsonString(value).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? fallback : text
  }

  private static func emptyToNil(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func loadTitle(item: IPTVItem, source: IPTVSource, password: String, session: URLSession, completion: @escaping (Result<IPTVTitleDetails, Error>) -> Void) {
    let base = normalizeServer(source.server)
    let action = item.kind == .series ? "get_series_info" : "get_vod_info"
    let idName = item.kind == .series ? "series_id" : "vod_id"
    guard let streamID = item.streamID, var components = URLComponents(string: base + "/player_api.php") else {
      completion(.failure(IPTVError.message("This title has no id.")))
      return
    }
    components.queryItems = [
      URLQueryItem(name: "username", value: source.username),
      URLQueryItem(name: "password", value: password),
      URLQueryItem(name: "action", value: action),
      URLQueryItem(name: idName, value: streamID)
    ]
    guard let url = components.url else {
      completion(.failure(IPTVError.badURL(base)))
      return
    }
    session.dataTask(with: url) { data, response, error in
      let result = decode(data: data, response: response, error: error)
      DispatchQueue.main.async {
        switch result {
        case .failure(let error):
          completion(.failure(error))
        case .success(let value):
          if item.kind == .series {
            completion(.success(IPTVTitleParser.seriesDetails(value, series: item)))
          } else {
            completion(.success(IPTVTitleParser.movieDetails(value, fallback: item)))
          }
        }
      }
    }.resume()
  }
}
