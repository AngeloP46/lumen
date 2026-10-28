import CoreImage
import CoreML
import Foundation
import os
import ImageIO

/// AI Denoise: SCUNet's real-noise model (cszn/SCUNet, Apache-2.0), converted to Core ML in CI
/// (.github/ci/denoise-convert, 256 x 256 tiles since 23 Oct (512 before), float16), run on the GPU. History (20 Oct): SCUNet on the Neural
/// Engine never got a quarter through a 24 MP photo in 100 s (its attention layers don't suit it); NAFNet-SIDD was
/// quick there but left half the noise and wrecked bright tiles (float16 overflow). The owner wants one model that
/// is good and quick, using the phone's chips to the full: SCUNet's quality on the GPU.
///
/// The full-size photo as the camera made it (no heals) is cleaned once, tile by tile, row of tiles by row of tiles,
/// and what the model took out (the noise, in linear light) is kept on disk per photo (`DenoiseStore`). Every decode
/// takes that noise out again by the AI Denoise amount, so preview, 100 % view, heals, export and thumbnails all see
/// the same cleaned photo, the slider is instant after the first run, and one clean serves HDR on and off (noise lives
/// in the shadows and midtones, where both decodes of a RAW are the same; highlights keep their own pixels).
/// A clean can pause (Lumen leaves the screen, or is swiped away) and continue later from the last finished row.

// MARK: - Shrinking rows into the small copy

/// A pixel value the row shrinker can average.
protocol ShrinkPixel {
    init(averaging value: Float)
    var floatValue: Float { get }
    static var opaque: Self { get }
}
extension UInt16: ShrinkPixel {
    init(averaging value: Float) { self = UInt16(Swift.min(65535, Swift.max(0, value.rounded()))) }
    var floatValue: Float { Float(self) }
    static var opaque: UInt16 { 65535 }
}
extension Float16: ShrinkPixel {
    init(averaging value: Float) { self = Float16(value) }
    var floatValue: Float { Float(self) }
    static var opaque: Float16 { 1 }
}

/// Box-averages full-size RGBA rows, given top to bottom, into a smaller copy written to a file row by row: needs only
/// one small row in memory (21 Oct: the 4096 px copy averaged in one go held ~200 MB during a clean).
final class RowShrinker<P: ShrinkPixel> {
    let width: Int, height: Int, smallWidth: Int, smallHeight: Int
    private let columnOf: [Int]
    private var acc: [Float], hits: [Float]
    private var row = 0, written = 0
    private let handle: FileHandle
    private(set) var failed = false

    init?(width: Int, height: Int, maxEdge: Int, url: URL) {
        guard width > 0, height > 0, maxEdge > 0 else { return nil }
        self.width = width; self.height = height
        let k = min(1, Double(maxEdge) / Double(max(width, height)))
        smallWidth = max(1, Int((Double(width) * k).rounded())); smallHeight = max(1, Int((Double(height) * k).rounded()))
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        let sw = smallWidth
        // Use the actual rounded output dimensions for bin assignment too. Using the unrounded scale left
        // the last bin empty for common shapes (6000 x 4000 -> 4096 x 2731), writing RGB 1 into a noise map.
        columnOf = (0..<width).map { min(sw - 1, $0 * sw / width) }
        acc = [Float](repeating: 0, count: smallWidth * 3); hits = [Float](repeating: 0, count: smallWidth)
    }

    /// The small row a full row `y` falls into.
    private func smallRow(_ y: Int) -> Int { min(smallHeight - 1, y * smallHeight / height) }

    private func flush() {
        guard written < smallHeight else { return }
        var out = [P](repeating: P.opaque, count: smallWidth * 4)
        for x in 0..<smallWidth {
            guard hits[x] > 0 else { failed = true; return }
            for c in 0..<3 { out[x * 4 + c] = P(averaging: acc[x * 3 + c] / hits[x]) }
        }
        if (try? out.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }) == nil { failed = true }
        written += 1
        for i in acc.indices { acc[i] = 0 }
        for i in hits.indices { hits[i] = 0 }
    }

    /// The next full row (width x 4 values).
    func add(_ px: UnsafePointer<P>) {
        if row > 0, smallRow(row) != smallRow(row - 1) { flush() }
        for x in 0..<width {
            let a = columnOf[x], o = x * 4
            acc[a * 3] += px[o].floatValue; acc[a * 3 + 1] += px[o + 1].floatValue; acc[a * 3 + 2] += px[o + 2].floatValue
            hits[a] += 1
        }
        row += 1
    }

    /// After the last row; false if anything couldn't be written.
    func finish() -> Bool {
        flush()
        try? handle.close()
        return !failed && row == height && written == smallHeight
    }
}

// MARK: - Results on disk

enum DenoiseStore {
    nonisolated(unsafe) static var directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumenDenoise")
    /// Changes when the model or the way it is run changes: older results are made again.
    static let modelVersion = "scunet-real-512-gpu-2"
    /// Results since 21 Oct keep the noise taken out (RGBA half floats, linear light, one file for HDR on and off);
    /// older ones are the cleaned photo itself, per HDR mode (`kind` nil), and are still read.
    static let noiseKind = "noise"
    /// The small copy's long edge: as big as the 100 % view's copy, so that view never reads the whole result.
    static let previewEdge = 4096
    /// Version 2 assigns samples using the rounded output dimensions (no empty last row/column).
    static let previewVersion = 2

    struct Info: Codable {
        var model: String
        var scale: Double      // the photo was divided by this before cleaning (HDR values above 1)
        var width: Int
        var height: Int
        var file: String
        var preview: String? = nil
        var previewWidth: Int? = nil
        var previewHeight: Int? = nil
        var kind: String? = nil
        /// The RAW decoder the photo was read with when this was made (`EditSession.decoderTag`); nil for results from
        /// before 23 Oct, which are taken as right.
        var decoder: String? = nil
        var previewVersion: Int? = nil
    }

    /// A clean that paused (Lumen left the screen or was swiped away): its rows so far are in `file`.
    struct Partial: Codable {
        var file: String
        var width: Int
        var height: Int
        var rows: Int
        var scale: Double
        var hdr: Bool
        var model: String
        var photo: String       // the photo's file name, for the library's "Continue" banner
        /// Residual rows only fit the exact decoder that produced them. Unknown older partials restart safely.
        var decoder: String? = nil
    }

    /// The same compatibility gate used before appending any rows to a paused result. Completed legacy results
    /// retain their existing read policy; this stricter rule prevents mixing two decoders in a newly completed file.
    static func canResume(_ partial: Partial, width: Int, height: Int, hdr: Bool, decoder: String) -> Bool {
        partial.width == width && partial.height == height && partial.hdr == hdr && partial.model == modelVersion
            && partial.rows > 0 && partial.rows < height && partial.decoder == decoder
    }

    static func stem(_ photo: URL) -> String { photo.deletingPathExtension().lastPathComponent }
    static func noiseInfoURL(_ photo: URL) -> URL { directory.appendingPathComponent(stem(photo) + "-noise.json") }
    static func partialURL(_ photo: URL) -> URL { directory.appendingPathComponent(stem(photo) + "-noise.partial.json") }
    /// Results before 21 Oct, one per HDR mode.
    static func key(_ photo: URL, hdr: Bool) -> String { stem(photo) + (hdr ? "-hdr" : "-sdr") }
    static func infoURL(_ photo: URL, hdr: Bool) -> URL { directory.appendingPathComponent(key(photo, hdr: hdr) + ".json") }

    private static func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// The result for this photo: the noise kind (any HDR mode), else an older cleaned copy for this mode.
    static func info(_ photo: URL, hdr: Bool, size: CGSize, decoder: String? = nil) -> Info? {
        func valid(_ i: Info?) -> Info? {
            guard let i, i.model == modelVersion, i.width == Int(size.width.rounded()), i.height == Int(size.height.rounded()),
                  // made with another RAW decoder (an iOS update): the noise no longer fits the picture exactly
                  decoder == nil || i.decoder == nil || i.decoder == decoder,
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(i.file).path) else { return nil }
            if ["noise", "rgba16"].contains((i.file as NSString).pathExtension) {
                guard rawFileFits(i.file, width: i.width, height: i.height) else { return nil }
            } else {
                guard legacyImageFits(i.file, width: i.width, height: i.height) else { return nil }
            }
            return i
        }
        return valid(read(noiseInfoURL(photo))) ?? valid(read(infoURL(photo, hdr: hdr)))
    }

    /// The stored image (the noise, or an older cleaned copy) in the working space; nil when there is none. `maxEdge` =
    /// the size the caller needs: the small copy is used when it is big enough. Raw files are read memory-mapped (no
    /// decoding; iOS can drop the pages again); results made before 21 Oct may be 16-bit PNGs.
    static func image(_ photo: URL, hdr: Bool, size: CGSize, maxEdge: CGFloat? = nil, decoder: String? = nil) -> (CIImage, Info)? {
        guard var i = info(photo, hdr: hdr, size: size, decoder: decoder) else { return nil }
        if let maxEdge, maxEdge <= CGFloat(previewEdge) + 1,
           ["noise", "rgba16"].contains((i.file as NSString).pathExtension),
           (!previewFits(i) || maxEdge > CGFloat(max(i.previewWidth ?? 0, i.previewHeight ?? 0)) + 1),
           let bigger = upgradePreview(photo, hdr: hdr, info: i) {
            i = bigger
        }
        func load(_ file: String, width w: Int, height h: Int) -> CIImage? {
            let url = directory.appendingPathComponent(file), size = CGSize(width: w, height: h)
            switch url.pathExtension {
            case "noise":
                guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count == w * h * 8 else { return nil }
                return CIImage(bitmapData: data, bytesPerRow: w * 8, size: size, format: .RGBAh, colorSpace: nil)
            case "rgba16":
                guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count == w * h * 8,
                      let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
                return CIImage(bitmapData: data, bytesPerRow: w * 8, size: size, format: .RGBA16, colorSpace: p3)
            default:
                guard legacyImageFits(file, width: w, height: h), let image = CIImage(contentsOf: url),
                      image.extent.width == CGFloat(w), image.extent.height == CGFloat(h) else { return nil }
                return image
            }
        }
        if let maxEdge, previewFits(i), let p = i.preview, let pw = i.previewWidth, let ph = i.previewHeight,
           maxEdge <= CGFloat(max(pw, ph)) + 1, let small = load(p, width: pw, height: ph) { return (small, i) }
        // A repair that cannot be written, or a preview replaced between lookup and mapping, never means no denoise.
        return load(i.file, width: i.width, height: i.height).map { ($0, i) }
    }

    private static let upgradeLock = NSLock()
    private static func rawFileFits(_ file: String, width: Int, height: Int) -> Bool {
        guard width > 0, height > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path),
              let count = attributes[.size] as? NSNumber else { return false }
        return count.int64Value == Int64(width) * Int64(height) * 8
    }

    private final class LegacyValidation: NSObject {
        let modified: Date, size: Int64, inode: UInt64, width: Int, height: Int, valid: Bool
        init(modified: Date, size: Int64, inode: UInt64, width: Int, height: Int, valid: Bool) {
            self.modified = modified; self.size = size; self.inode = inode
            self.width = width; self.height = height; self.valid = valid
        }
    }
    private static let legacyValidation: NSCache<NSString, LegacyValidation> = {
        let cache = NSCache<NSString, LegacyValidation>(); cache.countLimit = 128; return cache
    }()

    /// Older results are PNGs, not raw residual bytes. A present filename is insufficient: incomplete or wrongly
    /// sized images must not make requested denoise appear available. Header/status checks do not allocate a
    /// full-resolution decoded bitmap. Cache only the answer, invalidated by replacement/size/date changes.
    private static func legacyImageFits(_ file: String, width: Int, height: Int) -> Bool {
        let url = directory.appendingPathComponent(file)
        guard width > 0, height > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 45,
              let modified = attributes[.modificationDate] as? Date,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return false }
        let key = url.path as NSString
        if let hit = legacyValidation.object(forKey: key), hit.modified == modified, hit.size == size,
           hit.inode == inode, hit.width == width, hit.height == height { return hit.valid }
        let valid: Bool = {
            // ImageIO may tolerate a missing PNG end chunk. Cache files are written complete by Lumen;
            // verify its fixed 12-byte IEND too, without reading/decompressing the whole pixel stream.
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(size - 12))) != nil,
                  let tail = try? handle.read(upToCount: 12),
                  tail == Data([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]),
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
                  (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height,
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                  let image = CIImage(contentsOf: url), image.extent.width == CGFloat(width),
                  image.extent.height == CGFloat(height) else { return false }
            return true
        }()
        legacyValidation.setObject(LegacyValidation(modified: modified, size: size, inode: inode,
                                                   width: width, height: height, valid: valid), forKey: key)
        return valid
    }
    private static func previewFits(_ i: Info) -> Bool {
        guard let file = i.preview, let w = i.previewWidth, let h = i.previewHeight,
              w > 0, h > 0, w <= i.width, h <= i.height else { return false }
        if ["noise", "rgba16"].contains((i.file as NSString).pathExtension) {
            return i.previewVersion == previewVersion && rawFileFits(file, width: w, height: h)
        }
        return legacyImageFits(file, width: w, height: h)
    }

    /// Rebuild an old/invalid small copy using the unchanged full-resolution bytes, without running the model.
    /// Rows are mapped/read one at a time; a unique file is completed before its metadata is installed atomically.
    private static func upgradePreview(_ photo: URL, hdr: Bool, info i: Info) -> Info? {
        upgradeLock.lock(); defer { upgradeLock.unlock() }
        let infoFile = i.kind == noiseKind ? noiseInfoURL(photo) : infoURL(photo, hdr: hdr)
        guard let current: Info = read(infoFile), current.file == i.file else { return nil }
        if previewFits(current), max(current.previewWidth ?? 0, current.previewHeight ?? 0) >= min(previewEdge, max(i.width, i.height)) {
            return current
        }
        let fullURL = directory.appendingPathComponent(i.file)
        guard ["noise", "rgba16"].contains(fullURL.pathExtension),
              let data = try? Data(contentsOf: fullURL, options: .alwaysMapped), data.count == i.width * i.height * 8 else { return nil }
        let name = (i.file as NSString).deletingPathExtension + "-preview-v\(previewVersion)-\(UUID().uuidString)." + fullURL.pathExtension
        let url = directory.appendingPathComponent(name)
        func shrink<P: ShrinkPixel>(_ type: P.Type) -> (Int, Int)? {
            guard let shrinker = RowShrinker<P>(width: i.width, height: i.height, maxEdge: previewEdge, url: url) else { return nil }
            data.withUnsafeBytes { raw in
                let px = raw.bindMemory(to: P.self)
                for y in 0..<i.height { autoreleasepool { shrinker.add(px.baseAddress! + y * i.width * 4) } }
            }
            return shrinker.finish() ? (shrinker.smallWidth, shrinker.smallHeight) : nil
        }
        guard let dimensions = fullURL.pathExtension == "noise" ? shrink(Float16.self) : shrink(UInt16.self) else {
            try? FileManager.default.removeItem(at: url); return nil
        }
        var n = current
        let old = n.preview
        n.preview = name; n.previewWidth = dimensions.0; n.previewHeight = dimensions.1; n.previewVersion = previewVersion
        guard let json = try? JSONEncoder().encode(n), (try? json.write(to: infoFile, options: .atomic)) != nil else {
            try? FileManager.default.removeItem(at: url); return nil
        }
        if let old, old != name { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old)) }
        return n
    }

    // Paused cleans

    static func partial(_ photo: URL) -> Partial? { read(partialURL(photo)) }
    /// How far a paused clean of this photo got (0...1), nil when none is paused.
    static func pausedFraction(_ photo: URL) -> Double? {
        partial(photo).map { Double($0.rows) / Double(max(1, $0.height)) }
    }
    /// Every paused clean: the photo's file name and how far it got (the library offers to continue them).
    static func pausedCleans() -> [(photo: String, fraction: Double)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".partial.json") }.compactMap { n in
            guard let p: Partial = read(directory.appendingPathComponent(n)) else { return nil }
            return (p.photo, Double(p.rows) / Double(max(1, p.height)))
        }
    }
    static func dropPartial(_ photo: URL) {
        if let p = partial(photo) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(p.file)) }
        try? FileManager.default.removeItem(at: partialURL(photo))
    }

    // Removing

    private static func removeFiles(of infoFile: URL, keeping keep: Set<String> = []) {
        if let i: Info = read(infoFile) {
            for f in [i.file, i.preview].compactMap({ $0 }) where !keep.contains(f) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(f))
            }
        }
        try? FileManager.default.removeItem(at: infoFile)
    }

    /// Every finished result of this photo (both HDR modes, both kinds), except the files named in `keep`.
    static func removeResults(_ photo: URL, keeping keep: Set<String> = []) {
        upgradeLock.lock(); defer { upgradeLock.unlock() }
        removeFiles(of: noiseInfoURL(photo), keeping: keep)
        for hdr in [false, true] { removeFiles(of: infoURL(photo, hdr: hdr), keeping: keep) }
    }

    /// The photo was removed from the library: its results and any paused clean go too.
    static func remove(_ photo: URL) {
        removeResults(photo)
        dropPartial(photo)
    }

    /// At launch: files no result or paused clean refers to any more are removed, paused cleans older than two weeks
    /// go, and the folder is kept out of iCloud backups (results can be made again).
    static func sweep() {
        upgradeLock.lock(); defer { upgradeLock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        var used = Set<String>()
        for n in names where n.hasSuffix(".json") {
            let url = directory.appendingPathComponent(n)
            if n.hasSuffix(".partial.json") {
                let age = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    .map { Date().timeIntervalSince($0) } ?? 0
                if age > 14 * 86_400 { try? fm.removeItem(at: url); continue }
                if let p: Partial = read(url) { used.insert(p.file) }
            } else if let i: Info = read(url) {
                // a result from an older model or way of running it is never read again: it goes, with its files
                // (300-500 MB each; before 23 Oct they stayed for ever)
                if i.model != modelVersion { try? fm.removeItem(at: url); continue }
                used.insert(i.file); if let p = i.preview { used.insert(p) }
            }
        }
        for n in names where !n.hasSuffix(".json") && !used.contains(n) {
            try? fm.removeItem(at: directory.appendingPathComponent(n))
        }
    }
}

// MARK: - Cleaning

/// How a clean ended.
enum DenoiseOutcome {
    case done
    /// Stopped by `pause`: the rows so far are kept and the next clean of this photo continues from there.
    case paused
    /// Stopped by `cancelled`: nothing kept.
    case cancelled
    case failed
}

extension EditSession {
    /// The model (compiled by CI into the app as Denoise.mlmodelc). Tests point `LUMEN_DENOISE_MODEL` at one.
    nonisolated(unsafe) static var denoiseModelURL: URL? = {
        if let p = ProcessInfo.processInfo.environment["LUMEN_DENOISE_MODEL"] { return URL(fileURLWithPath: p) }
        return Bundle.main.url(forResource: "Denoise", withExtension: "mlmodelc")
    }()
    /// The model on the GPU. `LUMEN_DENOISE_UNITS=cpu` (CI: the Mac's virtual GPU ran out of memory at 24 MP) uses the CPU.
    private static let denoiseModel = LoadedModel<MLModel> {
        guard let url = denoiseModelURL else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = ProcessInfo.processInfo.environment["LUMEN_DENOISE_UNITS"] == "cpu" ? .cpuOnly : .cpuAndGPU
        // float16 sums on the GPU: faster; SCUNet's values stay small (largest ~100 on a test tile), and every tile is
        // checked against its input anyway
        cfg.allowLowPrecisionAccumulationOnGPU = true
        return try? MLModel(contentsOf: url, configuration: cfg)
    }
    /// True while the model is loaded and has run one tile.
    nonisolated(unsafe) static var denoiseWarm = false
    /// Loads the model and runs one blank tile, so the GPU's one-off setup (owner's phone, 0.1.388: 10 s load + 10 s
    /// first tile) happens while Detail is open, before the button is tapped. Returns the seconds it took (0: it was
    /// ready already).
    @discardableResult
    static func warmDenoise() -> Double {
        if denoiseWarm { return 0 }
        let t0 = Date()
        guard let model = denoiseModel.model,
              let shape = model.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint?.shape,
              let blank = try? MLMultiArray(shape: shape, dataType: .float16),
              let features = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: blank)]) else { return 0 }
        memset(blank.dataPointer, 0, blank.count * 2)
        _ = try? model.prediction(from: features)
        denoiseWarm = true
        return Date().timeIntervalSince(t0)
    }
    /// The same model on the CPU (full precision), for a tile the GPU got wrong.
    private static let denoiseCPU = LoadedModel<MLModel> {
        guard let url = denoiseModelURL else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        return try? MLModel(contentsOf: url, configuration: cfg)
    }
    /// One clean at a time, whoever asks (the editor, a batch from the library, an export).
    private static let denoiseJob = NSLock()
    /// Tests: read the photo strip by strip even when there is memory to read it whole.
    nonisolated(unsafe) static var denoiseForceStrips = false
    /// Memory Lumen may still use before iOS closes it (MB); unlimited on the Mac.
    static var availableMemoryMB: Int {
        #if os(iOS)
        return Int(os_proc_available_memory() / 1_048_576)
        #else
        return 1 << 20
        #endif
    }
    /// What the last clean measured (seconds), for the diagnostics log.
    nonisolated(unsafe) static var denoiseTimings = ""
    /// Only looks for the model's files (the Detail panel asks while drawing).
    static var hasDenoiseModel: Bool { modelFilesExist(denoiseModelURL) }
    /// Lets go of the model. Only for a memory warning: Core ML does not give the model's memory back when it is let go
    /// (owner's phone, 0.1.599: ~130 MB of ~1 GB came back, and loading the model again took another ~1.1 GB on top, so
    /// two loads in a session closed Lumen), so the loaded model is kept for the session and used again.
    static func releaseDenoiseModel() { denoiseModel.release(); denoiseCPU.release(); denoiseWarm = false }
    /// The CPU copy only needs to live as long as the tiles it redoes.
    static func releaseDenoiseFallback() { denoiseCPU.release() }

    /// Whether this photo has been cleaned (any HDR mode since 21 Oct).
    var hasDenoised: Bool { DenoiseStore.info(originalURL, hdr: hdrDecode, size: nativeSize, decoder: decoderTag) != nil }

    /// sRGB / Display P3 encoded value to linear light (a table for 0...1, the formula outside it).
    private static let linearTable: [Float] = (0...4096).map { i in
        let x = Float(i) / 4096
        return x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4)
    }
    @inline(__always) private static func linear(_ x: Float) -> Float {
        if x >= 0 && x <= 1 {
            let f = x * 4096, i = Int(f), t = f - Float(i)
            return i >= 4096 ? linearTable[4096] : linearTable[i] + (linearTable[i + 1] - linearTable[i]) * t
        }
        let a = abs(x)
        let l = a <= 0.04045 ? a / 12.92 : powf((a + 0.055) / 1.055, 2.4)
        return x < 0 ? -l : l
    }

    /// Cleans the full-size photo (as the camera made it, without heals) and keeps the noise it took out. Slow (about a
    /// minute for 24 MP on an iPhone 17 Pro Max): call off the main thread. `progress` gets 0...1 as tiles finish.
    /// Before every tile `pause` and `cancelled` are asked: a pause keeps the rows so far and the next clean of this
    /// photo (also after Lumen was swiped away) continues from there; a cancel drops them. iOS doesn't allow GPU work
    /// in the background, so the app pauses the clean when it leaves the screen. `log` gets the load time and the
    /// first tiles' times straight away, so even a run that never finishes shows the phone's speed in diagnostics.
    func makeDenoised(progress: ((Double) -> Void)? = nil, pause: (() -> Bool)? = nil, cancelled: (() -> Bool)? = nil,
                      log: ((String) -> Void)? = nil) -> DenoiseOutcome {
        if hasDenoised { return .done }
        guard Self.denoiseJob.try() else { log?("denoise: another clean is running"); return .failed }
        defer { Self.denoiseJob.unlock() }
        let t0 = Date()
        let model = Self.denoiseModel.model
        let loadSeconds = Date().timeIntervalSince(t0)
        log?(String(format: "denoise model %@ in %.1f s", model == nil ? "failed to load" : "loaded", loadSeconds))
        guard let model,
              let shape = model.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint?.shape,
              shape.count == 4 else { return .failed }
        let T = shape[3].intValue
        // 16 px of context each side (was 32; 20 Oct, whole photo in PyTorch: 60 dB from the 32 px result, no step at any
        // tile boundary): 117 tiles for 24 MP instead of 126
        let margin = 16, step = T - 2 * margin
        guard step > 0, let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return .failed }
        Self.healProbe?("denoise: start")

        // 1. the photo, divided by its bright end (HDR highlights above 1), read through a decoder of its own: the
        // photo's RAW decoder keeps a full-size decode cached for as long as the photo stays open (owner's phone,
        // 21 Oct: ~1 GB more after a clean, then Heal on top closed Lumen)
        let reader = EditSession(url: originalURL, expandHDR: hdrDecode)
        guard let camera = (reader ?? self).decodeCameraLocked(maxEdge: nil) else { return .failed }
        let e = camera.extent
        let W = Int(e.width.rounded()), H = Int(e.height.rounded())
        let fm = FileManager.default
        try? fm.createDirectory(at: DenoiseStore.directory, withIntermediateDirectories: true)
        // a paused clean of this photo, in this mode, by this model, carries on (its scale too)
        let candidate = DenoiseStore.partial(originalURL)
        if let candidate, candidate.decoder != decoderTag {
            log?(candidate.decoder == nil ? "denoise: restarting paused clean (its RAW decoder is unknown)"
                                         : "denoise: restarting paused clean (the RAW decoder changed)")
        }
        let paused = candidate.flatMap { p -> DenoiseStore.Partial? in
            guard DenoiseStore.canResume(p, width: W, height: H, hdr: hdrDecode, decoder: decoderTag),
                  fm.fileExists(atPath: DenoiseStore.directory.appendingPathComponent(p.file).path) else { return nil }
            return p
        }
        if paused == nil { DenoiseStore.dropPartial(originalURL) }
        let scale = paused?.scale ?? max(1, Double(Self.brightEnd99(camera)))
        var scaled = camera.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        if scale > 1.0001 {
            let s = CGFloat(1 / scale)
            scaled = scaled.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0)])
        }
        // Read the photo whole once (fastest) when there is plenty of memory for it and the RAW engine's own decode
        // (~50 MB per megapixel; 21 Oct review), else strip by strip from the RAW engine (memory stays the same
        // whatever the size; 21 Oct: a 48 MP ProRAW held whole was closed by iOS).
        let wholeMB = W * H * 8 / 1_048_576
        let whole = !Self.denoiseForceStrips && wholeMB * 4 + 50 * (W * H / 1_000_000) < Self.availableMemoryMB
        let source: CIImage
        if whole, let buffer = Self.materialized(scaled) {
            source = buffer.clampedToExtent()
            ctx.clearCaches()
        } else {
            source = scaled.clampedToExtent()
        }
        log?("denoise reads the photo " + (whole ? "whole (\(wholeMB) MB)" : "in strips (\(wholeMB) MB whole, \(Self.availableMemoryMB) MB free)")
             + (paused.map { String(format: ", continuing from %.0f %%", Double($0.rows) / Double(H) * 100) } ?? ""))

        // 2. the noise file: rows so far (a paused clean), then row of tiles by row of tiles. The small copy is averaged
        // from the rows as they are written; a continued clean rebuilds it from the rows already on disk.
        let fileName = paused?.file ?? DenoiseStore.stem(originalURL) + "-" + UUID().uuidString.prefix(8) + ".noise"
        let file = DenoiseStore.directory.appendingPathComponent(fileName)
        let previewName = (fileName as NSString).deletingPathExtension + "-preview.noise"
        let previewURL = DenoiseStore.directory.appendingPathComponent(previewName)
        var rowsWritten = paused?.rows ?? 0
        if paused == nil { guard fm.createFile(atPath: file.path, contents: nil) else { return .failed } }
        guard let handle = try? FileHandle(forWritingTo: file) else { return .failed }
        var outcome = DenoiseOutcome.failed
        defer {
            try? handle.close()
            switch outcome {
            case .done: break
            case .paused: try? fm.removeItem(at: previewURL)          // rebuilt when the clean continues
            case .cancelled, .failed:
                try? fm.removeItem(at: file); try? fm.removeItem(at: previewURL)
                try? fm.removeItem(at: DenoiseStore.partialURL(originalURL))
            }
        }
        let rowBytes = W * 8
        guard let shrinker = RowShrinker<Float16>(width: W, height: H, maxEdge: DenoiseStore.previewEdge, url: previewURL) else { return .failed }
        if rowsWritten > 0 {
            try? handle.truncate(atOffset: UInt64(rowsWritten * rowBytes))
            if let data = try? Data(contentsOf: file, options: .alwaysMapped), data.count == rowsWritten * rowBytes {
                data.withUnsafeBytes { raw in
                    let px = raw.bindMemory(to: Float16.self)
                    for y in 0..<rowsWritten { shrinker.add(px.baseAddress! + y * W * 4) }
                }
            } else {
                rowsWritten = 0
                try? handle.truncate(atOffset: 0)
            }
            _ = try? handle.seekToEnd()
        }
        func savePartial() {
            let p = DenoiseStore.Partial(file: fileName, width: W, height: H, rows: rowsWritten, scale: scale, hdr: hdrDecode,
                                         model: DenoiseStore.modelVersion, photo: originalURL.lastPathComponent, decoder: decoderTag)
            if let data = try? JSONEncoder().encode(p) { try? data.write(to: DenoiseStore.partialURL(originalURL), options: .atomic) }
        }
        savePartial()

        guard let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: T), NSNumber(value: T)], dataType: .float16) else { return .failed }
        let SW = max(W, T)                                    // strip width (a photo narrower than a tile is padded)
        var strip = [Float](repeating: 0, count: SW * T * 4)  // the model's input, RGBA, top row first
        var outStrip = [Float16](repeating: 1, count: W * T * 4)   // the noise, linear light, alpha 1
        func starts(_ size: Int) -> [Int] {
            guard size > T else { return [0] }
            var s = Array(stride(from: 0, to: size - T, by: step))
            s.append(size - T)
            return s
        }
        let xs = starts(W), ys = starts(H)
        let total = Double(xs.count * ys.count)
        var done = 0.0
        let plane = T * T
        var tileTimes: [Double] = [], stripTimes: [Double] = []
        var redone = 0
        let sc = Float(scale)
        for ty in ys {
            // rows of this strip still to write: from where the file ends (the last strip can overlap the one before,
            // and a continued clean skips the strips already on disk)
            let y0 = rowsWritten - ty, y1 = ty + T >= H ? min(T, H - ty) : T - margin
            guard y1 > y0 else { done += Double(xs.count); continue }
            if pause?() == true { outcome = .paused; return .paused }
            if cancelled?() == true { outcome = .cancelled; return .cancelled }
            let ts = Date()
            autoreleasepool {
                // Core Image's y goes up: the strip whose top row is `ty`
                strip.withUnsafeMutableBytes { buf in
                    ctx.render(source, toBitmap: buf.baseAddress!, rowBytes: SW * 16,
                               bounds: CGRect(x: 0, y: H - ty - T, width: SW, height: T), format: .RGBAf, colorSpace: p3)
                }
                ctx.clearCaches()
            }
            stripTimes.append(Date().timeIntervalSince(ts))
            for tx in xs {
                if pause?() == true { outcome = .paused; return .paused }
                if cancelled?() == true { outcome = .cancelled; return .cancelled }
                autoreleasepool {
                    let dst = input.dataPointer.bindMemory(to: Float16.self, capacity: 3 * plane)
                    for y in 0..<T {
                        let row = (y * SW + tx) * 4, d = y * T
                        for x in 0..<T {
                            let i = row + x * 4
                            dst[d + x] = Float16(strip[i])
                            dst[plane + d + x] = Float16(strip[i + 1])
                            dst[2 * plane + d + x] = Float16(strip[i + 2])
                        }
                    }
                    @inline(__always) func inputAt(_ x: Int, _ y: Int, _ c: Int) -> Float { strip[(y * SW + tx + x) * 4 + c] }
                    let tp = Date()
                    // keep the middle; at the photo's edges keep up to the edge
                    let x0 = tx == 0 ? 0 : margin
                    let x1 = tx + T >= W ? min(T, W - tx) : T - margin
                    func predict(_ m: MLModel) -> MLMultiArray? {
                        guard let features = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)]),
                              let result = try? m.prediction(from: features),
                              let o = result.featureValue(for: "output")?.multiArrayValue, o.dataType == .float16 else { return nil }
                        return o
                    }
                    // A denoised tile stays close to its input (noise is a few percent). Owner's phone, 0.1.381: some
                    // tiles came back white or false-coloured from the Neural Engine (NAFNet, a float16 overflow); any
                    // such tile is done again on the CPU (full precision), so it can never reach the photo.
                    func plausible(_ o: MLMultiArray) -> Bool {
                        let st = o.strides.map(\.intValue)
                        let src = o.dataPointer.bindMemory(to: Float16.self, capacity: o.count)
                        // on average close, and hardly any pixel far off (a wrecked patch can be small)
                        var diff: Float = 0, n: Float = 0, far: Float = 0
                        for y in stride(from: max(0, y0), to: y1, by: 4) {
                            for x in stride(from: x0, to: x1, by: 4) {
                                for c in 0..<3 {
                                    let v = Float(src[c * st[1] + y * st[2] + x * st[3]])
                                    guard v.isFinite else { return false }
                                    let d = abs(min(1, max(0, v)) - min(1, max(0, inputAt(x, y, c))))
                                    diff += d
                                    if d > 0.3 { far += 1 }
                                    n += 1
                                }
                            }
                        }
                        return n == 0 || (diff / n < 0.1 && far / n < 0.005)
                    }
                    var output = predict(model)
                    if output.map(plausible) != true {
                        redone += 1
                        if redone == 1 { log?("denoise: tile \(Int(done) + 1) looked wrong from the GPU, redone on the CPU") }
                        if let cpu = Self.denoiseCPU.model, let o = predict(cpu), plausible(o) { output = o }
                        else { output = nil }
                    }
                    // the noise taken out, in linear light at the photo's own scale; none in the highlights (the model
                    // saw them clipped) and none where no trustworthy result came back
                    if let o = output {
                        let st = o.strides.map(\.intValue)
                        let src = o.dataPointer.bindMemory(to: Float16.self, capacity: o.count)
                        for y in max(0, y0)..<y1 {
                            let row = y * W
                            for x in x0..<x1 {
                                let o4 = (row + tx + x) * 4
                                let r = inputAt(x, y, 0), g = inputAt(x, y, 1), b = inputAt(x, y, 2)
                                if max(r, max(g, b)) >= 0.98 {
                                    outStrip[o4] = 0; outStrip[o4 + 1] = 0; outStrip[o4 + 2] = 0
                                    continue
                                }
                                let at = y * st[2] + x * st[3]
                                let cr = max(0, min(1, Float(src[at]))), cg = max(0, min(1, Float(src[st[1] + at]))),
                                    cb = max(0, min(1, Float(src[2 * st[1] + at])))
                                outStrip[o4] = Float16((Self.linear(r) - Self.linear(cr)) * sc)
                                outStrip[o4 + 1] = Float16((Self.linear(g) - Self.linear(cg)) * sc)
                                outStrip[o4 + 2] = Float16((Self.linear(b) - Self.linear(cb)) * sc)
                            }
                        }
                    } else {
                        for y in max(0, y0)..<y1 {
                            for x in x0..<x1 {
                                let o4 = (y * W + tx + x) * 4
                                outStrip[o4] = 0; outStrip[o4 + 1] = 0; outStrip[o4 + 2] = 0
                            }
                        }
                    }
                    tileTimes.append(Date().timeIntervalSince(tp))
                }
                done += 1
                if tileTimes.count == 3 {
                    log?(String(format: "denoise first tiles %.2f / %.2f / %.2f s, %d tiles in all, first strip decoded in %.2f s",
                                tileTimes[0], tileTimes[1], tileTimes[2], Int(total), stripTimes.first ?? 0))
                }
                progress?(done / total)
            }
            // this strip's finished rows go to the file and into the small copy
            let first = max(0, y0)
            let wrote: Bool = outStrip.withUnsafeBytes { raw in
                let bytes = raw.baseAddress!.advanced(by: first * rowBytes)
                return (try? handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes),
                                                           count: (y1 - first) * rowBytes, deallocator: .none))) != nil
            }
            guard wrote else { log?("denoise: couldn't write the result (storage full?)"); return .failed }
            outStrip.withUnsafeBufferPointer { buf in
                for y in first..<y1 { shrinker.add(buf.baseAddress! + y * W * 4) }
            }
            rowsWritten = ty + y1
            savePartial()
        }
        guard rowsWritten == H else { log?("denoise: \(rowsWritten) of \(H) rows written"); return .failed }
        Self.healProbe?("denoise: tiles done")
        let sorted = tileTimes.sorted(), strips = stripTimes.sorted()
        Self.denoiseTimings = String(format: "load %.1f s, %d tiles, median %.2f s/tile, first %.1f s, %d redone on the CPU, %d strips decoded in %.1f s (median %.2f s)",
                                     loadSeconds, tileTimes.count, sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                                     tileTimes.first ?? 0, redone, strips.count, strips.reduce(0, +), strips.isEmpty ? 0 : strips[strips.count / 2])

        // 3. keep it: the noise file (read back memory-mapped, no decoding) and its small copy; older results of this
        // photo (other HDR mode, older kind) go
        let previewWritten = shrinker.finish()
        if !previewWritten { try? fm.removeItem(at: previewURL) }
        try? handle.synchronize()
        DenoiseStore.removeResults(originalURL, keeping: [fileName, previewName])
        let info = DenoiseStore.Info(model: DenoiseStore.modelVersion, scale: scale, width: W, height: H, file: fileName,
                                     preview: previewWritten ? previewName : nil,
                                     previewWidth: previewWritten ? shrinker.smallWidth : nil,
                                     previewHeight: previewWritten ? shrinker.smallHeight : nil, kind: DenoiseStore.noiseKind,
                                      decoder: decoderTag, previewVersion: previewWritten ? DenoiseStore.previewVersion : nil)
        guard let data = try? JSONEncoder().encode(info),
              (try? data.write(to: DenoiseStore.noiseInfoURL(originalURL), options: .atomic)) != nil else { return .failed }
        try? fm.removeItem(at: DenoiseStore.partialURL(originalURL))
        outcome = .done
        Self.healProbe?("denoise: saved")
        return .done
    }

    /// The brightness (largest colour channel) that 99.9 % of the photo stays under, on a 256 px copy.
    static func brightEnd99(_ img: CIImage) -> Float {
        let e = img.extent
        let k = 256 / max(e.width, e.height)
        let small = img.applyingFilter("CIMaximumComponent")
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1.0])
        let w = max(1, Int(e.width * k)), h = max(1, Int(e.height * k))
        var px = [Float](repeating: 0, count: w * h * 4)
        LumenGPU.context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                format: .RGBAf, colorSpace: nil)
        let v = stride(from: 0, to: px.count, by: 4).map { px[$0] }.filter { $0.isFinite }.sorted()
        guard !v.isEmpty else { return 1 }
        return v[min(v.count - 1, Int(Double(v.count) * 0.999))]
    }

    /// `decoded` with AI Denoise by `amount` (0...1): the stored noise taken out (any HDR mode), or for results made
    /// before 21 Oct the cleaned copy mixed in, highlights brighter than what the model saw keeping their own pixels.
    func withDenoise(_ decoded: CIImage, amount: Double) -> CIImage {
        guard amount > 0.001,
              let found = DenoiseStore.image(originalURL, hdr: hdrDecode, size: nativeSize,
                                             maxEdge: max(decoded.extent.width, decoded.extent.height), decoder: decoderTag) else { return decoded }
        let (stored, info) = found
        let e = decoded.extent, d = stored.extent
        var r = stored
        if abs(d.width - e.width) > 0.5 || abs(d.height - e.height) > 0.5 {
            r = r.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: e.width / d.width, kCIInputAspectRatioKey: 1.0])
        }
        r = r.transformed(by: CGAffineTransform(translationX: e.minX - r.extent.minX, y: e.minY - r.extent.minY)).cropped(to: e)
        if info.kind == DenoiseStore.noiseKind {
            guard let k = LumenKernels.shared?.noiseRemove,
                  let out = k.apply(extent: e, arguments: [decoded, r, NSNumber(value: amount)]) else { return decoded }
            return out
        }
        let high = decoded.applyingFilter("CIMaximumComponent")
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": info.scale * 0.98])
        let cleaned = decoded.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: r, kCIInputMaskImageKey: high])
        guard amount < 0.999 else { return cleaned.cropped(to: e) }
        return decoded.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: cleaned, kCIInputTimeKey: amount])
            .cropped(to: e)
    }
}
