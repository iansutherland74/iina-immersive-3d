//
//  IPTVParsers.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  M3U/M3U8 (#EXTINF, including tvg-id, tvg-logo, group-title, and catchup
//  attributes) and XMLTV listings. These parsers were not executed on the
//  machine that added them.

import Foundation

struct IPTVPlaylistParse {
  var epgURL: String?
  var items: [IPTVItem]
}

enum IPTVPlaylistParser {
  /// `base` resolves relative stream URLs. Network playlists pass their own URL; files pass the file URL.
  static func parse(_ raw: String, base: URL?) -> IPTVPlaylistParse {
    var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    if text.hasPrefix("\u{feff}") {
      text.removeFirst()
    }
    var epgURL: String?
    var header = IPTVCatchupHeader()
    var pendingGroup: String?
    var pending: (name: String, group: String, logo: String?, epgID: String?, attributes: [String: String])?
    var items: [IPTVItem] = []

    for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(lineSub).trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      if line.hasPrefix("#EXTM3U") {
        let attributes = attributes(in: String(line.dropFirst("#EXTM3U".count)))
        epgURL = firstNonEmpty(attributes["url-tvg"], attributes["x-tvg-url"], attributes["tvg-url"]) ?? epgURL
        header = catchupHeader(attributes, existing: header)
        continue
      }
      if line.hasPrefix("#EXTGRP:") {
        let name = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespaces)
        pendingGroup = name.isEmpty ? nil : name
        continue
      }
      if line.hasPrefix("#EXTINF:") {
        let body = String(line.dropFirst("#EXTINF:".count))
        let split = splitTitle(body)
        var meta = split.meta.trimmingCharacters(in: .whitespaces)
        if let token = meta.split(separator: " ", maxSplits: 1).first, Double(token) != nil {
          if let space = meta.firstIndex(where: { $0.isWhitespace }) {
            meta = String(meta[meta.index(after: space)...]).trimmingCharacters(in: .whitespaces)
          } else {
            meta = ""
          }
        }
        let attributes = attributes(in: meta)
        let group = firstNonEmpty(attributes["group-title"], pendingGroup) ?? "Ungrouped"
        var title = split.title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty {
          title = attributes["tvg-name"] ?? "Channel \(items.count + 1)"
        }
        let logo = emptyToNil(attributes["tvg-logo"])
        let epgID = emptyToNil(attributes["tvg-id"])
        pending = (title, group, logo, epgID, attributes)
        pendingGroup = nil
        continue
      }
      if line.hasPrefix("#") { continue }
      guard let current = pending else { continue }
      pending = nil
      let resolved = resolve(line, base: base)
      let archive = IPTVCatchup.resolve(attributes: current.attributes, header: header, streamURL: resolved)
      items.append(IPTVItem(
        id: "m3u-\(items.count)",
        name: current.name,
        group: current.group,
        logoURL: current.logo,
        epgID: current.epgID,
        kind: .live,
        absoluteURL: resolved,
        route: nil,
        streamID: nil,
        fileExtension: nil,
        catchup: archive
      ))
    }
    return IPTVPlaylistParse(epgURL: epgURL, items: items)
  }

  /// First comma outside quotes separates attributes from the display title.
  static func splitTitle(_ body: String) -> (meta: String, title: String) {
    var inSingle = false
    var inDouble = false
    let chars = Array(body)
    for index in chars.indices {
      let character = chars[index]
      if character == "\"" && !inSingle {
        inDouble.toggle()
      } else if character == "'" && !inDouble {
        inSingle.toggle()
      } else if character == "," && !inSingle && !inDouble {
        let meta = String(chars[..<index])
        let title = String(chars[(index + 1)...])
        return (meta, title)
      }
    }
    return (body, "")
  }

  static func attributes(in text: String) -> [String: String] {
    var result: [String: String] = [:]
    let chars = Array(text)
    var index = 0
    func skipSpace() {
      while index < chars.count && chars[index].isWhitespace { index += 1 }
    }
    while index < chars.count {
      skipSpace()
      if index >= chars.count { break }
      let keyStart = index
      while index < chars.count {
        let character = chars[index]
        if character.isLetter || character.isNumber || character == "-" || character == "_" {
          index += 1
        } else {
          break
        }
      }
      if index == keyStart {
        index += 1
        continue
      }
      let key = String(chars[keyStart..<index]).lowercased()
      skipSpace()
      // Not `key=value`. The index already sits on the next token, so start over there.
      // Advancing one character would eat the first letter of that token.
      if index >= chars.count || chars[index] != "=" {
        continue
      }
      index += 1
      skipSpace()
      guard index < chars.count else { break }
      let quote = chars[index]
      if quote == "\"" || quote == "'" {
        index += 1
        var value = ""
        while index < chars.count && chars[index] != quote {
          value.append(chars[index])
          index += 1
        }
        if index < chars.count { index += 1 }
        result[key] = value
      } else {
        var value = ""
        while index < chars.count && !chars[index].isWhitespace && chars[index] != "," {
          value.append(chars[index])
          index += 1
        }
        result[key] = value
      }
    }
    return result
  }

  private static func resolve(_ raw: String, base: URL?) -> String {
    if let url = URL(string: raw), url.scheme != nil { return url.absoluteString }
    if let base, let url = URL(string: raw, relativeTo: base)?.absoluteURL { return url.absoluteString }
    return raw
  }

  private static func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
    }
    return nil
  }

  private static func emptyToNil(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Header values are defaults. An entry that sets the same attribute replaces them.
  private static func catchupHeader(_ attributes: [String: String], existing: IPTVCatchupHeader) -> IPTVCatchupHeader {
    var header = existing
    if let mode = firstNonEmpty(attributes["catchup"], attributes["catchup-type"]) {
      header.mode = mode
    }
    if let days = IPTVCatchup.positiveDays(attributes["catchup-days"]) {
      header.days = days
    }
    if let source = emptyToNil(attributes["catchup-source"]) {
      header.source = source
    }
    if let raw = attributes["catchup-correction"]?.trimmingCharacters(in: .whitespaces), let hours = Double(raw) {
      header.correctionHours = hours
    }
    return header
  }
}

final class IPTVXMLTVParser: NSObject, XMLParserDelegate {
  private let moment: Date
  private let formatter: DateFormatter
  private var namesByChannel: [String: [String]] = [:]
  private var currentChannelID: String?
  private var currentDisplayName = ""
  private var inDisplayName = false
  private var programmeChannel = ""
  private var programmeStart = ""
  private var programmeStop = ""
  private var programmeTitle = ""
  private var programmeCatchupID = ""
  private var inTitle = false
  private(set) var epg = IPTVEPG()

  init(moment: Date = Date()) {
    self.moment = moment
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMddHHmmss"
    self.formatter = formatter
    super.init()
  }

  func parse(_ data: Data) -> IPTVEPG {
    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.parse()
    epg.sortProgrammes()
    return epg
  }

  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
    switch elementName {
    case "channel":
      currentChannelID = attributeDict["id"]
      currentDisplayName = ""
    case "display-name":
      inDisplayName = currentChannelID != nil
      currentDisplayName = ""
    case "programme":
      programmeChannel = attributeDict["channel"] ?? ""
      programmeStart = attributeDict["start"] ?? ""
      programmeStop = attributeDict["stop"] ?? ""
      programmeCatchupID = attributeDict["catchup-id"] ?? ""
      programmeTitle = ""
    case "title":
      inTitle = !programmeChannel.isEmpty
      programmeTitle = ""
    default:
      break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if inDisplayName { currentDisplayName += string }
    if inTitle { programmeTitle += string }
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
    switch elementName {
    case "display-name":
      if let currentChannelID {
        let name = currentDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
          namesByChannel[currentChannelID, default: []].append(name)
        }
      }
      inDisplayName = false
    case "channel":
      currentChannelID = nil
    case "title":
      inTitle = false
    case "programme":
      guard let start = parseDate(programmeStart), let stop = parseDate(programmeStop) else { break }
      let title = programmeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      let names = namesByChannel[programmeChannel] ?? []
      let catchupID = programmeCatchupID.trimmingCharacters(in: .whitespacesAndNewlines)
      epg.add(channelID: programmeChannel, names: names, programme: IPTVProgramme(title: title.isEmpty ? "Programme" : title, start: start, stop: stop, catchupID: catchupID.isEmpty ? nil : catchupID), at: moment)
      programmeChannel = ""
      programmeCatchupID = ""
    default:
      break
    }
  }

  func parserDidEndDocument(_ parser: XMLParser) {
    epg.sortProgrammes()
  }

  /// XMLTV stamps look like `20261011023000 +0000`. The digits are local to that offset.
  func parseDate(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
    let stamp = parts[0]
    guard stamp.count >= 14, let date = formatter.date(from: String(stamp.prefix(14))) else { return nil }
    guard parts.count == 2 else { return date }
    let offset = parseOffset(parts[1])
    return date.addingTimeInterval(TimeInterval(-offset))
  }

  private func parseOffset(_ raw: String) -> Int {
    let zone = raw.trimmingCharacters(in: .whitespaces).uppercased()
    if zone == "Z" || zone == "GMT" || zone == "UTC" { return 0 }
    let sign: Int
    var digits = zone
    if zone.hasPrefix("+") {
      sign = 1
      digits = String(zone.dropFirst())
    } else if zone.hasPrefix("-") {
      sign = -1
      digits = String(zone.dropFirst())
    } else {
      return 0
    }
    guard digits.count >= 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.dropFirst(2).prefix(2)) else { return 0 }
    return sign * ((hours * 60 + minutes) * 60)
  }
}
