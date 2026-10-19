import CoreImage
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Heal: paint over something and the on-device LaMa model (large-mask inpainting, Apache-2.0) rebuilds that spot
/// from its surroundings. Lightroom-style: the rebuilt pixels are made once from the full-resolution photo and kept
/// (HealStore), and every decode paints them back in, so preview, 100 % view, export and thumbnails all agree.
extension EditSession {
    /// The model (compiled by CI into the app as LaMa.mlmodelc). Tests point `LUMEN_HEAL_MODEL` at one.
    nonisolated(unsafe) static var healModelURL: URL? = {
        if let p = ProcessInfo.processInfo.environment["LUMEN_HEAL_MODEL"] { return URL(fileURLWithPath: p) }
        return Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc")
    }()
    /// `.all` is what the conversion was verified with. (0.1.137 used .cpuAndGPU: black. The dark fills on red
    /// paint / yellow plates in 0.1.139-145 were not the compute units but the output's alpha channel, see run().)
    private static let healStore = LoadedModel { loadHealModel(.all) }
    private static var healModel: MLModel? { healStore.model }
    /// Full precision, slower: tried when the first answer looks wrong, and let go of straight after.
    private static let healCPUStore = LoadedModel { loadHealModel(.cpuOnly) }
    private static var healModelCPU: MLModel? { healCPUStore.model }
    /// Lets go of the Heal model (hundreds of MB while loaded): when the Heal tool closes or memory runs short.
    /// It loads again the next time Heal is used (quicker than the first time: iOS keeps the compiled copy).
    static func releaseHealModel() {
        healStore.release()
        healCPUStore.release()
        healModelReady = false
    }
    private static func loadHealModel(_ units: MLComputeUnits) -> MLModel? {
        guard let url = healModelURL else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        return try? MLModel(contentsOf: url, configuration: cfg)
    }
    /// Whether this build has the Heal model. Only looks for the file: loading the model compiles it for the GPU,
    /// which takes many seconds the first time (the 1280 px one), and doing that on the main thread froze the app
    /// until iOS closed it (owner, 18 Oct, 0.1.248). Load it with `prepareHealModel()` off the main thread.
    static var hasHealModel: Bool { modelFilesExist(healModelURL) }   // an empty stand-in folder (UI-test builds) has none
    /// Whether the model is loaded and ready (set once `prepareHealModel()` has finished).
    nonisolated(unsafe) static var healModelReady = false
    /// Loads (and on first launch compiles) the Heal model. Slow: call it in the background, early.
    static func prepareHealModel() {
        _ = healModel
        healModelReady = healModel != nil
    }
    /// Called at each step of a heal (app: the diagnostics log; engine test: prints memory), to see where memory goes.
    nonisolated(unsafe) static var healProbe: ((String) -> Void)?
    /// What the last heal measured (engine test diagnostics).
    nonisolated(unsafe) static var healDiagnostics = ""
    nonisolated(unsafe) static var healAlpha: Float = 1
    /// Why the last makeHeal returned nothing (shown to the user).
    nonisolated(unsafe) static var healFailure: HealFailure?
    static func fourCC(_ t: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((t >> $0) & 0xFF) }, encoding: .ascii) ?? "\(t)"
    }

    /// The model's fixed input size, read from the model: 1280 for the Big LaMa CI converts (sharper large removals),
    /// 800 for the older package the build falls back to.
    /// Read from `side.txt`, which CI writes next to the compiled model, so asking doesn't load the model.
    static let healSide: Int = {
        if let url = healModelURL?.appendingPathComponent("side.txt"),
           let text = try? String(contentsOf: url, encoding: .utf8), let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 {
            return n
        }
        return healModel?.modelDescription.inputDescriptionsByName["image"]?.imageConstraint?.pixelsWide ?? 800
    }()

    /// Rebuilds the painted spot. `earlier` = the heals already made (the new one is built on top of them).
    /// Returns nil when the model is missing or fails. Slow (about a second): call off the main thread.
    func makeHeal(strokes: [BrushStroke], earlier: [HealSpot]) -> HealSpot? {
        Self.healFailure = .notAvailable
        guard Self.healModel != nil, !strokes.isEmpty else { return nil }
        let W = nativeSize.width, H = nativeSize.height, L = max(W, H)

        // the painted area in photo pixels (y down), brush radius included
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for st in strokes where !st.erase {
            let r = CGFloat(st.size) * L / 2
            for p in st.points {
                minX = min(minX, CGFloat(p.x) * W - r); maxX = max(maxX, CGFloat(p.x) * W + r)
                minY = min(minY, CGFloat(p.y) * H - r); maxY = max(maxY, CGFloat(p.y) * H + r)
            }
        }
        guard minX.isFinite, maxX > minX, maxY > minY else { return nil }
        let area = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let n = CGFloat(Self.healSide)

        // the hole: the strokes on the 800 x 800 square (white = rebuild), a little wider than painted
        return makeHeal(around: area, earlier: earlier, strokes: strokes, person: nil) { region, k, grow, soften in
            guard let g = CGContext(data: nil, width: Self.healSide, height: Self.healSide, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            g.setFillColor(gray: 0, alpha: 1); g.fill(CGRect(x: 0, y: 0, width: n, height: n))
            g.setLineCap(.round); g.setLineJoin(.round)
            // CGContext rows go up: flip so photo y (down) maps correctly
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
            return self.ctx.createCGImage(ci, from: ci.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
    }

    /// Remove people: rebuilds the area one person (or a group of touching people) covers.
    func makeHeal(person: FoundPerson, earlier: [HealSpot]) -> HealSpot? {
        Self.healFailure = .notAvailable
        guard Self.healModel != nil else { return nil }
        let W = nativeSize.width, H = nativeSize.height
        let b = person.box
        let area = CGRect(x: b.minX * W, y: b.minY * H, width: b.width * W, height: b.height * H)
        let me = person.mask.extent
        // the outline was found on a small copy: one of its pixels covers this many photo pixels
        let coarse = W / max(me.width, 1)
        let n = CGFloat(Self.healSide)
        let sq = CGRect(x: 0, y: 0, width: n, height: n)
        return makeHeal(around: area, earlier: earlier, strokes: [], person: b) { region, k, grow, soften in
            // the person's outline on the 800 x 800 square, widened by the detection's coarseness plus a little
            // (hair and edges the detector misses): a leftover rim of the person is what gives a removal away
            let widen = grow + coarse * k * 1.5 + 0.02 * max(area.width, area.height) * k
            let ciRegion = CGRect(x: region.minX, y: H - region.maxY, width: region.width, height: region.height)
            var m = Self.expandRed(person.mask)
                .transformed(by: CGAffineTransform(translationX: -me.minX, y: -me.minY))
                .transformed(by: CGAffineTransform(scaleX: W / me.width, y: H / me.height))
                .cropped(to: ciRegion)
                .transformed(by: CGAffineTransform(translationX: -ciRegion.minX, y: -ciRegion.minY))
                .transformed(by: CGAffineTransform(scaleX: k, y: k))
            m = m.composited(over: Self.constant(0, sq)).cropped(to: sq)
                .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5])
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: min(widen, 50)])
                .cropped(to: sq)
            if soften > 0 { m = Self.blur(m, soften, sq) }
            return self.ctx.createCGImage(m, from: sq, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
    }

    /// The square the model sees around `area` (photo pixels, y down): 2.4 times the area for context, at least
    /// 192 px, at most the photo's long edge (and twice its short edge). Up to 0.1.158 it could be no bigger than the
    /// short edge, so on a portrait photo anything taller than the photo's width was cut off at the square's top and
    /// bottom (head and legs left behind). Where the square runs past the photo, a mirror image of it fills in.
    /// nil when the area is bigger than any square allowed (only on a very long panorama).
    static func healRegion(around area: CGRect, width W: CGFloat, height H: CGFloat) -> CGRect? {
        let ext = max(area.width, area.height)
        let limit = min(max(W, H), 2 * min(W, H))
        guard ext <= limit + 1 else { return nil }
        let side = min(max(ext * 2.4, 192), limit)
        func place(_ centre: CGFloat, _ size: CGFloat) -> CGFloat {
            let lo = min(0, size - side), hi = max(0, size - side)
            return min(max(centre - side / 2, lo), hi)
        }
        return CGRect(x: place(area.midX, W), y: place(area.midY, H), width: side, height: side)
    }

    /// A mask on the model's square (`region` in photo pixels, y down, `k` square pixels per photo pixel) plus its
    /// mirror images across every photo edge the square runs past, matching `mirrorPadded`'s context there.
    static func withMirrors(_ mask: CGImage, region: CGRect, width W: CGFloat, height H: CGFloat, k: CGFloat, n: CGFloat,
                            ctx: CIContext) -> CGImage {
        let xs: [CGFloat?] = [nil] + (region.minX < 0 ? [0] : []) + (region.maxX > W ? [W] : [])
        let ys: [CGFloat?] = [nil] + (region.minY < 0 ? [0] : []) + (region.maxY > H ? [H] : [])
        guard xs.count > 1 || ys.count > 1 else { return mask }
        let base = CIImage(cgImage: mask, options: [.colorSpace: NSNull()])
        let sq = CGRect(x: 0, y: 0, width: n, height: n)
        var out = base
        for ex in xs {
            for ey in ys where ex != nil || ey != nil {
                // square x: X' = 2(e - minX)k - X; square y (up): Y' = 2n - 2(e - minY)k - Y
                let t = CGAffineTransform(a: ex == nil ? 1 : -1, b: 0, c: 0, d: ey == nil ? 1 : -1,
                                          tx: ex.map { 2 * ($0 - region.minX) * k } ?? 0,
                                          ty: ey.map { 2 * n - 2 * ($0 - region.minY) * k } ?? 0)
                out = base.transformed(by: t).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: out])
            }
        }
        out = out.composited(over: constant(0, sq)).cropped(to: sq)
        return ctx.createCGImage(out, from: sq, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) ?? mask
    }

    /// The brightness (largest colour channel) that 99.5 % of the square stays under, measured on a 64 x 64 copy.
    static func brightEnd(_ img: CIImage, n: CGFloat) -> Float {
        let m = 64
        let small = img.applyingFilter("CIMaximumComponent")
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: CGFloat(m) / n, kCIInputAspectRatioKey: 1.0])
        var px = [Float](repeating: 0, count: m * m * 4)
        LumenGPU.context.render(small, toBitmap: &px, rowBytes: m * 16, bounds: CGRect(x: 0, y: 0, width: m, height: m),
                                format: .RGBAf, colorSpace: nil)
        let v = stride(from: 0, to: px.count, by: 4).map { px[$0] }.filter { $0.isFinite }.sorted()
        guard !v.isEmpty else { return 1 }
        return v[min(v.count - 1, Int(Double(v.count) * 0.995))]
    }

    /// The picture with mirror images of itself all round: context for a square that runs past the photo's edges.
    static func mirrorPadded(_ img: CIImage, about frame: CGRect? = nil) -> CIImage {
        let e = frame ?? img.extent
        var out = img
        for dx in -1...1 {
            for dy in -1...1 where dx != 0 || dy != 0 {
                let t = CGAffineTransform(a: dx == 0 ? 1 : -1, b: 0, c: 0, d: dy == 0 ? 1 : -1,
                                          tx: dx == 0 ? 0 : (dx < 0 ? 2 * e.minX : 2 * e.maxX),
                                          ty: dy == 0 ? 0 : (dy < 0 ? 2 * e.minY : 2 * e.maxY))
                out = img.transformed(by: t).composited(over: out)
            }
        }
        return out
    }

    /// The model run shared by painted fixes and Remove people. `drawHole(region, k, grow, soften)` draws the area
    /// to rebuild on the 800 x 800 square (white), `grow` pixels wider, blurred by `soften`.
    private func makeHeal(around area: CGRect, earlier: [HealSpot], strokes: [BrushStroke], person: CGRect?,
                          hole drawHole: (CGRect, CGFloat, CGFloat, CGFloat) -> CGImage?) -> HealSpot? {
        Self.healFailure = .notAvailable
        guard let model = Self.healModel else { return nil }
        let W = nativeSize.width, H = nativeSize.height

        // 1. a square around the area with plenty of context (the model copies from what it can see)
        Self.healFailure = .tooBig
        guard let region = Self.healRegion(around: area, width: W, height: H) else { return nil }   // y down
        Self.healFailure = .failed
        let side = region.width
        let n = CGFloat(Self.healSide)
        let k = n / side

        // 2. the photo there, full resolution, with the earlier heals, scaled to the model's 800 x 800
        let ciRegion = CGRect(x: region.minX, y: H - region.maxY, width: side, height: side)  // Core Image: y up
        // The full-size decode, as context where the square runs past the photo (mirror image), seen from the square.
        // `scale` < 1 decodes a smaller copy (the square is shrunk to the model's size anyway); the result is in
        // photo pixels either way.
        let picture: (CGFloat) -> (CIImage, CGRect)? = { [self] f in
            let L = max(W, H)
            guard let full = decode(maxEdge: f < 0.95 ? (L * f).rounded(.up) : nil, heals: earlier) else { return nil }
            let d = full.extent, fx = d.width / W, fy = d.height / H
            // the region above was measured on `nativeSize`; it must be the picture as decoded
            guard abs(fx - fy) < 0.01, fx > 0, abs(d.width / fx - W) < 2 / fx + 2 else { return nil }
            // Only the part of the photo inside the square is rendered, once, into a small buffer; the mirror image
            // past the photo's edges is made from that buffer. Mirroring the decode itself made Core Image decode
            // the RAW for each reflected copy (the memory test's 2 GB heal spike).
            let inside = CGRect(x: ciRegion.minX * fx, y: ciRegion.minY * fy, width: ciRegion.width * fx, height: ciRegion.height * fy)
                .intersection(d).integral
            guard inside.width >= 1, inside.height >= 1,
                  let piece = ctx.createCGImage(full, from: inside, format: .RGBAh, colorSpace: LumenGPU.workingSpace) else { return nil }
            let toPhoto = CGAffineTransform(scaleX: 1 / fx, y: 1 / fy)
            let real = CGRect(x: 0, y: 0, width: W, height: H)
            let img = CIImage(cgImage: piece, options: [.colorSpace: LumenGPU.workingSpace])
                .transformed(by: CGAffineTransform(translationX: inside.minX, y: inside.minY)).transformed(by: toPhoto)
            return (real.insetBy(dx: -1, dy: -1).contains(ciRegion) ? img : Self.mirrorPadded(img, about: real), real)
        }
        // Rendered once, at the model's size, in half floats (HDR values above 1 kept), inside this closure so the
        // full-size photo is let go of before the model runs. Before 19 Oct the full-size graph was rendered twice
        // (peak, then the model's input) and kept alive through the model run: one heal peaked at 5.3 GB on a
        // 24 MP photo in the memory test (iPhone limit ~3.4 GB).
        Self.healProbe?("heal: about to decode")
        let rendered: (CGImage, CGRect)? = { [self] in
            // twice the model's resolution is plenty for a sharp downscale, and a 24 MP decode for a big square
            // was most of a heal's memory (2.3 GB spike in the memory test)
            let pic = picture(min(1, 2 * k))
            Self.healProbe?("heal: decoded and the square's part rendered")
            guard case let (photo, real)? = pic,
                  let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
            let lazyCrop = photo.cropped(to: ciRegion)
                .transformed(by: CGAffineTransform(translationX: -ciRegion.minX, y: -ciRegion.minY))
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1.0])
                .cropped(to: CGRect(x: 0, y: 0, width: n, height: n))
            guard let cg = ctx.createCGImage(lazyCrop, from: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBAh, colorSpace: linear)
            else { return nil }
            return (cg, real)
        }()
        ctx.clearCaches()
        guard case let (cropCG, realExtent)? = rendered else { return nil }
        let crop = CIImage(cgImage: cropCG)
        Self.healProbe?("heal: square rendered, full-size photo released")
        // HDR highlights go above 1: squeeze the patch so its brightest pixel is 1 (8-bit for the model), undo later
        var peak = [Float](repeating: 0, count: 4)
        let mx = crop.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: crop.extent)])
        LumenGPU.context.render(mx, toBitmap: &peak, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                format: .RGBAf, colorSpace: nil)
        // Divided by the bright end of the square, not its single brightest pixel: one sun glint at 20x white made the
        // whole square nearly black for the model (code review, 19 Oct). Brighter pixels are clipped for the model;
        // outside the area being rebuilt the photo's own pixels are kept there (see `blend` below).
        let peakScale = Double(max(1, peak[0], peak[1], peak[2]))
        let scale = min(peakScale, max(1, Double(Self.brightEnd(crop, n: n)) * 1.25))
        var input = crop
        if scale > 1 {
            let s = CGFloat(1 / scale)
            input = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0)])
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = ctx.createCGImage(input, from: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBA8, colorSpace: srgb)
        else { return nil }

        // 3. the hole (white = rebuild), and the softer, slightly wider area the result is blended in with
        // Where the square runs past the photo, the context there is a mirror image, so the area to rebuild is
        // mirrored too: otherwise a person at the edge has an unmasked mirror copy right next to the hole and the
        // model paints them back in (code review, 19 Oct).
        let mirrorHole: (CGImage?) -> CGImage? = { img in
            img.flatMap { Self.withMirrors($0, region: region, width: W, height: H, k: k, n: n, ctx: self.ctx) }
        }
        guard let hole = mirrorHole(drawHole(region, k, 6, 0)), var blend = mirrorHole(drawHole(region, k, 10, 4)),
              let outer = mirrorHole(drawHole(region, k, 34, 0)) else { return nil }
        if scale < peakScale - 0.001 {
            // highlights brighter than what the model saw stay the photo's own outside the hole
            let sq = CGRect(x: 0, y: 0, width: n, height: n)
            let high = crop.applyingFilter("CIMaximumComponent")
                .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": scale]).cropped(to: sq)
            let keep = high.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: Self.expandRed(CIImage(cgImage: hole, options: [.colorSpace: NSNull()])).applyingFilter("CIColorInvert")])
            let b = Self.expandRed(CIImage(cgImage: blend, options: [.colorSpace: NSNull()]))
                .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: keep.applyingFilter("CIColorInvert")])
                .cropped(to: sq)
            if let cg = ctx.createCGImage(b, from: sq, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) { blend = cg }
        }

        // 4. the model; an answer that is black (or far darker than its surroundings) inside the hole is a numeric
        //    failure, not a fill: try once more on the CPU, and never keep a broken patch
        func run(_ m: MLModel) -> CIImage? {
            // The pixels go in exactly as they are (sRGB-encoded bytes, mask 0/255). MLFeatureValue(cgImage:)
            // colour-matched them first, so the model saw (and painted) a much darker picture (0.1.139 and before).
            guard let imageC = m.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
                  let maskC = m.modelDescription.inputDescriptionsByName["mask"]?.imageConstraint,
                  let imagePB = Self.pixelBuffer(CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()]),
                                                 format: imageC.pixelFormatType, side: Self.healSide),
                  let maskPB = Self.pixelBuffer(Self.expandRed(CIImage(cgImage: hole, options: [.colorSpace: NSNull()])),
                                                format: maskC.pixelFormatType, side: Self.healSide),
                  case let imageV = MLFeatureValue(pixelBuffer: imagePB),
                  case let maskV = MLFeatureValue(pixelBuffer: maskPB),
                  let features = try? MLDictionaryFeatureProvider(dictionary: ["image": imageV, "mask": maskV]),
                  let result = try? m.prediction(from: features),
                  let buffer = result.featureValue(for: "output")?.imageBufferValue
            else { return nil }
            // The model only paints red, green and blue: on the iPhone the buffer's 4th (alpha) byte is not 255,
            // so the PNG kept a see-through patch and red paint (little blue, hence little "alpha") came out
            // black while white highlights survived (0.1.139-145). The patch is made fully opaque here.
            let raw = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: srgb])
            var lo = [Float](repeating: 0, count: 4)
            let mn = raw.applyingFilter("CIAreaMinimum", parameters: [kCIInputExtentKey: CIVector(cgRect: raw.extent)])
            LumenGPU.context.render(mn, toBitmap: &lo, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    format: .RGBAf, colorSpace: nil)
            Self.healAlpha = lo[3]
            return raw.settingAlphaOne(in: CGRect(x: 0, y: 0, width: n, height: n))
        }
        // what the fill is judged against: the photo right around the spot. (Up to 0.1.159 it was the whole square,
        // so on a dark photo a correct dark fill next to something bright, a white top say, was thrown away.)
        let ring = Self.meanInside(CIImage(cgImage: cgImage), mask: blend, invert: true)
        let band = Self.meanBetween(CIImage(cgImage: cgImage), outer: outer, inner: blend)
        func plausible(_ o: CIImage) -> Bool {
            let inHole = Self.meanInside(o, mask: hole, invert: false)
            return inHole.isFinite && !(band > 0.06 && inHole < band * 0.3)
        }
        Self.healProbe?("heal: input ready")
        var answer = run(model)
        Self.healProbe?("heal: model answered \(answer == nil ? "nothing" : "")")
        if let a = answer {
            Self.healDiagnostics = String(format: "band %.3f, ring %.3f, input hole %.3f, output hole %.3f, output ring %.3f, scale %.3f, raw output min alpha %.3f, square %.0f px, buffer %@",
                                          band, ring, Self.meanInside(CIImage(cgImage: cgImage), mask: hole, invert: false),
                                          Self.meanInside(a, mask: hole, invert: false), Self.meanInside(a, mask: blend, invert: true), scale,
                                          Self.healAlpha, side, Self.fourCC(model.modelDescription.outputDescriptionsByName["output"]?.imageConstraint?.pixelFormatType ?? 0))
        }
        if answer == nil || !plausible(answer!), let cpu = Self.healModelCPU {
            Self.healProbe?("heal: first answer rejected, trying the CPU model")
            answer = run(cpu)
            Self.healCPUStore.release()
        }
        guard let out = answer else { return nil }
        Self.healFailure = .looksWrong
        guard plausible(out) else { return nil }
        Self.healFailure = .failed

        // 5. a square bigger than the model's: keep the patch at (nearly) full resolution, with the photo's own fine
        //    texture, instead of the model's softer answer stretched over it (owner: big removals looked blurry)
        let stored = Self.healDetailEnabled && side > n * 1.05
            ? picture(1).flatMap { Self.detailed(out, photo: $0.0, realExtent: realExtent, region: ciRegion, scale: scale, hole: hole, n: n) } ?? out
            : out

        Self.healProbe?("heal: patch made")
        // 6. keep it: the rebuilt square and where to blend it in, checked again as it will be read back
        let id = UUID()
        try? FileManager.default.createDirectory(at: HealStore.directory, withIntermediateDirectories: true)
        do {
            guard try HealStore.write(id, owner: originalURL, body: {
                try ctx.writePNGRepresentation(of: stored, to: HealStore.patchURL(id), format: .RGBA8, colorSpace: srgb)
                try Self.writeGrayPNG(blend, to: HealStore.maskURL(id))
            }) else { return nil }
        } catch { return nil }
        guard let read = CIImage(contentsOf: HealStore.patchURL(id)), case let back = Self.toModelSide(read, n),
              plausible(back) else {
            HealStore.remove([id])
            return nil
        }
        Self.healFailure = nil
        // the square can run past the photo's edges (x or y below 0, w or h above 1): HealStore crops to the photo
        return HealSpot(id: id, strokes: strokes, x: Double(region.minX / W), y: Double(region.minY / H),
                        w: Double(side / W), h: Double(side / H), scale: scale,
                        person: person.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] })
    }

    /// Full-resolution texture for big heals. OFF since 18 Oct (owner's photos on 0.1.256/0.1.26x): it left a faint
    /// outline of the removed person at the hole's soft edge and could copy the wrong texture. Back to the model's
    /// fill until it is reworked and checked on real photos.
    static let healDetailEnabled = false

    /// Longest side a stored patch is kept at (a 24 MP photo's whole-width square would be a 100 MB PNG).
    static let maxPatchSide: CGFloat = 2560

    /// A patch read back, at the model's size (for the same checks the model's answer passed).
    static func toModelSide(_ img: CIImage, _ n: CGFloat) -> CIImage {
        let e = img.extent
        guard abs(e.width - n) > 0.5 else { return img }
        return img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: n / e.width, kCIInputAspectRatioKey: 1.0])
            .cropped(to: CGRect(x: 0, y: 0, width: n, height: n))
    }

    /// The model's fill (`fill`, n x n, divided by `scale`) at the square's real resolution: its shapes and colours,
    /// plus fine texture (grain, gravel, grass, leaves) copied from the best-matching spot right next to the hole, and
    /// the untouched photo everywhere outside the hole. nil keeps the model's answer as it is.
    /// `photo` may be mirror-padded past the photo's edges (context for the model); texture is only ever copied from
    /// `realExtent`, the real photo. (0.1.256 copied from the mirror image below the photo: a person removed at the
    /// bottom edge came back as a faint upside-down outline of themselves.)
    static func detailed(_ fill: CIImage, photo: CIImage, realExtent: CGRect, region: CGRect, scale: Double, hole: CGImage,
                         n: CGFloat) -> CIImage? {
        guard let kernel = LumenKernels.shared?.healDetail, let energyK = LumenKernels.shared?.healEnergy else { return nil }
        let side = min(region.width, maxPatchSide)
        let toSide = side / region.width            // photo pixels -> stored patch pixels
        let up = side / n                            // model pixels -> stored patch pixels
        let sq = CGRect(x: 0, y: 0, width: side, height: side)
        let inv = CGFloat(1 / scale)
        // the whole photo in patch coordinates (the square at 0,0), divided by scale like the model's input
        var whole = photo.transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
        if toSide < 0.999 {
            whole = whole.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: toSide, kCIInputAspectRatioKey: 1.0])
        }
        whole = whole.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: inv, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: inv, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: inv, w: 0)])
        let photoBox = whole.extent                  // where real photo exists, in patch pixels
        let real = whole.cropped(to: sq)
        let base = fill.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: up, kCIInputAspectRatioKey: 1.0])
            .cropped(to: sq)
        // the detail the model can't give at its size: the photo minus a copy blurred to the model's resolution
        let blurredWhole = whole.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.6 * up])
            .cropped(to: photoBox)

        // where to copy the texture from: the hole moved by about its own size in 8 directions, anywhere in the photo
        // (a big hole leaves no room inside its own square), clear of the hole, closest in colour to the model's fill
        let holeCI = expandRed(CIImage(cgImage: hole, options: [.colorSpace: NSNull()]))
        guard let bbox = holeBox(hole) else { return nil }
        let fillMean = mean(fill, mask: holeCI, area: CGRect(x: 0, y: 0, width: n, height: n))
        // the photo at model scale (model pixels, the square at 0,0) for scoring
        let wholeN = whole.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 1 / up, kCIInputAspectRatioKey: 1.0])
        let k = n / region.width                     // photo pixels -> model pixels
        let photoN = CGRect(x: (realExtent.minX - region.minX) * k, y: (realExtent.minY - region.minY) * k,
                            width: realExtent.width * k, height: realExtent.height * k).insetBy(dx: 2, dy: 2)
        var best: (CGPoint, Float)?
        for f in [1.1, 1.5, 2.0] as [CGFloat] {
            for (ux, uy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1)] as [(CGFloat, CGFloat)] {
                let d = CGPoint(x: ux * bbox.width * f, y: uy * bbox.height * f)
                let moved = bbox.offsetBy(dx: d.x, dy: d.y)
                guard photoN.contains(moved), !moved.intersects(bbox) else { continue }
                let shifted = holeCI.transformed(by: CGAffineTransform(translationX: d.x, y: d.y))
                let m = mean(wholeN, mask: shifted, area: moved)
                let score = zip(m, fillMean).map { abs($0 - $1) }.reduce(0, +)
                if best == nil || score < best!.1 { best = (d, score) }
            }
        }
        guard let (d, _) = best else { healDiagnostics += ", detail: no texture source"; return nil }
        // the copied texture, moved onto the hole (model pixels -> patch pixels), faded in at the hole's edge
        let move = CGAffineTransform(translationX: -d.x * up, y: -d.y * up)
        let tex = whole.transformed(by: move).cropped(to: sq)
        let texBlur = blurredWhole.transformed(by: move).cropped(to: sq)
        let holeUp = holeCI.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: up, kCIInputAspectRatioKey: 1.0])
            .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5 * up]).cropped(to: sq)
        // how much texture the hole's surroundings really have (a lens-blurred background has almost none) against
        // the source's: copy only that much, and never a step bigger than the surroundings' own (no pasted edges)
        let energy = energyK.apply(extent: photoBox, arguments: [whole, blurredWhole]) ?? constant(0, sq)
        let ringN = holeCI.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(4, bbox.width * 0.12)])
        let ringOnly = ringN.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: holeCI])
        let up2 = CGAffineTransform(scaleX: up, y: up)
        let eRing = mean(energy, mask: ringOnly.transformed(by: up2), area: sq)[0]
        let srcMask = holeCI.transformed(by: CGAffineTransform(translationX: d.x, y: d.y)).transformed(by: up2)
        let eSrc = mean(energy, mask: srcMask, area: bbox.offsetBy(dx: d.x, dy: d.y).applying(up2))[0]
        let gain = eSrc > 1e-7 ? min(1, (eRing / eSrc).squareRoot()) : 0
        let maxStep = 2.5 * eRing.squareRoot()
        healDiagnostics += String(format: ", detail from %.0f,%.0f gain %.2f step %.3f", d.x, d.y, gain, maxStep)
        guard gain > 0.05, maxStep > 0.002 else { return base.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: real, kCIInputMaskImageKey: holeUp]).cropped(to: sq) }
        return kernel.apply(extent: sq, arguments: [base, real, tex, texBlur, holeUp,
                                                    CIVector(x: CGFloat(gain), y: CGFloat(maxStep), z: 0, w: 0)])
    }

    /// Mean RGB of `img` where `mask` (red channel) is white, within `area`.
    private static func mean(_ img: CIImage, mask: CIImage, area r: CGRect) -> [Float] {
        let m = mask.composited(over: constant(0, r)).cropped(to: r)
        let w = img.cropped(to: r).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: m])
        var a = [Float](repeating: 0, count: 4), b = [Float](repeating: 0, count: 4)
        LumenGPU.context.render(w.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)]),
                                toBitmap: &a, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        LumenGPU.context.render(m.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)]),
                                toBitmap: &b, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        guard b[0] > 1e-5 else { return [0, 0, 0] }
        return [a[0] / b[0], a[1] / b[0], a[2] / b[0]]
    }


    /// The hole's bounding box in Core Image coordinates (y up) on the n x n square.
    private static func holeBox(_ hole: CGImage) -> CGRect? {
        let w = hole.width, h = hole.height
        var px = [UInt8](repeating: 0, count: w * h)
        guard let g = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        g.draw(hole, in: CGRect(x: 0, y: 0, width: w, height: h))
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where px[y * w + x] > 127 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
        guard x1 >= x0 else { return nil }
        // bitmap rows run top-down here; Core Image counts from the bottom
        return CGRect(x: x0, y: h - 1 - y1, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    /// Renders `img` into a new pixel buffer byte for byte (no colour conversion).
    static func pixelBuffer(_ img: CIImage, format: OSType, side: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                                      kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, side, side, format, attrs as CFDictionary, &pb) == kCVReturnSuccess, let buf = pb
        else { return nil }
        LumenGPU.context.render(img, to: buf, bounds: CGRect(x: 0, y: 0, width: side, height: side), colorSpace: nil)
        return buf
    }

    /// Mean brightness of `img` where `mask` is white (or, with `invert`, where it is black).
    static func meanInside(_ img: CIImage, mask: CGImage, invert: Bool) -> Float {
        let n = CGFloat(healSide)
        var m = expandRed(CIImage(cgImage: mask, options: [.colorSpace: NSNull()]))
        if invert { m = m.applyingFilter("CIColorInvert") }
        let r = CGRect(x: 0, y: 0, width: n, height: n)
        let weighted = img.cropped(to: r).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: m])
        var a = [Float](repeating: 0, count: 4), b = [Float](repeating: 0, count: 4)
        let ea = weighted.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
        let eb = m.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
        LumenGPU.context.render(ea, toBitmap: &a, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        LumenGPU.context.render(eb, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        guard b[0] > 1e-4 else { return 0 }
        return (a[0] + a[1] + a[2]) / 3 / b[0]
    }

    /// Mean brightness of `img` between two masks (where `outer` is white and `inner` is not): the band around a spot.
    static func meanBetween(_ img: CIImage, outer: CGImage, inner: CGImage) -> Float {
        let r = CGRect(x: 0, y: 0, width: CGFloat(healSide), height: CGFloat(healSide))
        func averages(_ mask: CGImage) -> (Float, Float) {
            let m = expandRed(CIImage(cgImage: mask, options: [.colorSpace: NSNull()]))
            let weighted = img.cropped(to: r).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: m])
            var a = [Float](repeating: 0, count: 4), b = [Float](repeating: 0, count: 4)
            let ea = weighted.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
            let eb = m.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
            LumenGPU.context.render(ea, toBitmap: &a, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            LumenGPU.context.render(eb, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return ((a[0] + a[1] + a[2]) / 3, b[0])
        }
        let (so, mo) = averages(outer), (si, mi) = averages(inner)
        guard mo - mi > 1e-4 else { return 0 }
        return (so - si) / (mo - mi)
    }

    static func writeGrayPNG(_ img: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Why a heal could not be made, in words for the Heal panel.
enum HealFailure {
    case notAvailable, tooBig, looksWrong, failed

    var message: String {
        switch self {
        case .notAvailable: "Heal isn't available in this build."
        case .tooBig: "That's too big to remove in one go. Try it in a few smaller pieces."
        case .looksWrong: "The fix came out looking wrong, so it wasn't used. Try painting it again."
        case .failed: "Couldn't remove that one. Try again."
        }
    }
}

/// A person found for Remove people (or a group of people touching each other).
struct FoundPerson: Identifiable, @unchecked Sendable {
    let id: Int
    /// Where they are: fractions of the photo, y down.
    let box: CGRect
    /// How much of the photo they cover (0...1).
    let area: Double
    /// White = this person. Upright, extent (0, 0, w, h) at detection size, covering the whole photo.
    let mask: CIImage
    /// Probably who the photo is of (big, and not much smaller than the biggest person): not picked at first.
    let main: Bool
}

extension EditSession {
    /// Remove people: everyone in the photo (with the heals already made), biggest first. Apple's on-device person
    /// segmentation (the People mask's), split here into separate people. Slow: call off the main thread.
    func findPeople(earlier: [HealSpot]) -> [FoundPerson] {
        // 3072 (was 2048): the quarters and body boxes below look at parts of it, so small people keep some detail
        guard let img = decode(maxEdge: 3072, heals: earlier) else { return [] }
        let e = img.extent
        guard let cg = ctx.createCGImage(img, from: e, format: .RGBA8, colorSpace: LumenGPU.displaySpace) else { return [] }
        // two of Apple's finders, put together: the segmentation (the People mask's) and the per-person one, which
        // on the CI street photo also caught a man cut off by the frame whose top half the segmentation missed
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let instances = VNGeneratePersonInstanceMaskRequest()
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request, instances, bodies])
        // each mask covers the whole photo (whatever its own shape): stretched over it, read back at up to 768 px
        let ext = CGRect(x: 0, y: 0, width: e.width, height: e.height)
        var found: [CIImage] = []
        if let buffer = request.results?.first?.pixelBuffer {
            found.append(Self.fit(Self.expandRed(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])), to: ext))
        }
        if let obs = instances.results?.first, !obs.allInstances.isEmpty,
           let buffer = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
            found.append(Self.fit(Self.expandRed(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])), to: ext))
        }
        // A person the whole-photo pass mostly missed (far away, half hidden; Vision runs it at about 1-2 MP) gets a
        // closer look: segmentation again on a crop around each body the body finder sees, kept inside that body's
        // box so neighbours never merge (owner, 19 Oct: Remove people missed many people). Whole-photo quarters
        // were tried first: their softer edges joined people up into one.
        if let base = found.first {
            for b in (bodies.results ?? []).filter({ $0.confidence > 0.4 }).prefix(24) {
                let r = VNImageRectForNormalizedRect(b.boundingBox, Int(e.width), Int(e.height)).intersection(ext).integral
                guard r.width >= 24, r.height >= 24 else { continue }
                // already found: most of the box's middle is covered
                var v = [Float](repeating: 0, count: 4)
                let mid = r.insetBy(dx: r.width * 0.3, dy: r.height * 0.2)
                let avg = base.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: mid)])
                ctx.render(avg, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                if v[0] > 0.35 { continue }
                let look = r.insetBy(dx: -r.width * 0.25, dy: -r.height * 0.15).intersection(ext).integral
                let top = CGRect(x: look.minX, y: ext.height - look.maxY, width: look.width, height: look.height)   // y down
                guard let part = cg.cropping(to: top) else { continue }
                let seg = VNGeneratePersonSegmentationRequest()
                seg.qualityLevel = .accurate
                seg.outputPixelFormat = kCVPixelFormatType_OneComponent8
                try? VNImageRequestHandler(cgImage: part, options: [:]).perform([seg])
                guard let buffer = seg.results?.first?.pixelBuffer else { continue }
                let m = Self.fit(Self.expandRed(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])), to: look)
                    .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5])
                    .cropped(to: r.insetBy(dx: -r.width * 0.05, dy: -r.height * 0.05))
                found.append(m.composited(over: Self.constant(0, ext)).cropped(to: ext))
            }
        }
        guard var mask = found.first else { return [] }
        for m in found.dropFirst() {
            mask = m.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask]).cropped(to: ext)
        }
        let me = mask.extent
        let s = 1024 / max(e.width, e.height)   // was 768: small people kept as pieces of their own
        let w = max(Int((e.width * s).rounded()), 8), h = max(Int((e.height * s).rounded()), 8)
        let small = mask.transformed(by: CGAffineTransform(translationX: -me.minX, y: -me.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / me.width, y: CGFloat(h) / me.height))
        var px = [UInt8](repeating: 0, count: w * h)
        LumenGPU.context.render(small, toBitmap: &px, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                format: .L8, colorSpace: nil)   // top row first
        return Self.splitPeople(px, width: w, height: h)
    }

    /// Splits a person mask (8-bit, top row first) into separate people. Pieces less than ~1 % of the photo apart
    /// count as one (an arm behind a lamp post stays with its body); crumbs are dropped. Biggest first, at most 30.
    static func splitPeople(_ px: [UInt8], width w: Int, height h: Int) -> [FoundPerson] {
        let n = w * h
        guard n > 0, px.count >= n else { return [] }
        var on = [Bool](repeating: false, count: n)
        var total = 0
        for i in 0..<n where px[i] >= 128 { on[i] = true; total += 1 }
        guard total > 0 else { return [] }
        // widened copy (square, radius r): what is joined up is decided on this
        let r = max(1, Int((Double(max(w, h)) * 0.006).rounded()))
        var rows = [Bool](repeating: false, count: n), grown = [Bool](repeating: false, count: n)
        for y in 0..<h {
            for x in 0..<w where on[y * w + x] {
                for xx in max(0, x - r)...min(w - 1, x + r) { rows[y * w + xx] = true }
            }
        }
        for y in 0..<h {
            for x in 0..<w where rows[y * w + x] {
                for yy in max(0, y - r)...min(h - 1, y + r) { grown[yy * w + x] = true }
            }
        }
        // connected pieces of the widened mask
        var label = [Int32](repeating: 0, count: n)
        struct Piece { var id: Int32; var count = 0; var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1 }
        var pieces: [Piece] = []
        var stack: [Int] = []
        for start in 0..<n where grown[start] && label[start] == 0 {
            var p = Piece(id: Int32(pieces.count + 1))
            label[start] = p.id
            stack.append(start)
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                if on[i] { p.count += 1; p.x0 = min(p.x0, x); p.x1 = max(p.x1, x); p.y0 = min(p.y0, y); p.y1 = max(p.y1, y) }
                if x > 0, grown[i - 1], label[i - 1] == 0 { label[i - 1] = p.id; stack.append(i - 1) }
                if x < w - 1, grown[i + 1], label[i + 1] == 0 { label[i + 1] = p.id; stack.append(i + 1) }
                if y > 0, grown[i - w], label[i - w] == 0 { label[i - w] = p.id; stack.append(i - w) }
                if y < h - 1, grown[i + w], label[i + w] == 0 { label[i + w] = p.id; stack.append(i + w) }
            }
            if p.count >= 20 { pieces.append(p) }
        }
        pieces.sort { $0.count > $1.count }
        pieces = Array(pieces.prefix(30))
        let biggest = Double(pieces.first?.count ?? 1)
        var people: [FoundPerson] = []
        for (k, p) in pieces.enumerated() {
            var bytes = [UInt8](repeating: 0, count: n)
            for i in 0..<n where label[i] == p.id { bytes[i] = 255 }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { continue }
            let area = Double(p.count) / Double(n)
            people.append(FoundPerson(
                id: k,
                box: CGRect(x: Double(p.x0) / Double(w), y: Double(p.y0) / Double(h),
                            width: Double(p.x1 - p.x0 + 1) / Double(w), height: Double(p.y1 - p.y0 + 1) / Double(h)),
                area: area,
                mask: CIImage(cgImage: cg, options: [.colorSpace: NSNull()]),
                main: area >= 0.03 && Double(p.count) >= 0.3 * biggest))
        }
        return people
    }

    /// Remove people: tints `people` on the shown photo (`colour` = r, g, b, strength), lined up with its crop and turns.
    func tintPeople(_ img: CIImage, _ people: [FoundPerson], source: ImageSource, settings: EditSettings,
                    applyCrop: Bool, colour: CIVector) -> CIImage {
        guard let k = LumenKernels.shared, !people.isEmpty else { return img }
        var all: CIImage?
        for p in people {
            let m = Self.fit(Self.expandRed(p.mask), to: source.extent)
            all = all.map { m.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? m
        }
        guard let union = all else { return img }
        return k.overlay.apply(extent: img.extent, arguments: [img, geometry(union, settings, applyCrop: applyCrop), colour]) ?? img
    }
}
