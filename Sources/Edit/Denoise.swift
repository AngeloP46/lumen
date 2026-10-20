import CoreImage
import CoreML
import Foundation
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
    }

    static func key(_ photo: URL, hdr: Bool) -> String { photo.deletingPathExtension().lastPathComponent + (hdr ? "-hdr" : "-sdr") }
    static func infoURL(_ photo: URL, hdr: Bool) -> URL { directory.appendingPathComponent(key(photo, hdr: hdr) + ".json") }

    static func info(_ photo: URL, hdr: Bool, size: CGSize) -> Info? {
        guard let data = try? Data(contentsOf: infoURL(photo, hdr: hdr)),
              let i = try? JSONDecoder().decode(Info.self, from: data),
              i.model == modelVersion, i.width == Int(size.width.rounded()), i.height == Int(size.height.rounded()),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(i.file).path) else { return nil }
        return i
    }

    /// The cleaned photo in the working space (linear), at full size; nil when it hasn't been made yet.
    static func image(_ photo: URL, hdr: Bool, size: CGSize) -> CIImage? {
        guard let i = info(photo, hdr: hdr, size: size),
              let img = CIImage(contentsOf: directory.appendingPathComponent(i.file)) else { return nil }
        guard i.scale > 1.0001 else { return img }
        let s = CGFloat(i.scale)
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0)])
    }

    /// The photo was removed from the library: its cleaned copies go too.
    static func remove(_ photo: URL) {
        for hdr in [false, true] {
            let infoFile = infoURL(photo, hdr: hdr)
            if let data = try? Data(contentsOf: infoFile), let i = try? JSONDecoder().decode(Info.self, from: data) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(i.file))
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
        let margin = 32, step = T - 2 * margin
        guard step > 0, let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return false }
        Self.healProbe?("denoise: start")

        // 1. the photo, decoded once into a half-float buffer, divided by its bright end (HDR highlights above 1)
        guard let camera = decodeCameraLocked(maxEdge: nil) else { return false }
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
        guard let source = Self.materialized(scaled)?.clampedToExtent() else { return false }
        ctx.clearCaches()
        Self.healProbe?("denoise: photo decoded")

        // 2. tile by tile: each tile sees `margin` px of context, only its middle is kept (no seams to blend)
        var out = [UInt16](repeating: 65535, count: W * H * 4)
        guard let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: T), NSNumber(value: T)], dataType: .float16) else { return false }
        var tile = [Float](repeating: 0, count: T * T * 4)
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
        var tileTimes: [Double] = []
        var redone = 0
        for ty in ys {
            for tx in xs {
                if cancelled?() == true { return false }
                let ok: Bool = autoreleasepool {
                    // Core Image's y goes up: the tile whose top row is `ty`
                    let bounds = CGRect(x: tx, y: H - ty - T, width: T, height: T)
                    tile.withUnsafeMutableBytes { buf in
                        ctx.render(source, toBitmap: buf.baseAddress!, rowBytes: T * 16, bounds: bounds, format: .RGBAf, colorSpace: p3)
                    }
                    let dst = input.dataPointer.bindMemory(to: Float16.self, capacity: 3 * plane)
                    for i in 0..<plane {
                        dst[i] = Float16(tile[i * 4])
                        dst[plane + i] = Float16(tile[i * 4 + 1])
                        dst[2 * plane + i] = Float16(tile[i * 4 + 2])
                    }
                    let tp = Date()
                    // keep the middle; at the photo's edges keep up to the edge
                    let x0 = tx == 0 ? 0 : margin, y0 = ty == 0 ? 0 : margin
                    let x1 = tx + T >= W ? min(T, W - tx) : T - margin, y1 = ty + T >= H ? min(T, H - ty) : T - margin
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
                                    let d = abs(min(1, max(0, v)) - min(1, max(0, tile[(y * T + x) * 4 + c])))
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
                    guard let o = output else {
                        // keep the photo's own pixels for this tile rather than a wrong one
                        for y in y0..<y1 {
                            for x in x0..<x1 {
                                let o4 = ((ty + y) * W + tx + x) * 4
                                for c in 0..<3 { out[o4 + c] = UInt16(max(0, min(1, tile[(y * T + x) * 4 + c])) * 65535 + 0.5) }
                            }
                        }
                        tileTimes.append(Date().timeIntervalSince(tp))
                        return true
                    }
                    let st = o.strides.map(\.intValue)
                    let src = o.dataPointer.bindMemory(to: Float16.self, capacity: o.count)
                    for y in y0..<y1 {
                        let row = (ty + y) * W
                        for x in x0..<x1 {
                            let o4 = (row + tx + x) * 4
                            for c in 0..<3 {
                                let v = Float(src[c * st[1] + y * st[2] + x * st[3]])
                                out[o4 + c] = UInt16(max(0, min(1, v)) * 65535 + 0.5)
                            }
                        }
                    }
                    tileTimes.append(Date().timeIntervalSince(tp))
                    return true
                }
                guard ok else { log?("denoise: tile \(Int(done) + 1) of \(Int(total)) failed"); return false }
                done += 1
                if tileTimes.count == 3 {
                    log?(String(format: "denoise first tiles %.2f / %.2f / %.2f s, %d tiles in all",
                                tileTimes[0], tileTimes[1], tileTimes[2], Int(total)))
                }
                progress?(done / total)
            }
        }
        Self.healProbe?("denoise: tiles done")
        let sorted = tileTimes.sorted()
        Self.denoiseTimings = String(format: "load %.1f s, %d tiles, median %.2f s/tile, first %.1f s, %d redone on the CPU",
                                     loadSeconds, tileTimes.count, sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                                     tileTimes.first ?? 0, redone)

        // 3. keep it: 16-bit PNG (lossless) in the model's space, with the scale to undo
        try? FileManager.default.createDirectory(at: DenoiseStore.directory, withIntermediateDirectories: true)
        let name = DenoiseStore.key(originalURL, hdr: hdrDecode) + "-" + UUID().uuidString.prefix(8) + ".png"
        let file = DenoiseStore.directory.appendingPathComponent(name)
        let written: Bool = out.withUnsafeMutableBytes { buf in
            guard let provider = CGDataProvider(data: Data(bytesNoCopy: buf.baseAddress!, count: buf.count, deallocator: .none) as CFData),
                  let cg = CGImage(width: W, height: H, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: W * 8, space: p3,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(dest, cg, nil)
            return CGImageDestinationFinalize(dest)
        }
        guard written else { try? FileManager.default.removeItem(at: file); return false }
        // the previous copy for this photo and mode (an older model) is replaced
        DenoiseStore.removeOne(originalURL, hdr: hdrDecode)
        let info = DenoiseStore.Info(model: DenoiseStore.modelVersion, scale: scale, width: W, height: H, file: name)
        guard let data = try? JSONEncoder().encode(info),
              (try? data.write(to: DenoiseStore.infoURL(originalURL, hdr: hdrDecode), options: .atomic)) != nil else { return false }
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
              var den = DenoiseStore.image(originalURL, hdr: hdrDecode, size: nativeSize) else { return decoded }
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
        }
        try? FileManager.default.removeItem(at: infoFile)
    }
}
