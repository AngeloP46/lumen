import CoreImage
import CoreML
import Foundation
import os
import ImageIO
import UniformTypeIdentifiers

/// AI Denoise: SCUNet's real-noise model (cszn/SCUNet, Apache-2.0), converted to Core ML in CI
/// (.github/ci/denoise-convert, 512 x 512 tiles, float16), run on the GPU. History (20 Oct): SCUNet on the Neural
/// Engine never got a quarter through a 24 MP photo in 100 s (its attention layers don't suit it); NAFNet-SIDD was
/// quick there but left half the noise and wrecked bright tiles (float16 overflow). The owner wants one model that
/// is good and quick, using the phone's chips to the full: SCUNet's quality on the GPU.
///
/// The full-size photo as the camera made it (no heals) is cleaned once, tile by tile, and kept on disk per photo and
/// HDR mode (`DenoiseStore`). Every decode then mixes it in by the AI Denoise amount, so preview, 100 % view, heals,
/// export and thumbnails all see the same cleaned photo and the slider is instant after the first run.
/// Box-averages full-size RGBA16 rows, given top to bottom, into a smaller copy written to a file row by row: needs only
/// one small row in memory (21 Oct: the 4096 px copy averaged in one go held ~200 MB during a clean).
final class RowShrinker {
    let width: Int, height: Int, smallWidth: Int, smallHeight: Int
    private let k: Double
    private let columnOf: [Int]
    private var acc: [Float], hits: [Float]
    private var row = 0, written = 0
    private let handle: FileHandle
    private(set) var failed = false

    init?(width: Int, height: Int, maxEdge: Int, url: URL) {
        self.width = width; self.height = height
        k = min(1, Double(maxEdge) / Double(max(width, height)))
        smallWidth = max(1, Int((Double(width) * k).rounded())); smallHeight = max(1, Int((Double(height) * k).rounded()))
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        let sw = smallWidth, kk = k
        columnOf = (0..<width).map { min(sw - 1, Int(Double($0) * kk)) }
        acc = [Float](repeating: 0, count: smallWidth * 3); hits = [Float](repeating: 0, count: smallWidth)
    }

    /// The small row a full row `y` falls into.
    private func smallRow(_ y: Int) -> Int { min(smallHeight - 1, Int(Double(y) * k)) }

    private func flush() {
        guard written < smallHeight else { return }
        var out = [UInt16](repeating: 65535, count: smallWidth * 4)
        for x in 0..<smallWidth where hits[x] > 0 {
            for c in 0..<3 { out[x * 4 + c] = UInt16(min(65535, (acc[x * 3 + c] / hits[x]).rounded())) }
        }
        if (try? out.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }) == nil { failed = true }
        written += 1
        for i in acc.indices { acc[i] = 0 }
        for i in hits.indices { hits[i] = 0 }
    }

    /// The next full row (width x 4 values).
    func add(_ px: UnsafePointer<UInt16>) {
        if row > 0, smallRow(row) != smallRow(row - 1) { flush() }
        for x in 0..<width {
            let a = columnOf[x], o = x * 4
            acc[a * 3] += Float(px[o]); acc[a * 3 + 1] += Float(px[o + 1]); acc[a * 3 + 2] += Float(px[o + 2])
            hits[a] += 1
        }
        row += 1
    }

    /// After the last row; false if anything couldn't be written.
    func finish() -> Bool {
        flush()
        while written < smallHeight && !failed { flush() }   // rounding: repeat the last row
        try? handle.close()
        return !failed && row == height
    }
}

enum DenoiseStore {
    nonisolated(unsafe) static var directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumenDenoise")
    /// Changes when the model or the way it is run changes: older results are made again.
    static let modelVersion = "scunet-real-512-gpu-2"

    struct Info: Codable {
        var model: String
        var scale: Double      // the photo was divided by this before cleaning (HDR values above 1)
        var width: Int
        var height: Int
        var file: String
        /// A copy at most `previewEdge` px long for the preview, the 100 % view's copy, thumbnails and the unhealed view
        /// (20 Oct: every decode read the whole file, ~400 MB at a time; 21 Oct: the 100 % view of a 48 MP ProRAW
        /// still read the whole 372 MB result at 2560 px, so the copy is 4096 px, as big as that view's copy).
        var preview: String? = nil
        var previewWidth: Int? = nil
        var previewHeight: Int? = nil
    }
    static let previewEdge = 4096

    static func key(_ photo: URL, hdr: Bool) -> String { photo.deletingPathExtension().lastPathComponent + (hdr ? "-hdr" : "-sdr") }
    static func infoURL(_ photo: URL, hdr: Bool) -> URL { directory.appendingPathComponent(key(photo, hdr: hdr) + ".json") }

    static func info(_ photo: URL, hdr: Bool, size: CGSize) -> Info? {
        guard let data = try? Data(contentsOf: infoURL(photo, hdr: hdr)),
              let i = try? JSONDecoder().decode(Info.self, from: data),
              i.model == modelVersion, i.width == Int(size.width.rounded()), i.height == Int(size.height.rounded()),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(i.file).path) else { return nil }
        return i
    }

    /// The cleaned photo in the working space (linear); nil when it hasn't been made yet. `maxEdge` = the size the
    /// caller needs: the small copy is used when it is big enough. Files are raw 16-bit RGBA, read memory-mapped (no
    /// decoding; iOS can drop the pages again); results made before 21 Oct are 16-bit PNGs and still read.
    static func image(_ photo: URL, hdr: Bool, size: CGSize, maxEdge: CGFloat? = nil) -> CIImage? {
        guard var i = info(photo, hdr: hdr, size: size) else { return nil }
        if let maxEdge, maxEdge <= CGFloat(previewEdge) + 1, maxEdge > CGFloat(max(i.previewWidth ?? 0, i.previewHeight ?? 0)) + 1,
           let bigger = upgradePreview(photo, hdr: hdr, info: i) {
            i = bigger
        }
        var file = i.file, w = i.width, h = i.height
        if let maxEdge, let p = i.preview, let pw = i.previewWidth, let ph = i.previewHeight, maxEdge <= CGFloat(max(pw, ph)) + 1,
           FileManager.default.fileExists(atPath: directory.appendingPathComponent(p).path) {
            file = p; w = pw; h = ph
        }
        let url = directory.appendingPathComponent(file)
        let loaded: CIImage?
        if url.pathExtension == "rgba16" {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count == w * h * 8,
                  let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
            loaded = CIImage(bitmapData: data, bytesPerRow: w * 8, size: CGSize(width: w, height: h), format: .RGBA16, colorSpace: p3)
        } else {
            loaded = CIImage(contentsOf: url)
        }
        guard let img = loaded else { return nil }
        guard i.scale > 1.0001 else { return img }
        let s = CGFloat(i.scale)
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0)])
    }

    private static let upgradeLock = NSLock()
    /// A `previewEdge` copy for a result whose small copy is smaller (owner's phone, 21 Oct: a 48 MP ProRAW cleaned with
    /// a 2560 px copy made the 100 % view read the whole 372 MB result, and iOS closed Lumen). Made once, row by row
    /// from the memory-mapped result; nil for old PNG results (they are read as before).
    private static func upgradePreview(_ photo: URL, hdr: Bool, info i: Info) -> Info? {
        upgradeLock.lock(); defer { upgradeLock.unlock() }
        let fullURL = directory.appendingPathComponent(i.file)
        guard fullURL.pathExtension == "rgba16",
              let data = try? Data(contentsOf: fullURL, options: .alwaysMapped), data.count == i.width * i.height * 8 else { return nil }
        let name = (i.file as NSString).deletingPathExtension + "-preview\(previewEdge).rgba16"
        let url = directory.appendingPathComponent(name)
        guard let shrinker = RowShrinker(width: i.width, height: i.height, maxEdge: previewEdge, url: url) else { return nil }
        data.withUnsafeBytes { raw in
            let px = raw.bindMemory(to: UInt16.self)
            for y in 0..<i.height { autoreleasepool { shrinker.add(px.baseAddress! + y * i.width * 4) } }
        }
        guard shrinker.finish() else { try? FileManager.default.removeItem(at: url); return nil }
        var n = i
        let old = n.preview
        n.preview = name; n.previewWidth = shrinker.smallWidth; n.previewHeight = shrinker.smallHeight
        guard let json = try? JSONEncoder().encode(n), (try? json.write(to: infoURL(photo, hdr: hdr), options: .atomic)) != nil else {
            try? FileManager.default.removeItem(at: url); return nil
        }
        if let old, old != name { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old)) }
        return n
    }

    /// The photo was removed from the library: its cleaned copies go too.
    static func remove(_ photo: URL) {
        for hdr in [false, true] {
            let infoFile = infoURL(photo, hdr: hdr)
            if let data = try? Data(contentsOf: infoFile), let i = try? JSONDecoder().decode(Info.self, from: data) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(i.file))
                if let p = i.preview { try? FileManager.default.removeItem(at: directory.appendingPathComponent(p)) }
            }
            try? FileManager.default.removeItem(at: infoFile)
        }
    }
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
    /// Loads the model and runs one blank tile, so the GPU's one-off setup (owner's phone, 0.1.388: 10 s load + 10 s
    /// first tile) happens while Detail is open, before the button is tapped. Returns the seconds it took.
    @discardableResult
    static func warmDenoise() -> Double {
        let t0 = Date()
        guard let model = denoiseModel.model,
              let shape = model.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint?.shape,
              let blank = try? MLMultiArray(shape: shape, dataType: .float16),
              let features = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: blank)]) else { return 0 }
        memset(blank.dataPointer, 0, blank.count * 2)
        _ = try? model.prediction(from: features)
        return Date().timeIntervalSince(t0)
    }
    /// The same model on the CPU (full precision), for a tile the Neural Engine got wrong.
    private static let denoiseCPU = LoadedModel<MLModel> {
        guard let url = denoiseModelURL else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        return try? MLModel(contentsOf: url, configuration: cfg)
    }
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
    /// Lets go of the model (it is only needed while a photo is being cleaned).
    static func releaseDenoiseModel() { denoiseModel.release(); denoiseCPU.release() }

    /// Whether the cleaned copy for the current HDR mode exists.
    var hasDenoised: Bool { DenoiseStore.info(originalURL, hdr: hdrDecode, size: nativeSize) != nil }

    /// Cleans the full-size photo (as the camera made it, without heals) and keeps it on disk. Slow (seconds to tens of
    /// seconds): call off the main thread. `progress` gets 0...1 as tiles finish. Returns false if it couldn't be made.
    /// `cancelled` is asked before every tile: the app leaving the screen stops the job (iOS doesn't allow GPU work in
    /// the background; owner's diagnostics 20 Oct: a job left running was killed on return at 2.7 GB).
    /// `log` gets the load time and the first tiles' times straight away, so even a run that never finishes shows the
    /// phone's speed in ⋯ → Send diagnostics.
    func makeDenoised(progress: ((Double) -> Void)? = nil, cancelled: (() -> Bool)? = nil,
                      log: ((String) -> Void)? = nil) -> Bool {
        if hasDenoised { return true }
        let t0 = Date()
        let model = Self.denoiseModel.model
        let loadSeconds = Date().timeIntervalSince(t0)
        log?(String(format: "denoise model %@ in %.1f s", model == nil ? "failed to load" : "loaded", loadSeconds))
        guard let model,
              let shape = model.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint?.shape,
              shape.count == 4 else { return false }
        let T = shape[3].intValue
        // 16 px of context each side (was 32; 20 Oct, whole photo in PyTorch: 60 dB from the 32 px result, no step at any
        // tile boundary): 117 tiles for 24 MP instead of 126
        let margin = 16, step = T - 2 * margin
        guard step > 0, let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return false }
        Self.healProbe?("denoise: start")

        // 1. the photo (not decoded yet: each row of tiles is decoded on its own below), divided by its bright end
        // (HDR highlights above 1)
        // read through a decoder of its own: the photo's RAW decoder keeps a full-size decode cached for as long as
        // the photo stays open (owner's phone, 21 Oct: ~1 GB more after a clean, then Heal on top closed Lumen)
        let reader = EditSession(url: originalURL, expandHDR: hdrDecode)
        guard let camera = (reader ?? self).decodeCameraLocked(maxEdge: nil) else { return false }
        let e = camera.extent
        let W = Int(e.width.rounded()), H = Int(e.height.rounded())
        let scale = max(1, Double(Self.brightEnd99(camera)))
        var scaled = camera.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        if scale > 1.0001 {
            let s = CGFloat(1 / scale)
            scaled = scaled.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0)])
        }
        // Read the photo whole once (fastest) when there is plenty of memory for it, else strip by strip from the RAW
        // engine (memory stays the same whatever the size; 21 Oct: a 48 MP ProRAW held whole was closed by iOS).
        let wholeMB = W * H * 8 / 1_048_576
        let whole = !Self.denoiseForceStrips && wholeMB * 4 < Self.availableMemoryMB
        let source: CIImage
        if whole, let buffer = Self.materialized(scaled) {
            source = buffer.clampedToExtent()
            ctx.clearCaches()
        } else {
            source = scaled.clampedToExtent()
        }
        log?("denoise reads the photo " + (whole ? "whole (\(wholeMB) MB)" : "in strips (\(wholeMB) MB whole, \(Self.availableMemoryMB) MB free)"))

        // 2. row of tiles by row of tiles: the strip is decoded, cleaned tile by tile (each tile sees `margin` px of
        // context, only its middle is kept: no seams to blend) and its rows are written straight to the file. Memory
        // stays the same whatever the photo's size (owner's phone, 21 Oct: a 48 MP ProRAW held whole, in and out,
        // was closed by iOS). The small preview copy is averaged from the rows as they go.
        try? FileManager.default.createDirectory(at: DenoiseStore.directory, withIntermediateDirectories: true)
        let stem = DenoiseStore.key(originalURL, hdr: hdrDecode) + "-" + UUID().uuidString.prefix(8)
        let name = stem + ".rgba16", previewName = stem + "-preview.rgba16"
        let file = DenoiseStore.directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { return false }
        var finished = false
        defer {
            try? handle.close()
            if !finished { try? FileManager.default.removeItem(at: file) }
        }
        let previewURL = DenoiseStore.directory.appendingPathComponent(previewName)
        let shrinker = RowShrinker(width: W, height: H, maxEdge: DenoiseStore.previewEdge, url: previewURL)
        defer { if !finished { try? FileManager.default.removeItem(at: previewURL) } }

        guard let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: T), NSNumber(value: T)], dataType: .float16) else { return false }
        let SW = max(W, T)                                   // strip width (a photo narrower than a tile is padded)
        var strip = [Float](repeating: 0, count: SW * T * 4) // RGBA float, top row first
        var outStrip = [UInt16](repeating: 65535, count: W * T * 4)
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
        var rowsWritten = 0
        for ty in ys {
            if cancelled?() == true { return false }
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
            // rows of this strip still to write (the last strip can overlap the one before: it starts where that ended)
            let y0 = rowsWritten - ty, y1 = ty + T >= H ? min(T, H - ty) : T - margin
            for tx in xs {
                if cancelled?() == true { return false }
                let ok: Bool = autoreleasepool {
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
                        for y in stride(from: y0, to: y1, by: 4) {
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
                    if let o = output {
                        let st = o.strides.map(\.intValue)
                        let src = o.dataPointer.bindMemory(to: Float16.self, capacity: o.count)
                        for y in max(0, y0)..<y1 {
                            let row = y * W
                            for x in x0..<x1 {
                                let o4 = (row + tx + x) * 4
                                for c in 0..<3 {
                                    let v = Float(src[c * st[1] + y * st[2] + x * st[3]])
                                    outStrip[o4 + c] = UInt16(max(0, min(1, v)) * 65535 + 0.5)
                                }
                            }
                        }
                    } else {
                        // keep the photo's own pixels for this tile rather than a wrong one
                        for y in max(0, y0)..<y1 {
                            for x in x0..<x1 {
                                let o4 = (y * W + tx + x) * 4
                                for c in 0..<3 { outStrip[o4 + c] = UInt16(max(0, min(1, inputAt(x, y, c))) * 65535 + 0.5) }
                            }
                        }
                    }
                    tileTimes.append(Date().timeIntervalSince(tp))
                    return true
                }
                guard ok else { log?("denoise: tile \(Int(done) + 1) of \(Int(total)) failed"); return false }
                done += 1
                if tileTimes.count == 3 {
                    log?(String(format: "denoise first tiles %.2f / %.2f / %.2f s, %d tiles in all, first strip decoded in %.2f s",
                                tileTimes[0], tileTimes[1], tileTimes[2], Int(total), stripTimes.first ?? 0))
                }
                progress?(done / total)
            }
            // this strip's finished rows go to the file and into the preview
            let first = max(0, y0)
            guard y1 > first else { continue }
            let wrote: Bool = outStrip.withUnsafeBytes { raw in
                let bytes = raw.baseAddress!.advanced(by: first * W * 8)
                return (try? handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes),
                                                           count: (y1 - first) * W * 8, deallocator: .none))) != nil
            }
            guard wrote else { log?("denoise: couldn't write the result (storage full?)"); return false }
            if let shrinker {
                outStrip.withUnsafeBufferPointer { buf in
                    for y in first..<y1 { shrinker.add(buf.baseAddress! + y * W * 4) }
                }
            }
            rowsWritten = ty + y1
        }
        guard rowsWritten == H else { log?("denoise: \(rowsWritten) of \(H) rows written"); return false }
        Self.healProbe?("denoise: tiles done")
        let sorted = tileTimes.sorted(), strips = stripTimes.sorted()
        Self.denoiseTimings = String(format: "load %.1f s, %d tiles, median %.2f s/tile, first %.1f s, %d redone on the CPU, %d strips decoded in %.1f s (median %.2f s)",
                                     loadSeconds, tileTimes.count, sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                                     tileTimes.first ?? 0, redone, strips.count, strips.reduce(0, +), strips.isEmpty ? 0 : strips[strips.count / 2])

        // 3. keep it: the raw 16-bit RGBA file (read back memory-mapped, no decoding) in the model's space, with the
        // scale to undo, plus the small copy for the preview and thumbnails
        let previewWritten = shrinker?.finish() ?? false
        if !previewWritten { try? FileManager.default.removeItem(at: previewURL) }
        let pw = shrinker?.smallWidth ?? 0, ph = shrinker?.smallHeight ?? 0
        try? handle.synchronize()
        // the previous copy for this photo and mode (an older model) is replaced
        DenoiseStore.removeOne(originalURL, hdr: hdrDecode)
        let info = DenoiseStore.Info(model: DenoiseStore.modelVersion, scale: scale, width: W, height: H, file: name,
                                     preview: previewWritten ? previewName : nil,
                                     previewWidth: previewWritten ? pw : nil, previewHeight: previewWritten ? ph : nil)
        guard let data = try? JSONEncoder().encode(info),
              (try? data.write(to: DenoiseStore.infoURL(originalURL, hdr: hdrDecode), options: .atomic)) != nil else {
            try? FileManager.default.removeItem(at: previewURL)
            return false
        }
        finished = true
        Self.healProbe?("denoise: saved")
        return true
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

    /// `decoded` with the cleaned photo mixed in by `amount` (0...1). Highlights brighter than what the model saw stay
    /// the photo's own.
    func withDenoise(_ decoded: CIImage, amount: Double) -> CIImage {
        guard amount > 0.001, let info = DenoiseStore.info(originalURL, hdr: hdrDecode, size: nativeSize),
              var den = DenoiseStore.image(originalURL, hdr: hdrDecode, size: nativeSize,
                                           maxEdge: max(decoded.extent.width, decoded.extent.height)) else { return decoded }
        let e = decoded.extent, d = den.extent
        if abs(d.width - e.width) > 0.5 || abs(d.height - e.height) > 0.5 {
            den = den.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: e.width / d.width, kCIInputAspectRatioKey: 1.0])
        }
        den = den.transformed(by: CGAffineTransform(translationX: e.minX - den.extent.minX, y: e.minY - den.extent.minY)).cropped(to: e)
        let high = decoded.applyingFilter("CIMaximumComponent")
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": info.scale * 0.98])
        let cleaned = decoded.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: den, kCIInputMaskImageKey: high])
        guard amount < 0.999 else { return cleaned.cropped(to: e) }
        return decoded.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: cleaned, kCIInputTimeKey: amount])
            .cropped(to: e)
    }
}

extension DenoiseStore {
    static func removeOne(_ photo: URL, hdr: Bool) {
        let infoFile = infoURL(photo, hdr: hdr)
        if let data = try? Data(contentsOf: infoFile), let i = try? JSONDecoder().decode(Info.self, from: data) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(i.file))
                if let p = i.preview { try? FileManager.default.removeItem(at: directory.appendingPathComponent(p)) }
        }
        try? FileManager.default.removeItem(at: infoFile)
    }
}
