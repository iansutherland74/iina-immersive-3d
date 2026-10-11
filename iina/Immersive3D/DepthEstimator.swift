//
//  DepthEstimator.swift
//  iina
//
//  Live monocular depth for the Immersive 3D fork of IINA.
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  Depth Anything V2 Small is a separate work (Lihe Yang et al., Apache-2.0).
//  This file does not vendor model weights.

import Cocoa
import CoreML
import CoreImage
import CoreVideo

let immersiveLog = Logger.makeSubsystem("immersive3d", ["cube.transparent"])

func log3D(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
  Logger.log(message(), level: level, subsystem: immersiveLog)
}

/// Where a depth `.mlpackage` may live. Weights are not in git.
///
/// `IINA_DEPTH_MODEL` overrides the settings picker. Otherwise the picker
/// selects Depth Anything V2 Small (default) or Depth Anything 3 Small, and
/// the first existing package in `packageNames` wins. A later name with the
/// same family prefix is used only when none of the preferred names exist.
enum DepthModelLocator {
  enum Kind: Int {
    case v2Small = 0
    case da3Small = 1

    var title: String {
      switch self {
      case .v2Small: return "Depth Anything V2 Small"
      case .da3Small: return "Depth Anything 3 Small"
      }
    }

    var familyPrefix: String {
      switch self {
      case .v2Small: return "DepthAnythingV2"
      case .da3Small: return "DepthAnything3"
      }
    }

    /// Preferred names, fastest / best-known package first.
    var packageNames: [String] {
      switch self {
      case .v2Small:
        return [
          "DepthAnythingV2SmallF16-364x280.mlpackage",
          "DepthAnythingV2SmallF16.mlpackage",
          "DepthAnythingV2SmallF16P6.mlpackage"
        ]
      case .da3Small:
        return [
          "DepthAnything3SmallF16-364x280.mlpackage",
          "DepthAnything3SmallF16-504x504.mlpackage",
          "DepthAnything3SmallF16.mlpackage"
        ]
      }
    }

    var missingHelp: String {
      switch self {
      case .v2Small:
        return """
        Immersive 3D is set to Depth Anything V2 Small. On your Mac, run \
        other/fetch_depth_model.sh (Apple's 518×392 Core ML package) or \
        other/convert_depth_anything_v2.py (364×280, better for real time). \
        Packages load from ~/Library/Application Support/com.colliderli.iina/Models/ \
        or from IINA_DEPTH_MODEL. Weights are not included in this fork.
        """
      case .da3Small:
        return """
        Immersive 3D is set to Depth Anything 3 Small. There is no official \
        Core ML build. On your Mac, run other/convert_depth_anything_3.py \
        and leave the .mlpackage in \
        ~/Library/Application Support/com.colliderli.iina/Models/. \
        Weights are not included in this fork.
        """
      }
    }
  }

  static func currentKind() -> Kind {
    Kind(rawValue: Preference.integer(for: .immersive3DDepthModel)) ?? .v2Small
  }

  static func searchDirectories() -> [URL] {
    var dirs: [URL] = []
    if let resources = Bundle.main.resourceURL {
      dirs.append(resources)
    }
    dirs.append(Utility.appSupportDirUrl.appendingPathComponent("Models", isDirectory: true))
    if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      dirs.append(appSupport.appendingPathComponent("IINA/Models", isDirectory: true))
    }
    return dirs
  }

  static func candidateURLs(for kind: Kind) -> [URL] {
    var urls: [URL] = []
    for name in kind.packageNames {
      for dir in searchDirectories() {
        urls.append(dir.appendingPathComponent(name))
      }
    }
    return urls
  }

  /// `nil` when nothing matches. A set but missing `IINA_DEPTH_MODEL` does not fall through.
  static func locate(kind: Kind) -> URL? {
    if let override = ProcessInfo.processInfo.environment["IINA_DEPTH_MODEL"], !override.isEmpty {
      let url = URL(fileURLWithPath: override)
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    if let exact = candidateURLs(for: kind).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
      return exact
    }
    let preferred = Set(kind.packageNames)
    for dir in searchDirectories() {
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
      let extras = names.filter { name in
        name.hasPrefix(kind.familyPrefix) && name.hasSuffix(".mlpackage") && !preferred.contains(name)
      }.sorted()
      if let name = extras.first {
        return dir.appendingPathComponent(name)
      }
    }
    return nil
  }

  static var environmentOverride: String? {
    let value = ProcessInfo.processInfo.environment["IINA_DEPTH_MODEL"] ?? ""
    return value.isEmpty ? nil : value
  }
}

struct DepthImage {
  var pixels: [Float]
  var width: Int
  var height: Int
  var serial: UInt64
}

/// Runs the selected depth model on the Neural Engine / GPU and temporally smooths the map.
///
/// Depth Anything V2 Small is the default. Apple's published package is a fixed
/// 518×392 RGB input with a float16 grayscale `depth` output (Core ML 6, macOS 13+).
/// A model converted at 364×280 is preferred when its feature description allows that size.
/// Depth Anything 3 Small is loaded the same way when that package is selected in settings.
final class DepthEstimator {
  static let shared = DepthEstimator()

  /// Real-time size used when the loaded model accepts a flexible input.
  static let realtimeWidth = 364
  static let realtimeHeight = 280

  private let queue = DispatchQueue(label: "com.colliderli.iina.depth", qos: .userInitiated)
  private let lock = NSLock()
  private var model: MLModel?
  private var inputName = "image"
  private var outputName = "depth"
  private var inputWidth = 0
  private var inputHeight = 0
  private var inputPixelFormat: OSType = kCVPixelFormatType_32ARGB
  private var inputBuffer: CVPixelBuffer?
  private let ciContext = CIContext(options: [.cacheIntermediates: false])
  private var loadState: LoadState = .idle
  private var loadGeneration: UInt64 = 0
  private var generation: UInt64 = 0
  private var inFlight = Set<ObjectIdentifier>()
  private var filters: [ObjectIdentifier: DepthTemporalFilter] = [:]
  private var results: [ObjectIdentifier: DepthImage] = [:]
  private var didAlert = false

  private enum LoadState {
    case idle
    case loading
    case ready
    case failed
  }

  private init() {}

  func ensureLoaded() {
    lock.lock()
    if loadState == .failed {
      loadState = .idle
      didAlert = false
    }
    guard loadState == .idle else {
      lock.unlock()
      return
    }
    let ticket = loadGeneration
    lock.unlock()
    queue.async { [weak self] in
      self?.loadModel(ticket: ticket)
    }
  }

  /// Drop the loaded network and load whatever the settings picker currently names.
  func reload() {
    lock.lock()
    loadGeneration &+= 1
    generation &+= 1
    filters.removeAll()
    results.removeAll()
    model = nil
    inputWidth = 0
    inputHeight = 0
    inputBuffer = nil
    loadState = .idle
    didAlert = false
    let ticket = loadGeneration
    lock.unlock()
    queue.async { [weak self] in
      self?.loadModel(ticket: ticket)
    }
  }

  func inputSize() -> (width: Int, height: Int)? {
    lock.lock()
    defer { lock.unlock() }
    guard loadState == .ready, inputWidth > 0, inputHeight > 0 else { return nil }
    return (inputWidth, inputHeight)
  }

  func isReady() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return loadState == .ready
  }

  func resetAll() {
    lock.lock()
    generation &+= 1
    filters.removeAll()
    results.removeAll()
    lock.unlock()
  }

  /// Drop the job when one is already running for `token`. Completion runs on the depth queue.
  func submit(topDownRGBA: [UInt8], width: Int, height: Int, token: ObjectIdentifier, whenReady: @escaping () -> Void) {
    lock.lock()
    guard loadState == .ready, model != nil else {
      lock.unlock()
      return
    }
    if inFlight.contains(token) {
      lock.unlock()
      return
    }
    inFlight.insert(token)
    let generation = self.generation
    lock.unlock()

    let pixels = topDownRGBA
    queue.async { [weak self] in
      guard let self else { return }
      defer {
        self.lock.lock()
        self.inFlight.remove(token)
        self.lock.unlock()
      }
      self.lock.lock()
      let stillCurrent = generation == self.generation
      self.lock.unlock()
      guard stillCurrent else { return }
      guard let depth = self.predict(topDownRGBA: pixels, width: width, height: height, token: token) else { return }
      self.lock.lock()
      guard generation == self.generation else {
        self.lock.unlock()
        return
      }
      let serial = (self.results[token]?.serial ?? 0) &+ 1
      self.results[token] = DepthImage(pixels: depth.pixels, width: depth.width, height: depth.height, serial: serial)
      self.lock.unlock()
      whenReady()
    }
  }

  func latestIfNew(token: ObjectIdentifier, since serial: UInt64) -> DepthImage? {
    lock.lock()
    defer { lock.unlock() }
    guard let image = results[token], image.serial != serial else { return nil }
    return image
  }

  // MARK: - Load

  private func loadModel(ticket: UInt64) {
    lock.lock()
    if ticket != loadGeneration || loadState != .idle {
      lock.unlock()
      return
    }
    loadState = .loading
    lock.unlock()

    let kind = DepthModelLocator.currentKind()
    guard let url = DepthModelLocator.locate(kind: kind) else {
      lock.lock()
      let current = ticket == loadGeneration
      if current {
        loadState = .failed
      }
      lock.unlock()
      guard current else { return }
      let paths = DepthModelLocator.candidateURLs(for: kind).map(\.path).joined(separator: "\n")
      let override = DepthModelLocator.environmentOverride.map { "\nIINA_DEPTH_MODEL=\($0)" } ?? ""
      log3D("Depth model not found for \(kind.title).\(override)\nLooked in:\n\(paths)", level: .error)
      alertOnce(title: "Depth model not found", body: kind.missingHelp + override)
      return
    }

    do {
      let config = MLModelConfiguration()
      config.computeUnits = .all
      let loaded = try MLModel(contentsOf: url, configuration: config)
      let description = loaded.modelDescription
      let input = description.inputDescriptionsByName["image"]
        ?? description.inputDescriptionsByName["input"]
        ?? description.inputDescriptionsByName.values.first
      let output = description.outputDescriptionsByName["depth"]
        ?? description.outputDescriptionsByName["output"]
        ?? description.outputDescriptionsByName.values.first
      guard let input, let output, let constraint = input.imageConstraint else {
        throw DepthModelError.unexpectedInterface
      }
      let size = Self.chooseInputSize(constraint)
      let format = Self.pixelFormat(for: constraint)
      var buffer: CVPixelBuffer?
      let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
      ]
      let status = CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height, format, attrs as CFDictionary, &buffer)
      guard status == kCVReturnSuccess, let buffer else {
        throw DepthModelError.pixelBuffer
      }
      lock.lock()
      guard ticket == loadGeneration else {
        lock.unlock()
        return
      }
      model = loaded
      inputName = input.name
      outputName = output.name
      inputWidth = size.width
      inputHeight = size.height
      inputPixelFormat = format
      inputBuffer = buffer
      loadState = .ready
      lock.unlock()
      let override = DepthModelLocator.environmentOverride == nil ? "" : " (IINA_DEPTH_MODEL override)"
      log3D("Loaded \(kind.title)\(override): \(url.lastPathComponent) input \(size.width)x\(size.height) \(input.name) -> \(output.name), compute units all (ANE/GPU/CPU)", level: .warning)
    } catch {
      lock.lock()
      let current = ticket == loadGeneration
      if current {
        loadState = .failed
      }
      lock.unlock()
      guard current else { return }
      log3D("Failed to load depth model at \(url.path): \(error.localizedDescription)", level: .error)
      alertOnce(
        title: "Depth model could not be loaded",
        body: "\(url.path)\n\n\(error.localizedDescription)\n\nThese packages need macOS 13 or later when the output is float16 grayscale."
      )
    }
  }

  /// Fixed models (Apple's published package is 518×392) keep their declared size.
  /// Flexible models are pinned near 364×280, on multiples of 14 when the range allows.
  static func chooseInputSize(_ constraint: MLImageConstraint) -> (width: Int, height: Int) {
    let flexibility = constraint.sizeConstraint
    switch flexibility.type {
    case .enumerated:
      let sizes = flexibility.enumeratedImageSizes
      if let exact = sizes.first(where: { $0.pixelsWide == realtimeWidth && $0.pixelsHigh == realtimeHeight }) {
        return (exact.pixelsWide, exact.pixelsHigh)
      }
      if let closest = sizes.min(by: { lhs, rhs in
        let ld = abs(lhs.pixelsWide * lhs.pixelsHigh - realtimeWidth * realtimeHeight)
        let rd = abs(rhs.pixelsWide * rhs.pixelsHigh - realtimeWidth * realtimeHeight)
        return ld < rd
      }) {
        return (closest.pixelsWide, closest.pixelsHigh)
      }
    case .range:
      let width = snapToPatch(realtimeWidth, range: flexibility.pixelsWideRange)
      let height = snapToPatch(realtimeHeight, range: flexibility.pixelsHighRange)
      return (width, height)
    case .unspecified:
      break
    @unknown default:
      break
    }
    if constraint.pixelsWide > 0 && constraint.pixelsHigh > 0 {
      return (constraint.pixelsWide, constraint.pixelsHigh)
    }
    return (realtimeWidth, realtimeHeight)
  }

  private static func snapToPatch(_ preferred: Int, range: NSRange) -> Int {
    let lower = max(range.location, 14)
    let upper: Int
    if range.length <= 0 || range.length >= 100_000 {
      upper = max(lower, preferred)
    } else {
      upper = range.location + range.length - 1
    }
    var value = min(max(preferred, lower), max(lower, upper))
    let snapped = max((value / 14) * 14, 14)
    if snapped >= lower && snapped <= upper {
      value = snapped
    }
    return value
  }

  private static func pixelFormat(for constraint: MLImageConstraint) -> OSType {
    let format = constraint.pixelFormatType
    let known: Set<OSType> = [
      kCVPixelFormatType_32ARGB,
      kCVPixelFormatType_32BGRA
    ]
    if known.contains(format) {
      return format
    }
    // Apple's sample fills a 32ARGB buffer and lets Core ML convert to RGB.
    return kCVPixelFormatType_32ARGB
  }

  // MARK: - Inference

  private func predict(topDownRGBA: [UInt8], width: Int, height: Int, token: ObjectIdentifier) -> (pixels: [Float], width: Int, height: Int)? {
    lock.lock()
    let model = self.model
    let inputName = self.inputName
    let outputName = self.outputName
    let buffer = self.inputBuffer
    let targetW = self.inputWidth
    let targetH = self.inputHeight
    lock.unlock()
    guard let model, let buffer else { return nil }
    guard render(topDownRGBA, width: width, height: height, into: buffer, targetWidth: targetW, targetHeight: targetH) else {
      return nil
    }
    do {
      let input = MLFeatureValue(pixelBuffer: buffer)
      let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: input])
      let result = try model.prediction(from: provider)
      guard let feature = result.featureValue(for: outputName) ?? result.featureValue(for: "depth") else {
        log3D("Depth model returned no '\(outputName)' feature", level: .error)
        return nil
      }
      guard let extracted = Self.extractDepth(feature, context: ciContext) else {
        log3D("Could not read the depth output", level: .error)
        return nil
      }
      lock.lock()
      var filter = filters[token] ?? DepthTemporalFilter()
      let smoothed = filter.smooth(extracted.pixels)
      filters[token] = filter
      lock.unlock()
      return (smoothed, extracted.width, extracted.height)
    } catch {
      log3D("Depth inference failed: \(error.localizedDescription)", level: .error)
      return nil
    }
  }

  private func render(_ rgba: [UInt8], width: Int, height: Int, into buffer: CVPixelBuffer, targetWidth: Int, targetHeight: Int) -> Bool {
    guard width > 0, height > 0, rgba.count >= width * height * 4 else { return false }
    let data = Data(rgba)
    guard let provider = CGDataProvider(data: data as CFData) else { return false }
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let cgImage = CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: info,
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent
    ) else { return false }
    var image = CIImage(cgImage: cgImage)
    if width != targetWidth || height != targetHeight {
      let sx = CGFloat(targetWidth) / CGFloat(width)
      let sy = CGFloat(targetHeight) / CGFloat(height)
      image = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }
    ciContext.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight), colorSpace: CGColorSpaceCreateDeviceRGB())
    return true
  }

  static func extractDepth(_ feature: MLFeatureValue, context: CIContext) -> (pixels: [Float], width: Int, height: Int)? {
    if let array = feature.multiArrayValue {
      return extract(array)
    }
    if let buffer = feature.imageBufferValue {
      return extract(buffer, context: context)
    }
    return nil
  }

  private static func extract(_ array: MLMultiArray) -> (pixels: [Float], width: Int, height: Int)? {
    let shape = array.shape.map { $0.intValue }
    let count = array.count
    guard count > 0, count < 4_000_000 else { return nil }
    var pixels = [Float](repeating: 0, count: count)
    switch array.dataType {
    case .float32:
      let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count)
      pixels.withUnsafeMutableBufferPointer { dest in
        dest.baseAddress!.update(from: pointer, count: count)
      }
    case .float16:
      let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: count)
      for i in 0..<count {
        pixels[i] = Float(pointer[i])
      }
    case .double:
      let pointer = array.dataPointer.bindMemory(to: Double.self, capacity: count)
      for i in 0..<count {
        pixels[i] = Float(pointer[i])
      }
    default:
      for i in 0..<count {
        pixels[i] = array[i].floatValue
      }
    }
    if shape.count >= 2 {
      let width = shape[shape.count - 1]
      let height = shape[shape.count - 2]
      if width > 0, height > 0, width * height == count {
        return (pixels, width, height)
      }
    }
    return (pixels, count, 1)
  }

  private static func extract(_ buffer: CVPixelBuffer, context: CIContext) -> (pixels: [Float], width: Int, height: Int)? {
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    guard width > 0, height > 0, width * height < 4_000_000 else { return nil }
    let format = CVPixelBufferGetPixelFormatType(buffer)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    if format == kCVPixelFormatType_OneComponent16Half || format == kCVPixelFormatType_DisparityFloat16 || format == kCVPixelFormatType_DepthFloat16 {
      var pixels = [Float](repeating: 0, count: width * height)
      for y in 0..<height {
        let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
        for x in 0..<width {
          pixels[y * width + x] = Float(Float16(bitPattern: row[x]))
        }
      }
      return (pixels, width, height)
    }
    if format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_DisparityFloat32 || format == kCVPixelFormatType_DepthFloat32 {
      var pixels = [Float](repeating: 0, count: width * height)
      for y in 0..<height {
        let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
        for x in 0..<width {
          pixels[y * width + x] = row[x]
        }
      }
      return (pixels, width, height)
    }
    if format == kCVPixelFormatType_OneComponent8 {
      var pixels = [Float](repeating: 0, count: width * height)
      for y in 0..<height {
        let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
          pixels[y * width + x] = Float(row[x]) / 255
        }
      }
      return (pixels, width, height)
    }
    // Unknown layout: ask Core Image for a single-float bitmap. This quantizes
    // some formats, which is still usable after per-frame normalization.
    var pixels = [Float](repeating: 0, count: width * height)
    let image = CIImage(cvPixelBuffer: buffer)
    pixels.withUnsafeMutableBytes { raw in
      guard let address = raw.baseAddress else { return }
      context.render(image, toBitmap: address, rowBytes: width * MemoryLayout<Float>.size, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .Rf, colorSpace: nil)
    }
    return (pixels, width, height)
  }

  private func alertOnce(title: String, body: String) {
    lock.lock()
    if didAlert {
      lock.unlock()
      return
    }
    didAlert = true
    lock.unlock()
    DispatchQueue.main.async {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = title
      alert.informativeText = body
      alert.runModal()
    }
  }
}

private enum DepthModelError: LocalizedError {
  case unexpectedInterface
  case pixelBuffer

  var errorDescription: String? {
    switch self {
    case .unexpectedInterface:
      return "The model has no image input named image/input and no depth output."
    case .pixelBuffer:
      return "Could not allocate the model input pixel buffer."
    }
  }
}

/// Geometric smoothing of normalized depth: prev^(1-a) * curr^a, which is
/// prev * (curr/prev)^a. Large jumps reset instead of blending across a cut.
struct DepthTemporalFilter {
  var previous: [Float]?
  var emaMin: Float = 0
  var emaMax: Float = 1
  var hasRange = false
  /// Higher follows the new frame faster. 0.42 damps flicker without a long smear.
  var responsiveness: Float = 0.42

  mutating func smooth(_ raw: [Float]) -> [Float] {
    guard !raw.isEmpty else { return raw }
    var lo = Float.greatestFiniteMagnitude
    var hi = -Float.greatestFiniteMagnitude
    let step = max(raw.count / 4096, 1)
    var index = 0
    while index < raw.count {
      let value = raw[index]
      if value.isFinite {
        lo = min(lo, value)
        hi = max(hi, value)
      }
      index += step
    }
    if !lo.isFinite || !hi.isFinite {
      return previous ?? raw
    }
    if !hasRange {
      emaMin = lo
      emaMax = hi
      hasRange = true
    } else {
      let span = max(emaMax - emaMin, 1e-4)
      let overlap = min(hi, emaMax) - max(lo, emaMin)
      if overlap < 0.15 * span {
        emaMin = lo
        emaMax = hi
      } else {
        emaMin = emaMin * 0.9 + lo * 0.1
        emaMax = emaMax * 0.9 + hi * 0.1
      }
    }
    let span = max(emaMax - emaMin, 1e-4)
    // Depth Anything V2 and V3 emit relative depth where larger means farther.
    // The stereo shader treats 1 as near, so store the complement. Invert Depth
    // in the menu flips it again if a model is disparity instead of depth.
    var normalized = [Float](repeating: 0, count: raw.count)
    for i in 0..<raw.count {
      let value = raw[i].isFinite ? raw[i] : emaMin
      let unit = min(max((value - emaMin) / span, 0), 1)
      normalized[i] = 1 - unit
    }
    guard var prior = previous, prior.count == normalized.count else {
      previous = normalized
      return normalized
    }
    var accum: Float = 0
    var samples = 0
    index = 0
    while index < normalized.count {
      accum += abs(normalized[index] - prior[index])
      samples += 1
      index += step
    }
    let meanDelta = accum / Float(max(samples, 1))
    if meanDelta > 0.28 {
      previous = normalized
      return normalized
    }
    let alpha = responsiveness
    for i in 0..<normalized.count {
      let current = max(normalized[i], 1e-4)
      let old = max(prior[i], 1e-4)
      let ratio = current / old
      let blended = old * pow(ratio, alpha)
      let value = min(max(blended, 0), 1)
      normalized[i] = value
      prior[i] = value
    }
    previous = prior
    return normalized
  }
}
