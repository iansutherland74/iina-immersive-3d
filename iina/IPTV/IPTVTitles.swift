//
//  IPTVTitles.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Xtream get_vod_info / get_series_info, watch progress, and optional TMDB gap fill.
//  The parsers and URL rules were checked as a Python transcription, not by compiling Swift
//  or contacting a provider.

import CryptoKit
import Foundation

extension Notification.Name {
  static let iptvWatchProgressDidChange = Notification.Name("IINAIPTVWatchProgressDidChange")
}

struct IPTVEpisodeDetails: Codable, Equatable {
  var season: Int
  var episode: Int
  var item: IPTVItem
  var plot: String?
  var thumbnailURL: String?
  var durationText: String?
  var durationSeconds: Double?
}

struct IPTVTitleDetails: Codable, Equatable {
  var name: String
  var plot: String?
  var cast: String?
  var director: String?
  var genre: String?
  var rating: String?
  var releaseDate: String?
  var durationText: String?
  var durationSeconds: Double?
  var posterURL: String?
  var backdropURL: String?
  var trailerURL: String?
  var tmdbID: String?
  var episodes: [IPTVEpisodeDetails]

  var factLine: String {
    let year = IPTVTitleParser.year(in: releaseDate) ?? IPTVTitleParser.splitTitleYear(name).year
    return [year, rating, durationText, genre].compactMap { value in
      guard let value, !value.isEmpty else { return nil }
      return value
    }.joined(separator: " · ")
  }
}

struct IPTVTitleCacheEntry: Codable {
  var fetchedAt: Date
  var tmdbFingerprint: String
  var details: IPTVTitleDetails
}

struct IPTVWatchRecord: Codable, Equatable {
  var position: Double
  var duration: Double
  var updated: Date
  var title: String
  var kind: String
  var group: String
  var logoURL: String?
  var route: String?
  var streamID: String?
  var fileExtension: String?
  var absoluteURL: String?
  var seriesItemID: String?
  var seriesTitle: String?
}

enum IPTVWatch {
  /// Ignore a few seconds of playback so opening a title does not look like progress.
  static let minimumResume = 30.0

  static func resumeSeconds(_ record: IPTVWatchRecord) -> Double? {
    guard record.position >= minimumResume else { return nil }
    if record.duration > 0 {
      if record.position >= record.duration - 30 { return nil }
      if record.position / record.duration >= 0.95 { return nil }
    }
    return record.position
  }

  static func fraction(_ record: IPTVWatchRecord) -> Double {
    guard record.duration > 0 else { return 0 }
    return min(1, max(0, record.position / record.duration))
  }
}

enum IPTVTitleParser {
  static func metadata(fromList object: [String: Any]) -> (plot: String?, rating: String?, releaseDate: String?, genre: String?, cast: String?, director: String?, tmdbID: String?, backdropURL: String?, trailerURL: String?, durationText: String?, posterURL: String?) {
    let plot = firstText(object["plot"], object["description"], object["overview"])
    let rating = ratingString(object)
    let release = firstText(object["releaseDate"], object["releasedate"], object["release_date"], object["year"])
    let genre = firstText(object["genre"])
    let cast = firstText(object["cast"], object["actors"])
    let director = firstText(object["director"])
    let tmdb = tmdbID(object["tmdb_id"] ?? object["tmdb"])
    let backdrop = firstURL(object["backdrop_path"] ?? object["backdrop"])
    let trailer = trailerURL(from: firstText(object["youtube_trailer"], object["trailer"]))
    let duration = duration(from: object)
    let poster = firstURL(object["stream_icon"] ?? object["cover"] ?? object["cover_big"] ?? object["movie_image"])
    return (plot, rating, release, genre, cast, director, tmdb, backdrop, trailer, duration.text, poster)
  }

  /// A single episode opened without its series. Does not call get_vod_info.
  static func details(from item: IPTVItem) -> IPTVTitleDetails {
    IPTVTitleDetails(
      name: item.name,
      plot: item.plot,
      cast: item.cast,
      director: item.director,
      genre: item.genre,
      rating: item.rating,
      releaseDate: item.releaseDate,
      durationText: item.durationText,
      durationSeconds: nil,
      posterURL: item.logoURL,
      backdropURL: item.backdropURL,
      trailerURL: item.trailerURL,
      tmdbID: item.tmdbID,
      episodes: []
    )
  }

  static func movieDetails(_ value: Any, fallback: IPTVItem) -> IPTVTitleDetails {
    let root = value as? [String: Any] ?? [:]
    let info = dictionary(root["info"]) ?? root
    let movie = dictionary(root["movie_data"]) ?? [:]
    let duration = duration(from: info)
    let name = firstText(info["name"], info["o_name"], movie["name"]) ?? fallback.name
    return IPTVTitleDetails(
      name: name,
      plot: firstText(info["plot"], info["description"], info["overview"], fallback.plot),
      cast: firstText(info["cast"], info["actors"], fallback.cast),
      director: firstText(info["director"], fallback.director),
      genre: firstText(info["genre"], fallback.genre),
      rating: ratingString(info) ?? fallback.rating,
      releaseDate: firstText(info["releasedate"], info["release_date"], info["releaseDate"], fallback.releaseDate),
      durationText: duration.text ?? fallback.durationText,
      durationSeconds: duration.seconds,
      posterURL: firstURL(info["movie_image"] ?? info["cover_big"] ?? info["cover"] ?? movie["stream_icon"]) ?? fallback.logoURL,
      backdropURL: firstURL(info["backdrop_path"] ?? info["backdrop"]) ?? fallback.backdropURL,
      trailerURL: trailerURL(from: firstText(info["youtube_trailer"], info["trailer"], fallback.trailerURL)),
      tmdbID: tmdbID(info["tmdb_id"] ?? info["tmdb"] ?? movie["tmdb"]) ?? fallback.tmdbID,
      episodes: []
    )
  }

  static func seriesDetails(_ value: Any, series: IPTVItem) -> IPTVTitleDetails {
    let root = value as? [String: Any] ?? [:]
    let info = dictionary(root["info"]) ?? root
    let duration = duration(from: info)
    let name = firstText(info["name"], info["o_name"]) ?? series.name
    let episodes = episodes(in: root, seriesName: name, seriesLogo: firstURL(info["cover"] ?? info["cover_big"]) ?? series.logoURL)
    return IPTVTitleDetails(
      name: name,
      plot: firstText(info["plot"], info["description"], info["overview"], series.plot),
      cast: firstText(info["cast"], info["actors"], series.cast),
      director: firstText(info["director"], series.director),
      genre: firstText(info["genre"], series.genre),
      rating: ratingString(info) ?? series.rating,
      releaseDate: firstText(info["releaseDate"], info["releasedate"], info["release_date"], series.releaseDate),
      durationText: duration.text ?? series.durationText,
      durationSeconds: duration.seconds,
      posterURL: firstURL(info["cover"] ?? info["cover_big"] ?? info["movie_image"]) ?? series.logoURL,
      backdropURL: firstURL(info["backdrop_path"] ?? info["backdrop"]) ?? series.backdropURL,
      trailerURL: trailerURL(from: firstText(info["youtube_trailer"], info["trailer"], series.trailerURL)),
      tmdbID: tmdbID(info["tmdb"] ?? info["tmdb_id"]) ?? series.tmdbID,
      episodes: episodes
    )
  }

  static func episodes(in root: [String: Any], seriesName: String, seriesLogo: String?) -> [IPTVEpisodeDetails] {
    var rows: [(Int, Int, [String: Any])] = []
    if let seasons = root["episodes"] as? [String: Any] {
      for (key, value) in seasons {
        let seasonNumber = Int(key) ?? 0
        for row in arrayOfDictionaries(value) {
          let season = Int(text(row["season"])) ?? seasonNumber
          let episode = Int(text(row["episode_num"])) ?? Int(text(row["episode"])) ?? 0
          rows.append((season, episode, row))
        }
      }
    } else {
      for row in arrayOfDictionaries(root["episodes"]) {
        let season = Int(text(row["season"])) ?? 0
        let episode = Int(text(row["episode_num"])) ?? Int(text(row["episode"])) ?? 0
        rows.append((season, episode, row))
      }
    }
    rows.sort { lhs, rhs in
      if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
      if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
      return text(lhs.2["id"]) < text(rhs.2["id"])
    }
    return rows.compactMap { season, episode, row in
      let info = dictionary(row["info"]) ?? [:]
      let streamID = text(row["id"])
      guard !streamID.isEmpty else { return nil }
      let title = firstText(row["title"], info["title"], info["name"]) ?? (episode > 0 ? "Episode \(episode)" : "Episode")
      let prefix = season > 0 ? String(format: "S%02dE%02d ", season, episode) : ""
      let plot = firstText(info["plot"], info["description"], row["plot"])
      let thumb = firstURL(info["movie_image"] ?? info["cover"] ?? row["movie_image"] ?? row["stream_icon"] ?? info["thumbnail"]) ?? seriesLogo
      let duration = duration(from: info.isEmpty ? row : info)
      let ext = firstText(row["container_extension"], info["container_extension"]) ?? "mp4"
      let direct = firstText(row["direct_source"]).flatMap { raw -> String? in
        guard let url = URL(string: raw), url.scheme != nil else { return nil }
        return url.absoluteString
      }
      let seasonLabel = season > 0 ? "Season \(season)" : "Episodes"
      let item = IPTVItem(
        id: "episode-\(streamID)",
        name: prefix + title,
        group: seasonLabel,
        logoURL: thumb,
        epgID: nil,
        kind: .episode,
        absoluteURL: direct,
        route: "series",
        streamID: streamID,
        fileExtension: ext,
        plot: plot,
        durationText: duration.text
      )
      return IPTVEpisodeDetails(
        season: season,
        episode: episode,
        item: item,
        plot: plot,
        thumbnailURL: thumb,
        durationText: duration.text,
        durationSeconds: duration.seconds
      )
    }
  }

  static func trailerURL(from raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "0" else { return nil }
    let lower = trimmed.lowercased()
    if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return trimmed }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    if trimmed.count == 11, trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
      return "https://www.youtube.com/watch?v=\(trimmed)"
    }
    return nil
  }

  static func year(in raw: String?) -> String? {
    guard let raw else { return nil }
    let digits = raw.prefix(4)
    guard digits.count == 4, let year = Int(digits), (1900...2100).contains(year) else { return nil }
    return String(digits)
  }

  /// Title used for a TMDB search, plus a year from the release date or a trailing `(YYYY)`.
  static func splitTitleYear(_ name: String, releaseDate: String? = nil) -> (title: String, year: String?) {
    let year = year(in: releaseDate) ?? trailingYear(in: name)
    var title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let year {
      title = title.replacingOccurrences(of: "(\(year))", with: "")
      title = title.replacingOccurrences(of: "[\(year)]", with: "")
      if title.hasSuffix(" \(year)") {
        title = String(title.dropLast(year.count + 1))
      }
    }
    title = title.split { $0.isWhitespace }.joined(separator: " ")
    return (title.isEmpty ? name : title, year)
  }

  static func durationLabel(seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m" }
    return "\(total)s"
  }

  static func seconds(fromClock raw: String) -> Double? {
    let parts = raw.split(separator: ":").compactMap { Double($0) }
    guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ $0 >= 0 }) else { return nil }
    if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
    return parts[0] * 60 + parts[1]
  }

  static func tmdbImage(_ path: String?, size: String) -> String? {
    guard let path else { return nil }
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") { return trimmed }
    if trimmed.hasPrefix("/") { return "https://image.tmdb.org/t/p/\(size)\(trimmed)" }
    return trimmed
  }

  /// Fills only empty fields. Xtream values that are already present stay.
  static func mergingTMDB(_ details: IPTVTitleDetails, json: [String: Any]) -> IPTVTitleDetails {
    var copy = details
    if empty(copy.plot), let overview = firstText(json["overview"]) { copy.plot = overview }
    if empty(copy.posterURL) { copy.posterURL = tmdbImage(firstText(json["poster_path"]), size: "w500") }
    if empty(copy.backdropURL) { copy.backdropURL = tmdbImage(firstText(json["backdrop_path"]), size: "w1280") }
    if empty(copy.rating), let vote = doubleValue(json["vote_average"]), vote > 0 {
      copy.rating = String(format: "%.1f", vote)
    }
    if empty(copy.releaseDate) {
      copy.releaseDate = firstText(json["release_date"], json["first_air_date"])
    }
    if empty(copy.genre) {
      let names = arrayOfDictionaries(json["genres"]).compactMap { firstText($0["name"]) }
      if !names.isEmpty { copy.genre = names.joined(separator: ", ") }
    }
    if empty(copy.durationText), let runtime = doubleValue(json["runtime"]) ?? episodeRuntime(json["episode_run_time"]), runtime > 0 {
      let seconds = runtime * 60
      copy.durationSeconds = seconds
      copy.durationText = durationLabel(seconds: seconds)
    }
    if let credits = dictionary(json["credits"]) {
      if empty(copy.cast) {
        let names = arrayOfDictionaries(credits["cast"]).prefix(8).compactMap { firstText($0["name"]) }
        if !names.isEmpty { copy.cast = names.joined(separator: ", ") }
      }
      if empty(copy.director) {
        let director = arrayOfDictionaries(credits["crew"]).first { text($0["job"]).caseInsensitiveCompare("Director") == .orderedSame }
        copy.director = firstText(director?["name"])
        if empty(copy.director) {
          let created = arrayOfDictionaries(json["created_by"]).compactMap { firstText($0["name"]) }
          if !created.isEmpty { copy.director = created.joined(separator: ", ") }
        }
      }
    }
    if empty(copy.tmdbID), let id = tmdbID(json["id"]) { copy.tmdbID = id }
    return copy
  }

  static func applyingEpisodeTMDB(_ episode: IPTVEpisodeDetails, overview: String?, stillPath: String?) -> IPTVEpisodeDetails {
    var copy = episode
    if empty(copy.plot), let overview, !overview.isEmpty { copy.plot = overview }
    if empty(copy.thumbnailURL), let still = tmdbImage(stillPath, size: "w300") { copy.thumbnailURL = still }
    if empty(copy.item.plot) { copy.item.plot = copy.plot }
    if empty(copy.item.logoURL) { copy.item.logoURL = copy.thumbnailURL }
    return copy
  }

  static func needsTMDB(_ details: IPTVTitleDetails) -> Bool {
    empty(details.plot) || empty(details.posterURL) || empty(details.backdropURL)
  }

  static func fingerprint(for apiKey: String) -> String {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let digest = SHA256.hash(data: Data(trimmed.utf8))
    return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
  }

  private static func trailingYear(in name: String) -> String? {
    let pattern = #"\((\d{4})\)\s*$|\[(\d{4})\]\s*$|\s(\d{4})\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
    for index in 1..<match.numberOfRanges {
      let range = match.range(at: index)
      guard range.location != NSNotFound, let swift = Range(range, in: name) else { continue }
      let year = String(name[swift])
      if let value = Int(year), (1900...2100).contains(value) { return year }
    }
    return nil
  }

  private static func duration(from object: [String: Any]) -> (text: String?, seconds: Double?) {
    if let seconds = doubleValue(object["duration_secs"]), seconds > 0 {
      return (durationLabel(seconds: seconds), seconds)
    }
    let written = firstText(object["duration"])
    if let written, written.contains(":"), let seconds = seconds(fromClock: written) {
      return (durationLabel(seconds: seconds), seconds)
    }
    if let minutes = doubleValue(object["episode_run_time"]), minutes > 0 {
      let seconds = minutes * 60
      return (durationLabel(seconds: seconds), seconds)
    }
    if let written, !written.isEmpty { return (written, nil) }
    return (nil, nil)
  }

  private static func ratingString(_ object: [String: Any]) -> String? {
    let raw = text(object["rating"])
    if !raw.isEmpty, raw != "0", raw != "0.0", raw != "0.00" { return raw }
    if let five = doubleValue(object["rating_5based"]), five > 0 {
      return String(format: "%.1f/5", five)
    }
    return nil
  }

  private static func tmdbID(_ value: Any?) -> String? {
    let raw = text(value)
    guard !raw.isEmpty, raw != "0", raw.allSatisfy({ $0.isNumber }) else { return nil }
    return raw
  }

  private static func episodeRuntime(_ value: Any?) -> Double? {
    if let number = doubleValue(value), number > 0 { return number }
    if let array = value as? [Any], let first = doubleValue(array.first), first > 0 { return first }
    return nil
  }

  private static func firstText(_ values: Any?...) -> String? {
    for value in values {
      let raw = text(value)
      if !raw.isEmpty { return raw }
    }
    return nil
  }

  private static func firstURL(_ value: Any?) -> String? {
    switch value {
    case let string as String:
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    case let array as [Any]:
      for entry in array {
        if let url = firstURL(entry) { return url }
      }
      return nil
    case let object as [String: Any]:
      return firstURL(object["url"] ?? object["path"])
    default:
      return nil
    }
  }

  static func text(_ value: Any?) -> String {
    switch value {
    case let string as String:
      return string.trimmingCharacters(in: .whitespacesAndNewlines)
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "1" : "0" }
      return number.stringValue
    default:
      return ""
    }
  }

  static func doubleValue(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
      return number.doubleValue
    case let string as String:
      return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
      return nil
    }
  }

  static func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
  }

  static func arrayOfDictionaries(_ value: Any?) -> [[String: Any]] {
    if let array = value as? [[String: Any]] { return array }
    if let array = value as? [Any] { return array.compactMap { $0 as? [String: Any] } }
    return []
  }

  private static func empty(_ value: String?) -> Bool {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
  }
}

enum IPTVTMDB {
  struct Result {
    var details: IPTVTitleDetails
    var note: String?
  }

  static func enrich(_ details: IPTVTitleDetails, kind: IPTVItemKind, apiKey: String, session: URLSession, completion: @escaping (Result) -> Void) {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, IPTVTitleParser.needsTMDB(details) else {
      completion(Result(details: details, note: nil))
      return
    }
    let media = kind == .series ? "tv" : "movie"
    let split = IPTVTitleParser.splitTitleYear(details.name, releaseDate: details.releaseDate)
    resolveID(existing: details.tmdbID, media: media, title: split.title, year: split.year, apiKey: key, session: session) { id in
      guard let id else {
        DispatchQueue.main.async {
          completion(Result(details: details, note: "TMDB had no match for this title."))
        }
        return
      }
      var items = [URLQueryItem(name: "append_to_response", value: "credits")]
      applyKey(key, to: &items)
      guard let url = endpoint("/\(media)/\(id)", items: items) else {
        DispatchQueue.main.async { completion(Result(details: details, note: nil)) }
        return
      }
      data(url, key: key, session: session) { result in
        switch result {
        case .failure:
          DispatchQueue.main.async {
            completion(Result(details: details, note: "TMDB did not answer. The provider's details are shown."))
          }
        case .success(let json):
          var merged = IPTVTitleParser.mergingTMDB(details, json: json)
          if merged.tmdbID == nil { merged.tmdbID = id }
          fillEpisodes(merged, tmdbID: id, apiKey: key, session: session) { filled in
            DispatchQueue.main.async {
              completion(Result(details: filled, note: nil))
            }
          }
        }
      }
    }
  }

  private static func fillEpisodes(_ details: IPTVTitleDetails, tmdbID: String, apiKey: String, session: URLSession, completion: @escaping (IPTVTitleDetails) -> Void) {
    let targets = details.episodes.enumerated().filter { _, episode in
      let missingPlot = episode.plot?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
      let missingStill = episode.thumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
      return episode.season > 0 && episode.episode > 0 && (missingPlot || missingStill)
    }.prefix(12)
    guard !targets.isEmpty else {
      completion(details)
      return
    }
    let group = DispatchGroup()
    let lock = NSLock()
    var updates: [Int: (String?, String?)] = [:]
    for (index, episode) in targets {
      group.enter()
      var items: [URLQueryItem] = []
      applyKey(apiKey, to: &items)
      guard let url = endpoint("/tv/\(tmdbID)/season/\(episode.season)/episode/\(episode.episode)", items: items) else {
        group.leave()
        continue
      }
      data(url, key: apiKey, session: session) { result in
        if case .success(let json) = result {
          lock.lock()
          updates[index] = (IPTVTitleParser.text(json["overview"]), IPTVTitleParser.text(json["still_path"]))
          lock.unlock()
        }
        group.leave()
      }
    }
    group.notify(queue: .global(qos: .userInitiated)) {
      var copy = details
      for (index, update) in updates {
        guard copy.episodes.indices.contains(index) else { continue }
        let overview = update.0.isEmpty ? nil : update.0
        let still = update.1.isEmpty ? nil : update.1
        copy.episodes[index] = IPTVTitleParser.applyingEpisodeTMDB(copy.episodes[index], overview: overview, stillPath: still)
      }
      completion(copy)
    }
  }

  private static func resolveID(existing: String?, media: String, title: String, year: String?, apiKey: String, session: URLSession, completion: @escaping (String?) -> Void) {
    if let existing, !existing.isEmpty {
      completion(existing)
      return
    }
    guard !title.isEmpty else {
      completion(nil)
      return
    }
    search(media: media, title: title, year: year, apiKey: apiKey, session: session) { id in
      if let id {
        completion(id)
        return
      }
      guard year != nil else {
        completion(nil)
        return
      }
      search(media: media, title: title, year: nil, apiKey: apiKey, session: session, completion: completion)
    }
  }

  private static func search(media: String, title: String, year: String?, apiKey: String, session: URLSession, completion: @escaping (String?) -> Void) {
    var items = [URLQueryItem(name: "query", value: title)]
    if let year {
      items.append(URLQueryItem(name: media == "tv" ? "first_air_date_year" : "year", value: year))
    }
    applyKey(apiKey, to: &items)
    guard let url = endpoint("/search/\(media)", items: items) else {
      completion(nil)
      return
    }
    data(url, key: apiKey, session: session) { result in
      guard case .success(let json) = result else {
        completion(nil)
        return
      }
      let raw = IPTVTitleParser.arrayOfDictionaries(json["results"]).first.map { IPTVTitleParser.text($0["id"]) } ?? ""
      completion(raw.isEmpty || raw == "0" ? nil : raw)
    }
  }

  private static func applyKey(_ key: String, to items: inout [URLQueryItem]) {
    if !key.hasPrefix("ey") {
      items.append(URLQueryItem(name: "api_key", value: key))
    }
  }

  private static func endpoint(_ path: String, items: [URLQueryItem]) -> URL? {
    guard var components = URLComponents(string: "https://api.themoviedb.org/3" + path) else { return nil }
    components.queryItems = items
    return components.url
  }

  private static func data(_ url: URL, key: String, session: URLSession, completion: @escaping (Result<[String: Any], Error>) -> Void) {
    var request = URLRequest(url: url)
    if key.hasPrefix("ey") {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    session.dataTask(with: request) { data, response, error in
      if let error {
        completion(.failure(error))
        return
      }
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        completion(.failure(IPTVError.http(http.statusCode)))
        return
      }
      guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        completion(.failure(IPTVError.notJSON))
        return
      }
      completion(.success(json))
    }.resume()
  }
}
