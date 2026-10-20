import CoreImage
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// AI Denoise: SCUNet's real-noise model (cszn/SCUNet, Apache-2.0), converted to Core ML in CI
/// (.github/ci/denoise-convert, 512 x 512 tiles, float16). Picked over NAFNet-SIDD on 20 Oct: on the owner's McLaren
/// photo with ISO 6400 / 25600-like noise added, SCUNet scored +3.7 / +4.7 dB PSNR over NAFNet and kept more detail
/// (NAFNet left speckles at high noise).
///
/// The full-size photo as the camera made it (no heals) is cleaned once, tile by tile, and kept on disk per photo and
/// HDR mode (`DenoiseStore`). Every decode then mixes it in by the AI Denoise amount, so preview, 100 % view, heals,
/// export and thumbnails all see the same cleaned photo and the slider is instant after the first run.
enum DenoiseStore {
    nonisolated(unsafe) static var directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumenDenoise")
    /// Changes when the model or the way it is run changes: older results are made again.
    static let modelVersion = "scunet-real-512-1"

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
    private static let denoiseStore = LoadedModel<MLModel> {
        guard let url = denoiseModelURL else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: cfg)
    }
    /// Only looks for the model's files (the Detail panel asks while drawing).
    static var hasDenoiseModel: Bool { modelFilesExist(denoiseModelURL) }
    /// Lets go of the model (it is only needed while a photo is being cleaned).
    static func releaseDenoiseModel() { denoiseStore.release() }

    /// Whether the cleaned copy for the current HDR mode exists.
    var hasDenoised: Bool { DenoiseStore.info(originalURL, hdr: hdrDecode, size: nativeSize) != nil }

    /// Cleans the full-size photo (as the camera made it, without heals) and keeps it on disk. Slow (seconds to tens of
    /// seconds): call off the main thread. `progress` gets 0...1 as tiles finish. Returns false if it couldn't be made.
    func makeDenoised(progress: ((Double) -> Void)? = nil) -> Bool {
        if hasDenoised { return true }
        guard let model = Self.denoiseStore.model,
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
        for ty in ys {
            for tx in xs {
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
                    guard let features = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)]),
                          let result = try? model.prediction(from: features),
                          let o = result.featureValue(for: "output")?.multiArrayValue, o.dataType == .float16 else { return false }
                    let st = o.strides.map(\.intValue)
                    let src = o.dataPointer.bindMemory(to: Float16.self, capacity: o.count)
                    // keep the middle; at the photo's edges keep up to the edge
                    let x0 = tx == 0 ? 0 : margin, y0 = ty == 0 ? 0 : margin
                    let x1 = tx + T >= W ? min(T, W - tx) : T - margin, y1 = ty + T >= H ? min(T, H - ty) : T - margin
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
                    return true
                }
                guard ok else { return false }
                done += 1
                progress?(done / total)
            }
        }
        Self.healProbe?("denoise: tiles done")

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
