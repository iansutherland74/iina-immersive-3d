//
//  LiveCaptionFilter.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Silence gate and hallucination filter for live Whisper captions.
//  Foundation only, so the headless self-test can compile this file.

import Foundation

enum LiveCaptionFilter {
  struct Segment {
    var text: String
    var duration: Double
  }

  /// Whole-window or 30 ms frame RMS below this is not speech. The window is
  /// not sent to Whisper.
  static let silenceRMS: Float = 0.008
  /// Above the silence gate, but still quiet enough that a known outro or a
  /// repeated line is not trusted. Normal speech sits above this.
  static let lowEnergyRMS: Float = 0.02
  /// Whisper's silence hallucinations are a brief timestamp. A longer line at
  /// speech energy is kept, including when the next window repeats it.
  static let shortSegmentSeconds: Double = 2.5

  private static let sampleRate = 16_000
  private static let frameSamples = sampleRate * 30 / 1000

  /// Phrases Whisper emits on silence, music, and noise. Stored after
  /// `normalize`, so matching ignores case and punctuation.
  private static let phrases: [String] = [
    "thank you for watching",
    "thanks for watching",
    "please like and subscribe",
    "like and subscribe",
    "please subscribe",
    "thanks for listening",
    "thank you for listening",
    "see you next time",
    "see you in the next video",
    "subtitles by the amara.org community",
    "subtitles by amara.org",
    "www.youtube.com",
    "thank you",
    "thanks",
    "goodbye",
    "bye bye",
    "bye",
    "you"
  ].map { normalize($0) }.sorted { $0.count > $1.count }

  static func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var acc: Float = 0
    for value in samples {
      acc += value * value
    }
    return (acc / Float(samples.count)).squareRoot()
  }

  /// True when any 30 ms frame has speech energy. A short word in a quiet
  /// window still counts, and a near-silent window does not.
  static func shouldTranscribe(_ samples: [Float]) -> Bool {
    let count = samples.count
    guard count > 0 else { return false }
    if count < frameSamples {
      return rms(samples) >= silenceRMS
    }
    var offset = 0
    while offset + frameSamples <= count {
      if frameRMS(samples, start: offset, count: frameSamples) >= silenceRMS {
        return true
      }
      offset += frameSamples
    }
    let tail = count - offset
    if tail >= frameSamples / 2 {
      return frameRMS(samples, start: offset, count: tail) >= silenceRMS
    }
    return false
  }

  /// Lowercase, punctuation and symbols removed, whitespace collapsed.
  static func normalize(_ text: String) -> String {
    var words: [String] = []
    var word = ""
    func flush() {
      if !word.isEmpty {
        words.append(word)
        word = ""
      }
    }
    for scalar in text.lowercased().unicodeScalars {
      if CharacterSet.whitespacesAndNewlines.contains(scalar) {
        flush()
        continue
      }
      if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
        flush()
        continue
      }
      word.unicodeScalars.append(scalar)
    }
    flush()
    return words.joined(separator: " ")
  }

  /// Drops known outro phrases and repeated identical segments when the
  /// segment is shorter than `shortSegmentSeconds` or `energy` is below
  /// `lowEnergyRMS`. `previous` is the normalized text of the last segment
  /// that was kept, including from an earlier window.
  static func filter(_ segments: [Segment], energy: Float, previous: inout String) -> [Segment] {
    var kept: [Segment] = []
    var prior = previous
    let low = !energy.isFinite || energy < lowEnergyRMS
    for segment in segments {
      let cleaned = prepare(segment.text)
      let key = normalize(cleaned)
      if key.isEmpty {
        continue
      }
      let duration = segment.duration.isFinite ? max(0, segment.duration) : 0
      let short = duration < shortSegmentSeconds
      let repeated = !prior.isEmpty && key == prior
      if (isHallucination(key) || repeated) && (short || low) {
        continue
      }
      prior = key
      var copy = segment
      copy.text = cleaned
      kept.append(copy)
    }
    previous = prior
    return kept
  }

  private static func frameRMS(_ samples: [Float], start: Int, count: Int) -> Float {
    guard count > 0 else { return 0 }
    var acc: Float = 0
    let end = start + count
    for index in start..<end {
      let value = samples[index]
      acc += value * value
    }
    return (acc / Float(count)).squareRoot()
  }

  private static func prepare(_ raw: String) -> String {
    var text = raw.replacingOccurrences(of: "[BLANK_AUDIO]", with: "", options: .caseInsensitive)
    while let start = text.range(of: "<|"), let end = text.range(of: "|>", range: start.upperBound..<text.endIndex) {
      text.removeSubrange(start.lowerBound..<end.upperBound)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The segment is one known phrase, or several of them joined ("Thank you. Bye.").
  private static func isHallucination(_ key: String) -> Bool {
    guard !key.isEmpty else { return false }
    return covers(key)
  }

  private static func covers(_ key: String) -> Bool {
    for phrase in phrases {
      if key == phrase {
        return true
      }
      let prefix = phrase + " "
      if key.hasPrefix(prefix) {
        let rest = String(key.dropFirst(prefix.count))
        if covers(rest) {
          return true
        }
      }
    }
    return false
  }
}
