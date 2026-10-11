import CoreImage
import CoreML
import Foundation

/// Smart fill: Stable Diffusion 1.5 *inpainting* (CyberRealistic V8 Inpaint, Core ML, 6-bit, 512 x 512, licence
/// CreativeML OpenRAIL-M) run on the phone. Slower than the quick LaMa heal, but it has some idea of what a scene
/// should look like behind the thing removed. The ~950 MB of model files are downloaded once inside the app
/// (`SmartFillFiles`), not shipped in it, so app updates stay small.
enum SmartFillFiles {
    static let repo = "https://huggingface.co/LocalMuseAI/coreml-cyberrealistic-v8-inpaint-6bit/resolve/main/"
    /// (path, size in bytes) — sizes from the repository listing, used to check every download.
    static let files: [(String, Int64)] = [
        ("TextEncoder.mlmodelc/analytics/coremldata.bin", 243), ("TextEncoder.mlmodelc/coremldata.bin", 992),
        ("TextEncoder.mlmodelc/metadata.json", 3089), ("TextEncoder.mlmodelc/model.mil", 187497),
        ("TextEncoder.mlmodelc/weights/weight.bin", 139910080),
        ("Unet.mlmodelc/analytics/coremldata.bin", 243), ("Unet.mlmodelc/coremldata.bin", 1425),
        ("Unet.mlmodelc/metadata.json", 4039), ("Unet.mlmodelc/model.mil", 3136987),
        ("Unet.mlmodelc/weights/weight.bin", 645336256),
        ("VAEDecoder.mlmodelc/analytics/coremldata.bin", 243), ("VAEDecoder.mlmodelc/coremldata.bin", 919),
        ("VAEDecoder.mlmodelc/metadata.json", 2726), ("VAEDecoder.mlmodelc/model.mil", 194902),
        ("VAEDecoder.mlmodelc/weights/weight.bin", 98993280),
        ("VAEEncoder.mlmodelc/analytics/coremldata.bin", 243), ("VAEEncoder.mlmodelc/coremldata.bin", 923),
        ("VAEEncoder.mlmodelc/metadata.json", 2710), ("VAEEncoder.mlmodelc/model.mil", 149284),
        ("VAEEncoder.mlmodelc/weights/weight.bin", 68338112),
        ("merges.txt", 524619), ("vocab.json", 1059962),
    ]
    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.1 } }

    /// Where the files live. Tests point `LUMEN_SMARTFILL_DIR` at a downloaded copy.
    nonisolated(unsafe) static var directory: URL = {
        if let p = ProcessInfo.processInfo.environment["LUMEN_SMARTFILL_DIR"] { return URL(fileURLWithPath: p) }
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("SmartFill-cyberrealistic-v8-inpaint-6bit", isDirectory: true)
    }()

    static var isComplete: Bool {
        files.allSatisfy { f in
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(f.0).path)[.size] as? Int64) ?? -1
            return size == f.1
        }
    }
}

/// The four models, loaded on first use and kept until `unload()`.
final class SmartFillModels: @unchecked Sendable {
    nonisolated(unsafe) private static var cached: SmartFillModels?
    private static let lock = NSLock()

    let textEncoder: MLModel, unet: MLModel, vaeEncoder: MLModel, vaeDecoder: MLModel
    let tokenizer: CLIPTokenizer
    /// Text embeddings for the fixed prompts, [77 x 768] each.
    let positive: [Float], negative: [Float]

    static let positivePrompt = "seamless background, natural continuation of the surroundings, empty scene, high quality photo"
    static let negativePrompt = "person, people, man, woman, face, text, letters, logo, watermark, object, blurry, distorted, artifacts"

    static func shared(unetUnits: MLComputeUnits = .cpuAndNeuralEngine) -> SmartFillModels? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        guard SmartFillFiles.isComplete else { return nil }
        let c = SmartFillModels(unetUnits: unetUnits)
        cached = c
        return c
    }
    static func unload() { lock.lock(); cached = nil; lock.unlock() }

    private init?(unetUnits: MLComputeUnits) {
        let dir = SmartFillFiles.directory
        func load(_ name: String, _ units: MLComputeUnits) -> MLModel? {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = units
            return try? MLModel(contentsOf: dir.appendingPathComponent("\(name).mlmodelc"), configuration: cfg)
        }
        guard let te = load("TextEncoder", .cpuAndNeuralEngine), let u = load("Unet", unetUnits),
              let ve = load("VAEEncoder", .cpuAndGPU), let vd = load("VAEDecoder", .cpuAndGPU),
              let tok = CLIPTokenizer(vocab: dir.appendingPathComponent("vocab.json"), merges: dir.appendingPathComponent("merges.txt"))
        else { return nil }
        textEncoder = te; unet = u; vaeEncoder = ve; vaeDecoder = vd; tokenizer = tok
        func embed(_ text: String) -> [Float]? {
            let ids = tok.encode(text)
            guard let arr = try? MLMultiArray(shape: [1, 77], dataType: .float32) else { return nil }
            for (i, id) in ids.enumerated() { arr[i] = NSNumber(value: Float(id)) }
            guard let out = try? te.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_ids": arr])),
                  let h = out.featureValue(for: "last_hidden_state")?.multiArrayValue else { return nil }
            return MLArrays.floats(h)
        }
        guard let p = embed(Self.positivePrompt), let n = embed(Self.negativePrompt), p.count == 77 * 768, n.count == 77 * 768
        else { return nil }
        positive = p; negative = n
    }
}

/// CLIP's byte-pair tokenizer (the text side of Stable Diffusion), just enough for plain English prompts.
struct CLIPTokenizer {
    private let vocab: [String: Int]
    private let ranks: [String: Int]
    static let bos = 49406, eos = 49407

    init?(vocab vURL: URL, merges mURL: URL) {
        guard let vData = try? Data(contentsOf: vURL),
              let v = try? JSONSerialization.jsonObject(with: vData) as? [String: Int],
              let mText = try? String(contentsOf: mURL, encoding: .utf8) else { return nil }
        vocab = v
        var r: [String: Int] = [:]
        for (i, line) in mText.split(separator: "\n").dropFirst().enumerated() { r[String(line)] = i }
        ranks = r
    }

    private func bpe(_ word: String) -> [String] {
        var parts = word.map { String($0) }
        guard !parts.isEmpty else { return [] }
        parts[parts.count - 1] += "</w>"
        while parts.count > 1 {
            var best: (rank: Int, i: Int)?
            for i in 0..<(parts.count - 1) {
                if let rk = ranks[parts[i] + " " + parts[i + 1]], best == nil || rk < best!.rank { best = (rk, i) }
            }
            guard let b = best else { break }
            let a = parts[b.i], c = parts[b.i + 1]
            var merged: [String] = []
            var j = 0
            while j < parts.count {
                if j < parts.count - 1 && parts[j] == a && parts[j + 1] == c { merged.append(a + c); j += 2 }
                else { merged.append(parts[j]); j += 1 }
            }
            parts = merged
        }
        return parts
    }

    /// Token ids, start and end markers included, padded to 77 with the end marker.
    func encode(_ text: String) -> [Int] {
        let clean = text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let pattern = "'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
        var ids = [Self.bos]
        if let re = try? NSRegularExpression(pattern: pattern) {
            let ns = clean as NSString
            for m in re.matches(in: clean, range: NSRange(location: 0, length: ns.length)) {
                for tok in bpe(ns.substring(with: m.range)) { if let id = vocab[tok] { ids.append(id) } }
            }
        }
        ids = Array(ids.prefix(76)) + [Self.eos]
        while ids.count < 77 { ids.append(Self.eos) }
        return ids
    }
}

enum MLArrays {
    /// All values of a Float16/Float32/Double array in logical (row-major) order, whatever its strides.
    static func floats(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        let n = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: n)
        var contiguous = true
        var expect = 1
        for d in stride(from: shape.count - 1, through: 0, by: -1) { if strides[d] != expect { contiguous = false }; expect *= shape[d] }
        func offset(_ i: Int) -> Int {
            var rest = i, o = 0
            for d in stride(from: shape.count - 1, through: 0, by: -1) { o += (rest % shape[d]) * strides[d]; rest /= shape[d] }
            return o
        }
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: 1)
            for i in 0..<n { out[i] = p[contiguous ? i : offset(i)] }
        case .float16:
            let p = a.dataPointer.bindMemory(to: Float16.self, capacity: 1)
            for i in 0..<n { out[i] = Float(p[contiguous ? i : offset(i)]) }
        default:
            for i in 0..<n { out[i] = a[i].floatValue }
        }
        return out
    }

    static func half(_ values: [Float], shape: [Int]) -> MLMultiArray? {
        guard let a = try? MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16) else { return nil }
        let p = a.dataPointer.bindMemory(to: Float16.self, capacity: values.count)
        for i in values.indices { p[i] = Float16(values[i]) }
        return a
    }
}

/// Deterministic Gaussian noise (a fresh seed = a different version of the fill).
struct SeededNoise {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    private mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return (Double(z >> 11) + 0.5) / Double(1 << 53)
    }
    mutating func gaussian(_ n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        var i = 0
        while i < n {
            let u = next(), v = next()
            let r = (-2 * log(u)).squareRoot()
            out[i] = Float(r * cos(2 * .pi * v)); if i + 1 < n { out[i + 1] = Float(r * sin(2 * .pi * v)) }
            i += 2
        }
        return out
    }
}

extension EditSession {
    static let smartSide = 512

    /// Rebuilds the painted spot with the diffusion model. `progress(step, steps)` is called as it works.
    /// Returns nil when the models are missing or the answer is unusable.
    func makeSmartHeal(strokes: [BrushStroke], earlier: [HealSpot], seed: UInt64, steps: Int = 20,
                       progress: ((Int, Int) -> Void)? = nil) -> HealSpot? {
        guard !strokes.isEmpty, var models = SmartFillModels.shared() else { return nil }
        let W = nativeSize.width, H = nativeSize.height, L = max(W, H)

        // 1. the painted area (y down), brush radius included, and a square around it with room for context
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for st in strokes where !st.erase {
            let r = CGFloat(st.size) * L / 2
            for p in st.points {
                minX = min(minX, CGFloat(p.x) * W - r); maxX = max(maxX, CGFloat(p.x) * W + r)
                minY = min(minY, CGFloat(p.y) * H - r); maxY = max(maxY, CGFloat(p.y) * H + r)
            }
        }
        guard minX.isFinite, maxX > minX, maxY > minY else { return nil }
        var side = max(maxX - minX, maxY - minY) * 1.7
        side = min(max(side, 256), min(W, H))
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let rx = min(max(cx - side / 2, 0), W - side), ry = min(max(cy - side / 2, 0), H - side)
        let region = CGRect(x: rx, y: ry, width: side, height: side)
        let n = CGFloat(Self.smartSide), N = Self.smartSide
        let k = n / side

        // 2. the photo there (with earlier heals), 512 x 512, HDR squeezed into 0...1 like the quick heal
        guard let full = decode(maxEdge: nil, heals: earlier) else { return nil }
        let ciRegion = CGRect(x: region.minX, y: H - region.maxY, width: side, height: side)
        let crop = full.cropped(to: ciRegion)
            .transformed(by: CGAffineTransform(translationX: -ciRegion.minX, y: -ciRegion.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1.0])
            .cropped(to: CGRect(x: 0, y: 0, width: n, height: n))
        var peak = [Float](repeating: 0, count: 4)
        let mx = crop.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: crop.extent)])
        LumenGPU.context.render(mx, toBitmap: &peak, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                format: .RGBAf, colorSpace: nil)
        let scale = Double(max(1, peak[0], peak[1], peak[2]))
        var input = crop
        if scale > 1 {
            let s = CGFloat(1 / scale)
            input = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0)])
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: N * N * 4)
        LumenGPU.context.render(input, toBitmap: &rgba, rowBytes: N * 4, bounds: CGRect(x: 0, y: 0, width: n, height: n),
                                format: .RGBA8, colorSpace: srgb)   // top row first

        // 3. the hole (1 = rebuild), a little wider than painted, at 512 and at the model's 64 x 64
        func strokeMask(grow: CGFloat, soften: CGFloat) -> CGImage? {
            guard let g = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            g.setFillColor(gray: 0, alpha: 1); g.fill(CGRect(x: 0, y: 0, width: n, height: n))
            g.setLineCap(.round); g.setLineJoin(.round)
            func pt(_ p: Pt) -> CGPoint { CGPoint(x: (CGFloat(p.x) * W - region.minX) * k, y: n - (CGFloat(p.y) * H - region.minY) * k) }
            for st in strokes {
                guard let first = st.points.first else { continue }
                g.setStrokeColor(gray: st.erase ? 0 : 1, alpha: 1)
                g.setLineWidth(max(2, CGFloat(st.size) * L * k + (st.erase ? -grow : grow) * 2))
                g.beginPath(); g.move(to: pt(first)); g.addLine(to: pt(first))
                for p in st.points.dropFirst() { g.addLine(to: pt(p)) }
                g.strokePath()
            }
            guard let img = g.makeImage() else { return nil }
            guard soften > 0 else { return img }
            let ci = Self.blur(Self.expandRed(CIImage(cgImage: img, options: [.colorSpace: NSNull()])), soften,
                               CGRect(x: 0, y: 0, width: n, height: n))
            return ctx.createCGImage(ci, from: ci.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        guard let holeCG = strokeMask(grow: 6, soften: 0), let blend = strokeMask(grow: 10, soften: 4),
              let hole = Self.grayBytes(holeCG, N) else { return nil }
        let L8 = 64
        var mask64 = [Float](repeating: 0, count: L8 * L8)
        for y in 0..<L8 { for x in 0..<L8 {
            var any = false
            for yy in (y * 8)..<(y * 8 + 8) where !any { for xx in (x * 8)..<(x * 8 + 8) where hole[yy * N + xx] > 127 { any = true; break } }
            mask64[y * L8 + x] = any ? 1 : 0
        } }

        // 4. image and masked image in [-1, 1] (planar RGB), and the masked image's latent
        var img = [Float](repeating: 0, count: 3 * N * N), masked = img
        for i in 0..<(N * N) {
            let m: Float = hole[i] > 127 ? 0 : 1
            for c in 0..<3 {
                let v = Float(rgba[i * 4 + c]) / 127.5 - 1
                img[c * N * N + i] = v
                masked[c * N * N + i] = v * m
            }
        }
        guard let mIn = MLArrays.half(masked, shape: [1, 3, N, N]),
              let mOut = try? models.vaeEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x": mIn])),
              let moments = mOut.featureValue(for: "latent")?.multiArrayValue else { return nil }
        let mom = MLArrays.floats(moments)                       // [8, 64, 64]: mean then log variance
        let LL = 4 * L8 * L8
        // This conversion's encoder already applies SD's 0.18215 latent scale (scaling again drained the colour:
        // red paint came back grey); the decoder still wants unscaled latents (z = latent / 0.18215).
        let maskedLatent = Array(mom[0..<LL])
        var debug = ""
        if ProcessInfo.processInfo.environment["LUMEN_SMARTFILL_DEBUG"] != nil {
            // round trip: decode the masked image's latent and read a pixel away from the hole (should be the photo)
            let holeCount = hole.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }
            let maskSum = mask64.reduce(0, +)
            var rt = "-"
            if let z = MLArrays.half(maskedLatent.map { $0 / 0.18215 }, shape: [1, 4, L8, L8]),   // as the final decode does
               let o = try? models.vaeDecoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["z": z])),
               let im = o.featureValue(for: "image")?.multiArrayValue {
                let f = MLArrays.floats(im)
                let p = 40 * N + 40, q = (N / 2) * N + N / 2
                rt = String(format: "corner %.2f %.2f %.2f centre %.2f %.2f %.2f", f[p], f[N * N + p], f[2 * N * N + p],
                            f[q], f[N * N + q], f[2 * N * N + q])
            }
            let inPx = String(format: "%.2f %.2f %.2f", img[40 * N + 40], img[N * N + 40 * N + 40], img[2 * N * N + 40 * N + 40])
            let lm = (0..<4).map { c in (0..<(L8 * L8)).reduce(Float(0)) { $0 + maskedLatent[c * L8 * L8 + $1] } / Float(L8 * L8) }
            debug = "hole px \(holeCount), mask64 \(maskSum), input corner \(inPx), latent means \(lm.map { String(format: "%.2f", $0) }), vae round trip \(rt)"
        }

        // 5. DPM-Solver++ (2M) with classifier-free guidance; the unconditional half uses the negative prompt
        var betas = [Double](repeating: 0, count: 1000)
        for i in 0..<1000 { let b = 0.00085.squareRoot() + (0.012.squareRoot() - 0.00085.squareRoot()) * Double(i) / 999; betas[i] = b * b }
        var acp = [Double](repeating: 0, count: 1000)
        var prod = 1.0
        for i in 0..<1000 { prod *= 1 - betas[i]; acp[i] = prod }
        let ts: [Int] = (0..<steps).map { Int((999.0 - 999.0 * Double($0) / Double(steps)).rounded()) }
        func alpha(_ t: Int) -> Double { acp[t].squareRoot() }
        func sigma(_ t: Int) -> Double { (1 - acp[t]).squareRoot() }
        func lambda(_ t: Int) -> Double { log(alpha(t) / sigma(t)) }

        var noise = SeededNoise(seed: seed)
        var x = noise.gaussian(LL)
        var hidden = [Float](repeating: 0, count: 2 * 768 * 77)
        for kk in 0..<77 { for c in 0..<768 {
            hidden[c * 77 + kk] = models.negative[kk * 768 + c]
            hidden[768 * 77 + c * 77 + kk] = models.positive[kk * 768 + c]
        } }
        guard let hiddenArr = MLArrays.half(hidden, shape: [2, 768, 1, 77]) else { return nil }
        let guidance: Float = 5
        var prevX0: [Float]?
        var retriedOnGPU = false

        var i = 0
        while i < steps {
            let t = ts[i]
            var sample = [Float](repeating: 0, count: 2 * 9 * L8 * L8)
            let plane = L8 * L8
            for b in 0..<2 {
                let base = b * 9 * plane
                for j in 0..<LL { sample[base + j] = x[j] }
                for j in 0..<plane { sample[base + 4 * plane + j] = mask64[j] }
                for j in 0..<LL { sample[base + 5 * plane + j] = maskedLatent[j] }
            }
            guard let sArr = MLArrays.half(sample, shape: [2, 9, L8, L8]),
                  let tArr = MLArrays.half([Float(t), Float(t)], shape: [2]),
                  let out = try? models.unet.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                      "sample": sArr, "timestep": tArr, "encoder_hidden_states": hiddenArr])),
                  let np = out.featureValue(for: "noise_pred")?.multiArrayValue else { return nil }
            let e = MLArrays.floats(np)
            var eps = [Float](repeating: 0, count: LL)
            var finite = true
            for j in 0..<LL {
                let v = e[j] + guidance * (e[LL + j] - e[j])
                if !v.isFinite { finite = false }
                eps[j] = v
            }
            if !finite {
                // the Neural Engine's float16 gave up: once, start again on the GPU
                guard !retriedOnGPU else { return nil }
                retriedOnGPU = true
                SmartFillModels.unload()
                guard let g = SmartFillModels.shared(unetUnits: .cpuAndGPU) else { return nil }
                models = g
                noise = SeededNoise(seed: seed); x = noise.gaussian(LL); prevX0 = nil; i = 0
                continue
            }
            let a = Float(alpha(t)), s = Float(sigma(t))
            let x0 = (0..<LL).map { (x[$0] - s * eps[$0]) / a }
            if i == steps - 1 {
                x = x0
            } else {
                let tn = ts[i + 1]
                let h = lambda(tn) - lambda(t)
                let an = Float(alpha(tn)), sn = Float(sigma(tn))
                let c1 = sn / s, c2 = an * Float(exp(-h) - 1)
                var d = x0
                if let p = prevX0, i > 0 {
                    let h0 = lambda(t) - lambda(ts[i - 1])
                    let r = Float(h0 / h)
                    for j in 0..<LL { d[j] = (1 + 1 / (2 * r)) * x0[j] - (1 / (2 * r)) * p[j] }
                }
                for j in 0..<LL { x[j] = c1 * x[j] - c2 * d[j] }
                prevX0 = x0
            }
            i += 1
            progress?(i, steps)
        }

        // 6. decode, keep the photo outside the hole, and store it like a quick heal
        guard let zArr = MLArrays.half(x.map { $0 / 0.18215 }, shape: [1, 4, L8, L8]),
              let dOut = try? models.vaeDecoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["z": zArr])),
              let imgArr = dOut.featureValue(for: "image")?.multiArrayValue else { return nil }
        let dec = MLArrays.floats(imgArr)
        guard dec.count == 3 * N * N else { return nil }
        var outBytes = [UInt8](repeating: 255, count: N * N * 4)
        for p in 0..<(N * N) { for c in 0..<3 {
            let v = dec[c * N * N + p]
            guard v.isFinite else { return nil }
            outBytes[p * 4 + c] = UInt8(max(0, min(255, ((v + 1) * 127.5).rounded())))
        } }
        guard let provider = CGDataProvider(data: Data(outBytes) as CFData),
              let outCG = CGImage(width: N, height: N, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: N * 4,
                                  space: srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let out = CIImage(cgImage: outCG)
        // never keep a broken answer: inside the hole it must not be far darker than around it
        guard let inCG = CGImage(width: N, height: N, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: N * 4,
                                 space: srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                 provider: CGDataProvider(data: Data(rgba) as CFData)!, decode: nil, shouldInterpolate: true,
                                 intent: .defaultIntent) else { return nil }
        let ring = Self.meanInside(CIImage(cgImage: inCG), mask: blend, invert: true, side: N)
        let inHole = Self.meanInside(out, mask: holeCG, invert: false, side: N)
        Self.healDiagnostics = String(format: "smart: ring %.3f, output hole %.3f, scale %.3f, gpu retry %@", ring, inHole, scale,
                                      retriedOnGPU ? "yes" : "no") + (debug.isEmpty ? "" : "; " + debug)
            + String(format: "; decoded centre %.2f %.2f %.2f", dec[(N / 2) * N + N / 2], dec[N * N + (N / 2) * N + N / 2], dec[2 * N * N + (N / 2) * N + N / 2])
        guard inHole.isFinite, !(ring > 0.06 && inHole < ring * 0.3) else { return nil }

        let id = UUID()
        try? FileManager.default.createDirectory(at: HealStore.directory, withIntermediateDirectories: true)
        do {
            try ctx.writePNGRepresentation(of: out, to: HealStore.patchURL(id), format: .RGBA8, colorSpace: srgb)
            try Self.writeGrayPNG(blend, to: HealStore.maskURL(id))
        } catch { return nil }
        return HealSpot(id: id, strokes: strokes, x: Double(region.minX / W), y: Double(region.minY / H),
                        w: Double(side / W), h: Double(side / H), scale: scale)
    }

    /// 8-bit grey pixels of a mask, top row first.
    static func grayBytes(_ cg: CGImage, _ n: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n * n)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let c = CGContext(data: p.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        return ok ? buf : nil
    }
}
