//
//  IPTVModels.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Saved IPTV sources. Passwords are not in this model; they live in the keychain.

import CoreGraphics
import Foundation

enum IPTVSourceKind: String, Codable {
  case m3u
  case xtream
}

struct IPTVSource: Codable, Equatable {
  var id: UUID
  var name: String
  var kind: IPTVSourceKind
  /// M3U URL or local file path. Unused for Xtream.
  var location: String
  /// Optional guide URL. For M3U this overrides url-tvg. For Xtream it overrides xmltv.php.
  var epgURL: String
  var server: String
  var username: String

  init(id: UUID = UUID(), name: String, kind: IPTVSourceKind, location: String = "", epgURL: String = "", server: String = "", username: String = "") {
    self.id = id
    self.name = name
    self.kind = kind
    self.location = location
    self.epgURL = epgURL
    self.server = server
    self.username = username
  }
}

enum IPTVItemKind: String, Codable {
  case live
  case vod
  case series
  case episode
}

struct IPTVItem: Codable, Equatable {
  var id: String
  var name: String
  var group: String
  var logoURL: String?
  var epgID: String?
  var kind: IPTVItemKind
  /// Set for M3U entries and Xtream direct_source. May embed credentials that came from the playlist itself.
  var absoluteURL: String?
  /// Xtream route: "live", "movie", or "series".
  var route: String?
  var streamID: String?
  var fileExtension: String?
  /// How to build a timeshift URL. Nil when the channel has no archive. The Xtream password is not stored here.
  var catchup: IPTVArchive?
  var plot: String?
  var rating: String?
  var releaseDate: String?
  var genre: String?
  var cast: String?
  var director: String?
  var tmdbID: String?
  var backdropURL: String?
  var trailerURL: String?
  var durationText: String?

  init(id: String, name: String, group: String, logoURL: String?, epgID: String?, kind: IPTVItemKind, absoluteURL: String?, route: String?, streamID: String?, fileExtension: String?, catchup: IPTVArchive? = nil, plot: String? = nil, rating: String? = nil, releaseDate: String? = nil, genre: String? = nil, cast: String? = nil, director: String? = nil, tmdbID: String? = nil, backdropURL: String? = nil, trailerURL: String? = nil, durationText: String? = nil) {
    self.id = id
    self.name = name
    self.group = group
    self.logoURL = logoURL
    self.epgID = epgID
    self.kind = kind
    self.absoluteURL = absoluteURL
    self.route = route
    self.streamID = streamID
    self.fileExtension = fileExtension
    self.catchup = catchup
    self.plot = plot
    self.rating = rating
    self.releaseDate = releaseDate
    self.genre = genre
    self.cast = cast
    self.director = director
    self.tmdbID = tmdbID
    self.backdropURL = backdropURL
    self.trailerURL = trailerURL
    self.durationText = durationText
  }

  func matchesText(_ query: String) -> Bool {
    let parts = [name, group, epgID, plot, rating, releaseDate, genre, cast, director].compactMap { $0 }
    return IPTVText.normalize(parts.joined(separator: " ")).contains(query)
  }

  var playsDirectly: Bool { kind != .series }

  /// A recognized archive mode with a positive day count and a way to build a URL.
  var hasArchive: Bool {
    guard let catchup, catchup.days > 0 else { return false }
    if catchup.mode == "xtream" { return true }
    return !(catchup.template ?? "").isEmpty
  }
}

/// Catch-up descriptor parsed from M3U attributes or Xtream `tv_archive`.
struct IPTVArchive: Codable, Equatable {
  /// `default`, `append`, `shift`, `flussonic`, `flussonic-hls`, `flussonic-ts`, `fs`, `xc`, `vod`, or `xtream`.
  var mode: String
  var days: Int
  /// Placeholder template. Nil for `xtream`, which is built from the server at play time.
  var template: String?
  /// Hours subtracted from the programme clock when filling the URL. The guide times themselves are unchanged.
  var correctionHours: Double
}

struct IPTVCatalog: Codable {
  var epgURL: String?
  var items: [IPTVItem]
}

struct IPTVLibraryFile: Codable {
  var sources: [IPTVSource]
  /// "sourceUUID|itemID"
  var favourites: [String]
}

struct IPTVProgramme {
  var title: String
  var start: Date
  var stop: Date
  /// XMLTV `catchup-id`, when the guide supplied one.
  var catchupID: String?
}

/// How much of an XMLTV file the guide keeps and draws.
/// A week back is kept so catch-up listings can be clicked. Older programmes are dropped even if `catchup-days` is longer.
enum IPTVGuideWindow {
  static let retainedDays = 7
  static let past: TimeInterval = TimeInterval(retainedDays) * 24 * 60 * 60
  static let future: TimeInterval = 26 * 60 * 60
  static let timelinePast: TimeInterval = past
  /// Seven days before the current hour through 24 hours ahead.
  static let timelineLength: TimeInterval = past + 24 * 60 * 60
  static let rowHeight: CGFloat = 72
  static let channelWidth: CGFloat = 288
  static let headerHeight: CGFloat = 34
  static let hourWidth: CGFloat = 220

  static func timelineStart(at moment: Date = Date()) -> Date {
    let hour = Calendar.current.dateInterval(of: .hour, for: moment)?.start ?? moment
    return hour.addingTimeInterval(-timelinePast)
  }
}

struct IPTVEPG {
  private var byID: [String: [IPTVProgramme]] = [:]
  private var nameToID: [String: String] = [:]

  var programmeCount: Int {
    byID.values.reduce(0) { $0 + $1.count }
  }

  var isEmpty: Bool { byID.isEmpty }

  /// Keeps a programme when it overlaps `[moment - past, moment + future]`.
  mutating func add(channelID: String, names: [String], programme: IPTVProgramme, at moment: Date) {
    let windowStart = moment.addingTimeInterval(-IPTVGuideWindow.past)
    let windowEnd = moment.addingTimeInterval(IPTVGuideWindow.future)
    guard programme.stop > programme.start else { return }
    guard programme.stop > windowStart, programme.start < windowEnd else { return }
    let idKey = IPTVText.normalize(channelID)
    let key = idKey.isEmpty ? IPTVText.normalize(names.first ?? "") : idKey
    guard !key.isEmpty else { return }
    byID[key, default: []].append(programme)
    guard !idKey.isEmpty else { return }
    for name in names {
      let normalized = IPTVText.normalize(name)
      if !normalized.isEmpty {
        nameToID[normalized] = idKey
      }
    }
  }

  mutating func sortProgrammes() {
    for key in byID.keys {
      byID[key]?.sort { $0.start < $1.start }
    }
  }

  func programmes(for item: IPTVItem) -> [IPTVProgramme] {
    if let epgID = item.epgID {
      let key = IPTVText.normalize(epgID)
      if let list = byID[key] { return list }
      if let mapped = nameToID[key], let list = byID[mapped] { return list }
    }
    let name = IPTVText.normalize(item.name)
    if let mapped = nameToID[name], let list = byID[mapped] { return list }
    return byID[name] ?? []
  }

  func nowAndNext(for item: IPTVItem, at moment: Date) -> (now: IPTVProgramme?, next: IPTVProgramme?) {
    var current: IPTVProgramme?
    var upcoming: IPTVProgramme?
    for programme in programmes(for: item) {
      if programme.start <= moment && programme.stop > moment {
        if current == nil || programme.start >= current!.start {
          current = programme
        }
      } else if programme.start > moment && (upcoming == nil || programme.start < upcoming!.start) {
        upcoming = programme
      }
    }
    return (current, upcoming)
  }

  /// Channel name, group, EPG id, or any stored programme title.
  func matches(_ item: IPTVItem, query: String) -> Bool {
    let hay = IPTVText.normalize(item.name + " " + item.group + " " + (item.epgID ?? ""))
    if hay.contains(query) { return true }
    return programmes(for: item).contains { IPTVText.normalize($0.title).contains(query) }
  }
}

enum IPTVText {
  static func normalize(_ raw: String) -> String {
    raw.lowercased().split { $0.isWhitespace || $0.isNewline }.joined(separator: " ")
  }
}

/// What the guide should do with a click.
enum IPTVGuideAction {
  case live
  /// Play the provider timeshift URL from the programme start.
  case fromStart(IPTVProgramme, restart: Bool)
  case notice(String)
}

/// M3U header values that apply when an entry omits them.
struct IPTVCatchupHeader {
  var mode: String?
  var days: Int?
  var source: String?
  var correctionHours: Double?
}

/// Timeshift URL rules used by M3U `catchup` attributes and Xtream `tv_archive`.
/// Placeholder substitution replaces a whole token, so `{duration:60}` is not eaten by `{duration}` and `{utc:Y-m-d}` is not eaten by `{utc}`.
enum IPTVCatchup {
  static func resolve(attributes: [String: String], header: IPTVCatchupHeader, streamURL: String) -> IPTVArchive? {
    var mode = firstNonEmpty(attributes["catchup"], attributes["catchup-type"], header.mode)?.lowercased()
    let source = firstNonEmpty(attributes["catchup-source"], header.source)
    var days = intValue(attributes["catchup-days"])
    let legacyDays = intValue(attributes["timeshift"]) ?? intValue(attributes["tvg-rec"])
    if days == nil {
      days = legacyDays ?? header.days
    }
    let known: Set<String> = ["default", "append", "shift", "flussonic", "flussonic-hls", "flussonic-ts", "fs", "xc", "vod"]
    if mode == nil, let legacyDays, legacyDays > 0 {
      mode = "shift"
    }
    guard let mode, known.contains(mode) else { return nil }
    guard let days, days > 0 else { return nil }
    guard let template = template(mode: mode, source: source, streamURL: streamURL), !template.isEmpty else { return nil }
    let correction = doubleValue(attributes["catchup-correction"]) ?? header.correctionHours ?? 0
    return IPTVArchive(mode: mode, days: days, template: template, correctionHours: correction)
  }

  static func template(mode: String, source: String?, streamURL: String) -> String? {
    switch mode {
    case "default":
      if let source, !source.isEmpty { return source }
      return appendShiftQuery(streamURL)
    case "append":
      if let source, !source.isEmpty { return streamURL + source }
      return appendShiftQuery(streamURL)
    case "shift":
      return appendShiftQuery(streamURL)
    case "flussonic", "flussonic-hls":
      return flussonicTemplate(streamURL, preferTS: false)
    case "flussonic-ts", "fs":
      return flussonicTemplate(streamURL, preferTS: true)
    case "xc":
      return xtreamCodesTemplate(streamURL)
    case "vod":
      if let source, !source.isEmpty { return source }
      return "{catchup-id}"
    default:
      return nil
    }
  }

  /// SIPTV-style query used for `shift`, and for `default` / `append` when no `catchup-source` was given.
  static func appendShiftQuery(_ url: String) -> String {
    let query = "utc={utc}&lutc={lutc}"
    if url.contains("?") { return url + "&" + query }
    return url + "?" + query
  }

  static func canPlayFromStart(_ item: IPTVItem, _ programme: IPTVProgramme, now: Date) -> Bool {
    guard withinArchive(item, programme, now: now) else { return false }
    guard programme.stop <= now, programme.start < now else { return false }
    return templateCanPlay(item, programme)
  }

  static func canRestart(_ item: IPTVItem, _ programme: IPTVProgramme, now: Date) -> Bool {
    guard withinArchive(item, programme, now: now) else { return false }
    guard programme.start <= now, programme.stop > now else { return false }
    return templateCanPlay(item, programme)
  }

  /// Xtream `tv_archive` URL. `duration` minutes are at least 1. The clock is the Mac's local time after `catchup` correction.
  static func xtreamArchiveURL(base: String, username: String, password: String, streamID: String, programme: IPTVProgramme, correctionHours: Double, timeZone: TimeZone = .current) -> URL? {
    let duration = max(0, programme.stop.timeIntervalSince(programme.start))
    let minutes = max(1, Int(duration) / 60)
    let start = correctedStart(programme.start, correctionHours: correctionHours)
    let stamp = formatClock(start, pattern: "Y-m-d:H-M", timeZone: timeZone)
    let user = IPTVXtream.pathEscape(username)
    let pass = IPTVXtream.pathEscape(password)
    let id = IPTVXtream.pathEscape(streamID)
    return URL(string: "\(base)/timeshift/\(user)/\(pass)/\(minutes)/\(stamp)/\(id).ts")
  }

  static func url(template: String, programme: IPTVProgramme, now: Date, correctionHours: Double, timeZone: TimeZone = .current) -> URL? {
    let formatted = formatTemplate(template, start: programme.start, end: programme.stop, now: now, correctionHours: correctionHours, catchupID: programme.catchupID, timeZone: timeZone)
    if formatted.lowercased().hasPrefix("plugin://") { return nil }
    guard let url = URL(string: formatted), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
    return url
  }

  /// `{utc:FORMAT}` and `{duration:N}` are replaced before the bare tokens.
  static func formatTemplate(_ template: String, start: Date, end: Date, now: Date, correctionHours: Double, catchupID: String?, timeZone: TimeZone) -> String {
    let urlStart = correctedStart(start, correctionHours: correctionHours)
    let duration = max(0, end.timeIntervalSince(start))
    let urlEnd = urlStart.addingTimeInterval(duration)
    let offset = max(0, now.timeIntervalSince(urlStart))
    var text = template
    text = replaceMatches(formatPattern, in: text) { match, _ in
      let dollar = group(1, match, text)
      let plain = group(2, match, text)
      let pattern = group(3, match, text)
      let name = dollar.isEmpty ? plain : dollar
      let moment: Date
      switch name {
      case "utc", "start": moment = urlStart
      case "utcend", "end": moment = urlEnd
      case "lutc", "now", "timestamp": moment = now
      default: return ""
      }
      return formatClock(moment, pattern: pattern, timeZone: timeZone)
    }
    text = replaceMatches(unitsPattern, in: text) { match, _ in
      let kind = group(1, match, text)
      let divider = Int(group(2, match, text)) ?? 0
      guard divider > 0 else { return "0" }
      let seconds = kind == "offset" ? offset : duration
      let units = Int(seconds) / divider
      return String(max(0, units))
    }
    let startParts = clockParts(urlStart, timeZone: timeZone)
    let pairs = [
      ("{Y}", startParts.Y), ("{m}", startParts.m), ("{d}", startParts.d),
      ("{H}", startParts.H), ("{M}", startParts.M), ("{S}", startParts.S),
      ("{utc}", unix(urlStart)), ("${start}", unix(urlStart)),
      ("{utcend}", unix(urlEnd)), ("${end}", unix(urlEnd)),
      ("{lutc}", unix(now)), ("${now}", unix(now)), ("${timestamp}", unix(now)),
      ("{duration}", String(Int(duration))),
      ("${offset}", String(Int(offset)))
    ]
    for (token, value) in pairs {
      text = text.replacingOccurrences(of: token, with: value)
    }
    if let catchupID {
      text = text.replacingOccurrences(of: "{catchup-id}", with: catchupID)
    }
    return text
  }

  private static func correctedStart(_ start: Date, correctionHours: Double) -> Date {
    // Same sign as Kodi: the attribute is stored as hours and then subtracted.
    // catchup-correction="-4" therefore moves URL timestamps four hours later.
    start.addingTimeInterval(-correctionHours * 3600)
  }

  private static func withinArchive(_ item: IPTVItem, _ programme: IPTVProgramme, now: Date) -> Bool {
    guard item.hasArchive, let days = item.catchup?.days, days > 0 else { return false }
    let earliest = now.addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60)
    return programme.start >= earliest
  }

  private static func templateCanPlay(_ item: IPTVItem, _ programme: IPTVProgramme) -> Bool {
    guard let catchup = item.catchup else { return false }
    if catchup.mode == "xtream" { return true }
    let template = catchup.template ?? ""
    if template == "{catchup-id}" || template.lowercased().hasPrefix("plugin://") {
      let id = programme.catchupID?.lowercased() ?? ""
      return id.hasPrefix("http://") || id.hasPrefix("https://")
    }
    return !template.isEmpty
  }

  private static func flussonicTemplate(_ url: String, preferTS: Bool) -> String? {
    let wellDefined = #"^(https?://[^/]+)/(.*)/([^/]*)(mpegts|\.m3u8)(\?.+=.+)?$"#
    if let parts = firstMatch(wellDefined, in: url), parts.count >= 6 {
      let host = parts[1]
      let channel = parts[2]
      let listType = parts[3]
      let streamType = parts[4]
      let query = parts[5]
      if streamType == "mpegts" {
        return "\(host)/\(channel)/timeshift_abs-${start}.ts\(query)"
      }
      if listType == "index" {
        return "\(host)/\(channel)/timeshift_rel-{offset:1}.m3u8\(query)"
      }
      return "\(host)/\(channel)/\(listType)-timeshift_rel-{offset:1}.m3u8\(query)"
    }
    let generic = #"^(https?://[^/]+)/(.*)/([^\?]*)(\?.+=.+)?$"#
    if let parts = firstMatch(generic, in: url), parts.count >= 5 {
      let host = parts[1]
      let channel = parts[2]
      let query = parts[4]
      if preferTS {
        return "\(host)/\(channel)/timeshift_abs-${start}.ts\(query)"
      }
      return "\(host)/\(channel)/timeshift_rel-{offset:1}.m3u8\(query)"
    }
    return nil
  }

  private static func xtreamCodesTemplate(_ url: String) -> String? {
    let pattern = #"^(https?://[^/]+)/(?:live/)?([^/]+)/([^/]+)/([^/\.]+)(\.m3u8?)?$"#
    guard let parts = firstMatch(pattern, in: url), parts.count >= 6 else { return nil }
    let host = parts[1]
    let user = parts[2]
    let pass = parts[3]
    let id = parts[4]
    var ext = parts[5]
    if ext.isEmpty { ext = ".ts" }
    return "\(host)/timeshift/\(user)/\(pass)/{duration:60}/{Y}-{m}-{d}:{H}-{M}/\(id)\(ext)"
  }

  private static func formatClock(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
    let parts = clockParts(date, timeZone: timeZone)
    var out = ""
    for character in pattern {
      switch character {
      case "Y": out += parts.Y
      case "m": out += parts.m
      case "d": out += parts.d
      case "H": out += parts.H
      case "M": out += parts.M
      case "S": out += parts.S
      default: out.append(character)
      }
    }
    return out
  }

  private static func clockParts(_ date: Date, timeZone: TimeZone) -> (Y: String, m: String, d: String, H: String, M: String, S: String) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return (
      String(format: "%04d", components.year ?? 0),
      String(format: "%02d", components.month ?? 0),
      String(format: "%02d", components.day ?? 0),
      String(format: "%02d", components.hour ?? 0),
      String(format: "%02d", components.minute ?? 0),
      String(format: "%02d", components.second ?? 0)
    )
  }

  private static func unix(_ date: Date) -> String {
    String(Int(date.timeIntervalSince1970))
  }

  private static func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      if let value {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
    }
    return nil
  }

  static func positiveDays(_ raw: String?) -> Int? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let value = Int(trimmed), value > 0 { return value }
    if let value = Double(trimmed), value >= 1 { return Int(value) }
    return nil
  }

  private static func intValue(_ raw: String?) -> Int? {
    positiveDays(raw)
  }

  private static func doubleValue(_ raw: String?) -> Double? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let value = Double(trimmed) else { return nil }
    return value
  }

  private static let formatPattern = try! NSRegularExpression(pattern: #"(?:\$\{(start|end|now|timestamp)|\{(utc|utcend|lutc)):([^{}]*)\}"#)
  private static let unitsPattern = try! NSRegularExpression(pattern: #"\{(duration|offset):(\d+)\}"#)

  private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
    var parts: [String] = []
    for index in 0..<match.numberOfRanges {
      parts.append(group(index, match, text))
    }
    return parts
  }

  private static func group(_ index: Int, _ match: NSTextCheckingResult, _ text: String) -> String {
    let range = match.range(at: index)
    guard range.location != NSNotFound, let swift = Range(range, in: text) else { return "" }
    return String(text[swift])
  }

  private static func replaceMatches(_ regex: NSRegularExpression, in text: String, _ transform: (NSTextCheckingResult, String) -> String) -> String {
    let range = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, options: [], range: range)
    if matches.isEmpty { return text }
    var result = ""
    var cursor = text.startIndex
    for match in matches {
      guard let matchRange = Range(match.range, in: text) else { continue }
      result += text[cursor..<matchRange.lowerBound]
      result += transform(match, String(text[matchRange]))
      cursor = matchRange.upperBound
    }
    result += text[cursor...]
    return result
  }
}

enum IPTVError: LocalizedError {
  case badURL(String)
  case http(Int)
  case unauthorized(String)
  case notJSON
  case keychain(String)
  case message(String)

  var errorDescription: String? {
    switch self {
    case .badURL(let value):
      return "Could not use \(value) as a URL."
    case .http(let code):
      return "The server returned HTTP \(code)."
    case .unauthorized(let message):
      return message.isEmpty ? "The server rejected this username or password." : message
    case .notJSON:
      return "The server response was not JSON."
    case .keychain(let message):
      return "The password could not be saved in the Keychain. \(message)"
    case .message(let message):
      return message
    }
  }
}
