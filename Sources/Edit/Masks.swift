import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Vision
import CoreML

/// Local adjustments. Every mask becomes one grey image (white = fully affected). Each mask's slider offsets are
/// multiplied by that image and summed into five "parameter planes" the develop kernel reads per pixel, so any
/// number of overlapping masks cost almost nothing at render time.
extension EditSession {
    static let aiSubject = "subject"
    static let aiSky = "sky"
    static let aiPeople = "people"
    static let aiDepth = "depth"

    // MARK: Planes

    func localPlanes(_ s: EditSettings, source: ImageSource) -> [CIImage]? {
        guard let k = LumenKernels.shared else { return nil }
        let active = s.masks.filter { !$0.adjust.isNeutral }
        guard !active.isEmpty else { return nil }
        let ext = source.extent
        var planes = (0..<5).map { _ in Self.constant(0, ext) }
        let gain = exp2(s.exposure)
        for m in active {
            guard let mask = maskImage(m, source: source, gain: gain) else { continue }
            let a = m.adjust
            let vs: [CIVector] = [
                CIVector(x: a.exposure / 4, y: a.contrast / 100, z: a.highlights / 100, w: 0),
                CIVector(x: a.shadows / 100, y: a.whites / 100, z: a.blacks / 100, w: 0),
                CIVector(x: a.temperature / 100, y: a.tint / 100, z: a.saturation / 100, w: 0),
                CIVector(x: a.clarity / 100, y: a.texture / 100, z: a.dehaze / 100, w: 0),
                CIVector(x: a.sharpness / 100 * 0.9, y: a.noise / 100, z: 0, w: 0),
            ]
            for i in 0..<5 where vs[i].x != 0 || vs[i].y != 0 || vs[i].z != 0 {
                planes[i] = k.accum.apply(extent: ext, arguments: [planes[i], mask, vs[i]]) ?? planes[i]
            }
        }
        return planes
    }

    // MARK: Mask images

    /// The finished grey image for a whole mask (components combined, inverted, opacity applied).
    func maskImage(_ m: Mask, source: ImageSource, gain: Double) -> CIImage? {
        guard let k = LumenKernels.shared else { return nil }
        var acc: CIImage?
        for c in m.components {
            var ci = componentImage(c, source: source, gain: gain)
            if c.invert { ci = k.maskFinish.apply(extent: source.extent, arguments: [ci, CIVector(x: 1, y: 1, z: 0, w: 0)]) ?? ci }
            if c.amount < 100 {
                // this part only, before it is combined: a 50 % Subtract takes away half, the rest stays untouched;
                // a 50 % Intersect trims half as much (1 - t·(1 - b))
                let t = max(c.amount, 0) / 100
                if c.op == .intersect && acc != nil {
                    let cut = k.maskFinish.apply(extent: source.extent, arguments: [ci, CIVector(x: 1, y: t, z: 0, w: 0)]) ?? ci
                    ci = k.maskFinish.apply(extent: source.extent, arguments: [cut, CIVector(x: 1, y: 1, z: 0, w: 0)]) ?? ci
                } else {
                    ci = k.maskFinish.apply(extent: source.extent, arguments: [ci, CIVector(x: 0, y: t, z: 0, w: 0)]) ?? ci
                }
            }
            if let a = acc {
                let op: Double = c.op == .add ? 0 : (c.op == .subtract ? 1 : 2)
                acc = k.combine.apply(extent: source.extent, arguments: [a, ci, CIVector(x: op, y: 0, z: 0, w: 0)])
            } else {
                acc = ci
            }
        }
        guard let a = acc else { return nil }
        if m.invert || m.amount < 100 {
            return k.maskFinish.apply(extent: source.extent,
                                      arguments: [a, CIVector(x: m.invert ? 1 : 0, y: m.amount / 100, z: 0, w: 0)]) ?? a
        }
        return a
    }

    /// Red tint over `img` showing where `mask` applies.
    /// `settings`: the edits whose turns / straighten / crop the shown photo has, so the overlay lines up with it.
    func overlay(_ img: CIImage, mask: Mask, source: ImageSource, gain: Double, settings: EditSettings? = nil,
                 applyCrop: Bool = true) -> CIImage {
        guard let k = LumenKernels.shared, var m = maskImage(mask, source: source, gain: gain) else { return img }
        if let settings { m = geometry(m, settings, applyCrop: applyCrop) }
        return k.overlay.apply(extent: img.extent, arguments: [img, m, CIVector(x: 1.0, y: 0.1, z: 0.12, w: 0.55)]) ?? img
    }

    private static func pixel(_ x: Double, _ y: Double, _ ext: CGRect) -> CGPoint {
        CGPoint(x: ext.minX + CGFloat(x) * ext.width, y: ext.minY + CGFloat(1 - y) * ext.height)
    }

    func componentImage(_ c: MaskComponent, source: ImageSource, gain: Double) -> CIImage {
        let k = LumenKernels.shared!
        let ext = source.extent
        let zero = Self.constant(0, ext)
        var img: CIImage
        switch c.kind {
        case .linear:
            let a = Self.pixel(c.x0, c.y0, ext), b = Self.pixel(c.x1, c.y1, ext)
            img = k.linearMask.apply(extent: ext, arguments: [source.base,
                                                              CIVector(x: a.x, y: a.y, z: b.x, w: b.y),
                                                              CIVector(x: 0, y: 0, z: 0, w: 0)]) ?? zero
        case .radial:
            let ctr = Self.pixel(c.x0, c.y0, ext)
            let ang = -c.angle * .pi / 180   // UI angle is clockwise on screen
            img = k.radialMask.apply(extent: ext, arguments: [
                source.base,
                CIVector(x: ctr.x, y: ctr.y, z: max(0.01, c.x1) * ext.width, w: max(0.01, c.y1) * ext.height),
                CIVector(x: cos(ang), y: sin(ang), z: c.feather / 100, w: 0)]) ?? zero
        case .brush:
            img = brushImage(c, source: source) ?? zero
        case .subject:
            img = source.cachedMask(Self.aiSubject) ?? zero
        case .background:
            // everything that is not the subject; when no subject was found, that is the whole photo
            if let subject = source.cachedMask(Self.aiSubject) {
                img = k.maskFinish.apply(extent: ext, arguments: [subject, CIVector(x: 1, y: 1, z: 0, w: 0)]) ?? subject
            } else if source.hasTried(Self.aiSubject) {
                img = Self.constant(1, ext)
            } else {
                img = zero   // still looking
            }
        case .sky:
            img = source.cachedMask(Self.aiSky) ?? zero
        case .people:
            img = source.cachedMask(Self.aiPeople) ?? zero
        case .luminance:
            img = k.lumMask.apply(extent: ext, arguments: [
                source.base,
                CIVector(x: c.lumLow, y: c.lumHigh, z: c.lumLowFeather, w: c.lumHighFeather),
                CIVector(x: gain, y: 0, z: 0, w: 0)]) ?? zero
        case .depth:
            if let d = source.cachedMask(Self.aiDepth), let rk = k.rangeMask {
                img = rk.apply(extent: ext, arguments: [d, CIVector(x: c.lumLow, y: c.lumHigh, z: c.lumLowFeather, w: c.lumHighFeather)]) ?? zero
            } else {
                img = zero   // still estimating, or no depth model in this build
            }
        case .color:
            var vs = [CIVector](repeating: CIVector(x: 0, y: 0, z: 0, w: 0), count: 4)
            for (i, smp) in c.samples.prefix(4).enumerated() {
                let lab = Self.lab(of: SIMD3(Float(smp.r), Float(smp.g), Float(smp.b)), gain: gain)
                vs[i] = CIVector(x: Double(lab.0), y: Double(lab.1), z: Double(lab.2), w: 1)
            }
            img = k.colorMask.apply(extent: ext, arguments: [
                source.base, vs[0], vs[1], vs[2], vs[3],
                CIVector(x: c.tolerance, y: 0.3 + c.feather / 100 * 0.7, z: 0, w: 0),
                CIVector(x: gain, y: 0, z: 0, w: 0)]) ?? zero
        }
        if c.kind.isAutomatic, c.feather > 0 {
            img = Self.blur(img, c.feather / 100 * 0.006 * source.longEdge, ext)
        }
        return img
    }

    /// OkLab of a linear colour after the same soft compression the colour-range kernel uses.
    static func lab(of rgb: SIMD3<Float>, gain: Double) -> (Float, Float, Float) {
        let c = SIMD3(max(rgb.x * Float(gain), 0), max(rgb.y * Float(gain), 0), max(rgb.z * Float(gain), 0))
        let t = c / (SIMD3<Float>(1, 1, 1) + c)
        return Ok.toLab(t.x, t.y, t.z)
    }

    // MARK: Brush

    private func brushImage(_ c: MaskComponent, source: ImageSource) -> CIImage? {
        if let hit = source.cachedRaster(c) { return hit }
        let ext = source.extent
        let longSide = max(ext.width, ext.height)
        let mw = max(1, Int(1024 * ext.width / longSide))
        let mh = max(1, Int(1024 * ext.height / longSide))
        let side = CGFloat(max(mw, mh))
        let refPoints: [Pt] = c.strokes.filter { !$0.erase }.flatMap(\.points)

        /// Draws strokes into a black mask (paint = white, erase = black) and softens it by `feather`.
        func layer(_ strokes: [BrushStroke], feather: Double, eraseAsWhite: Bool = false) -> CIImage? {
            guard let gctx = CGContext(data: nil, width: mw, height: mh, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceGray(),
                                       bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            gctx.setFillColor(gray: 0, alpha: 1)
            gctx.fill(CGRect(x: 0, y: 0, width: mw, height: mh))
            gctx.setLineCap(.round)
            gctx.setLineJoin(.round)
            func cg(_ p: Pt) -> CGPoint { CGPoint(x: CGFloat(p.x) * CGFloat(mw), y: CGFloat(1 - p.y) * CGFloat(mh)) }
            for st in strokes {
                guard let first = st.points.first else { continue }
                gctx.setStrokeColor(gray: (st.erase && !eraseAsWhite) ? 0 : 1, alpha: 1)
                gctx.setLineWidth(max(1, CGFloat(st.size) * side))
                gctx.beginPath()
                gctx.move(to: cg(first))
                gctx.addLine(to: cg(first))
                for p in st.points.dropFirst() { gctx.addLine(to: cg(p)) }
                gctx.strokePath()
            }
            guard let image = gctx.makeImage() else { return nil }
            var ci = Self.expandRed(CIImage(cgImage: image, options: [.colorSpace: NSNull()]))
            let blurRadius = feather / 100 * 0.03 * Double(side)
            if blurRadius > 0.5 { ci = Self.blur(ci, CGFloat(blurRadius), ci.extent) }
            return ci
        }

        // Each stroke keeps the softness it was painted with (older strokes follow the component's Feather).
        let feathers = c.strokes.map { $0.feather ?? c.feather }
        var maskImage: CIImage?
        if Set(feathers).count <= 1 {
            // one softness for everything: draw all strokes together, exactly as before
            maskImage = layer(c.strokes, feather: feathers.first ?? c.feather)
        } else {
            // softness changed between strokes: soften each run of strokes on its own, then combine them in order
            // (paint runs are added, erase runs cut away what was painted before them)
            var acc: CIImage?
            var i = 0
            while i < c.strokes.count {
                var j = i + 1
                while j < c.strokes.count, c.strokes[j].erase == c.strokes[i].erase, feathers[j] == feathers[i] { j += 1 }
                let run = Array(c.strokes[i..<j])
                if let img = layer(run, feather: feathers[i], eraseAsWhite: run[0].erase) {
                    let base = acc ?? Self.constant(0, img.extent)
                    if run[0].erase {
                        let keep = img.applyingFilter("CIColorInvert")
                        acc = keep.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: base])
                            .cropped(to: img.extent)
                    } else {
                        acc = img.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: base])
                            .cropped(to: img.extent)
                    }
                }
                i = j
            }
            maskImage = acc
        }
        guard let ci = maskImage else { return nil }
        var out = Self.fit(ci, to: ext)

        if c.autoMask, !refPoints.isEmpty, let k = LumenKernels.shared {
            // Edge-aware: keep only pixels whose colour resembles what was painted over.
            var sum = SIMD3<Float>(0, 0, 0)
            let step = max(1, refPoints.count / 24)
            var n: Float = 0
            for (i, p) in refPoints.enumerated() where i % step == 0 {
                sum += source.stats.average(atNormalized: p.x, p.y, radius: 1)
                n += 1
            }
            let lab = Self.lab(of: sum / max(n, 1), gain: 1)
            let sim = k.similarMask.apply(extent: ext, arguments: [
                source.base, CIVector(x: Double(lab.0), y: Double(lab.1), z: Double(lab.2), w: 0.16)])
            if let sim { out = k.maskMul.apply(extent: ext, arguments: [out, sim]) ?? out }
        }
        source.storeRaster(c, out)
        return out
    }

    /// Single-channel images come in as (v,0,0); copy red into all channels and make it opaque.
    static func expandRed(_ i: CIImage) -> CIImage {
        let v = CIVector(x: 1, y: 0, z: 0, w: 0)
        return i.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v, "inputGVector": v, "inputBVector": v,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).cropped(to: i.extent)
    }

    static func fit(_ img: CIImage, to ext: CGRect) -> CIImage {
        let e = img.extent
        return img
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: ext.width / e.width, y: ext.height / e.height))
            .transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY))
    }

    // MARK: Automatic masks (subject, sky)

    /// Computes any automatic masks `s` needs and caches them on `source`. Call off the main thread.
    @discardableResult
    func prepareAutoMasks(_ s: EditSettings, source: ImageSource) -> Bool {
        var needSubject = false, needSky = false, needPeople = false, needDepth = false
        for m in s.masks {
            for c in m.components {
                if c.kind == .subject || c.kind == .background { needSubject = true }
                if c.kind == .sky { needSky = true }
                if c.kind == .people { needPeople = true }
                if c.kind == .depth { needDepth = true }
            }
        }
        var computed = false
        if needSubject, !source.hasTried(Self.aiSubject) {
            source.storeMask(Self.aiSubject, refined(computeSubject(source), source: source))
            computed = true
        }
        if needSky, !source.hasTried(Self.aiSky) {
            source.storeMask(Self.aiSky, refined(computeSky(source), source: source))
            computed = true
        }
        if needPeople, !source.hasTried(Self.aiPeople) {
            source.storeMask(Self.aiPeople, refined(computePeople(source), source: source))
            computed = true
        }
        if needDepth, !source.hasTried(Self.aiDepth) {
            let field = computeDepth(source)
            source.storeDepth(field)
            source.storeMask(Self.aiDepth, refined(field.map { Self.depthImage($0, extent: source.extent) }, source: source, depth: true))
            computed = true
        }
        return computed
    }

    /// Auto-level: Apple's on-device horizon detection (Vision) on the photo as turned on screen. Returns the
    /// Straighten value (degrees, clockwise) that levels it, or nil when no horizon was found.
    func levelAngle(_ source: ImageSource, quarterTurns: Int) -> Double? {
        var img = source.base
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns != 0 { img = Self.normalized(Self.rotateAboutCenter(img, by: -CGFloat(turns) * .pi / 2)) }
        return levelAngle(of: img)
    }

    /// The Straighten value (degrees, clockwise) that levels `image`'s horizon, or nil.
    func levelAngle(of image: CIImage) -> Double? {
        let ext = image.extent
        let k = min(1, 1024 / max(ext.width, ext.height))
        let small = Self.normalized(image.transformed(by: CGAffineTransform(scaleX: k, y: k)))
        guard let cg = ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace)
        else { return nil }
        // 1. A real horizon (sea, skyline, field edge): Apple's on-device horizon detection
        let request = VNDetectHorizonRequest()
        if (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])) != nil,
           let obs = request.results?.first {
            // Vision's angle is the turn that levels the photo, anticlockwise positive; Straighten is clockwise
            // positive, hence the minus (checked by the engine test on tilted synthetic scenes)
            let deg = -Double(obs.angle) * 180 / .pi
            if abs(deg) <= 20 { return (deg * 10).rounded() / 10 }
        }
        // 2. No horizon (buildings, cars, interiors): level the photo's straight edges instead
        return edgeLevel(of: small)
    }

    /// Edge levelling, refined: measure, turn by it, measure what is left, until the edges read level (the pixel grid
    /// pulls a single measurement slightly towards level, so one pass under-turns).
    func edgeLevel(of image: CIImage) -> Double? {
        func measure(_ img: CIImage) -> Double? {
            guard let cg = ctx.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace)
            else { return nil }
            return Self.edgeLevelAngle(cg)
        }
        guard var total = measure(image) else { return nil }
        for _ in 0..<3 where abs(total) <= 20 {
            var s = EditSettings()
            s.straighten = total
            guard let rest = measure(geometry(image, s)), abs(rest) >= 0.15 else { break }
            total += rest
        }
        guard abs(total) <= 20 else { return nil }
        return (total * 10).rounded() / 10
    }

    /// Finds the small turn (up to 20°) that makes the photo's strongest straight edges horizontal or vertical,
    /// like Lightroom's Level. Edges are measured with a Sobel filter; their directions, folded so verticals and
    /// horizontals agree, are voted into a histogram weighted by edge strength; the clear peak is the tilt.
    static func edgeLevelAngle(_ cg: CGImage) -> Double? {
        let w = min(cg.width, 640), h = max(1, cg.height * w / max(cg.width, 1))
        guard w > 16, h > 16,
              let gctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        gctx.interpolationQuality = .medium
        gctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = gctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)
        func v(_ x: Int, _ y: Int) -> Float { Float(px[y * w + x]) }

        // gradients (rows as stored: y down)
        var mags: [Float] = [], dirs: [Float] = []
        mags.reserveCapacity(w * h / 4); dirs.reserveCapacity(w * h / 4)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let gx = (v(x + 1, y - 1) + 2 * v(x + 1, y) + v(x + 1, y + 1)) - (v(x - 1, y - 1) + 2 * v(x - 1, y) + v(x - 1, y + 1))
                let gy = (v(x - 1, y + 1) + 2 * v(x, y + 1) + v(x + 1, y + 1)) - (v(x - 1, y - 1) + 2 * v(x, y - 1) + v(x + 1, y - 1))
                let m = (gx * gx + gy * gy).squareRoot()
                if m > 60 { mags.append(m); dirs.append(atan2(gy, gx)) }
            }
        }
        guard mags.count > 200 else { return nil }
        // only the strongest edges vote
        let cut = mags.sorted()[mags.count * 3 / 4]
        let bins = 160                      // 0.25° each over -20...20°
        var hist = [Float](repeating: 0, count: bins)
        var total: Float = 0
        for i in mags.indices where mags[i] >= cut {
            var a = dirs[i] * 180 / .pi                    // -180...180
            a = a - 90 * (a / 90).rounded()                // fold to -45...45: 0 = level edge
            guard abs(a) < 20 else { continue }
            let b = Int((a + 20) / 40 * Float(bins))
            hist[min(max(b, 0), bins - 1)] += mags[i]
            total += mags[i]
        }
        guard total > 0 else { return nil }
        // smooth over ±1°, then the peak must clearly stand out from an even spread
        var smooth = [Float](repeating: 0, count: bins)
        for i in 0..<bins {
            var s: Float = 0
            for k in -4...4 { let j = i + k; if j >= 0 && j < bins { s += hist[j] * Float(5 - abs(k)) } }
            smooth[i] = s
        }
        guard let peak = smooth.indices.max(by: { smooth[$0] < smooth[$1] }) else { return nil }
        let mean = smooth.reduce(0, +) / Float(bins)
        guard smooth[peak] > mean * 2.2 else { return nil }
        let tilt = (Double(peak) + 0.5) / Double(bins) * 40 - 20     // degrees, image rows going down
        // rows run downwards, so an edge tilted anticlockwise on screen reads as a negative angle here; the
        // clockwise turn that levels it (Straighten) is therefore -tilt (checked by the engine test)
        let straighten = -tilt
        guard abs(straighten) >= 0.2 else { return 0 }
        return (straighten * 10).rounded() / 10
    }

    /// Apple's on-device person segmentation (Vision): every person in the photo, hair and clothes included.
    /// nil when nobody was found.
    func computePeople(_ source: ImageSource) -> CIImage? {
        let ext = source.extent
        let k = min(1, 1024 / max(ext.width, ext.height))
        let small = Self.normalized(source.base.transformed(by: CGAffineTransform(scaleX: k, y: k)))
        guard let cg = ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace)
        else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do { try handler.perform([request]) } catch { return nil }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        var ci = Self.expandRed(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]))
        // nobody there: the mask is (almost) all black
        let probe = ci.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        var px = [Float](repeating: 0, count: 4)
        LumenGPU.context.render(probe, toBitmap: &px, rowBytes: 16, bounds: probe.extent,
                                format: .RGBAf, colorSpace: nil)
        guard px[0] > 0.2 else { return nil }
        ci = Self.blur(ci, 1.0, ci.extent)
        if let m = Self.materialized(ci) { ci = m }
        return Self.fit(ci, to: ext)
    }

    // MARK: Edge refinement

    /// Snaps a soft AI mask onto the photo's real edges (guided filter, guide = the photo's brightness), then keeps
    /// the result as a finished 8-bit image so it costs nothing while editing. The AI models work on small copies
    /// (Vision ~1024 px, depth 518 px), so without this their outlines are blurry when zoomed in.
    /// `depth`: a smooth depth map, refined more gently (a larger window keeps distances from following textures).
    func refined(_ mask: CIImage?, source: ImageSource, depth: Bool = false) -> CIImage? {
        guard let mask else { return nil }
        guard let k = LumenKernels.shared, let pack = k.gfPack, let coef = k.gfCoef, let apply = k.gfApply else { return mask }
        let ext = source.extent
        // the window must reach across the mask's soft zone: Vision masks come from ~1024 px (about 2.5x smaller than
        // the preview), depth from 518 px (about 5x)
        // (a guided filter only restores the edge fully when its window is ~3x wider than the soft zone)
        let r = max(4, source.longEdge * (depth ? 0.014 : 0.008))
        let eps = depth ? 0.004 : 0.0015
        func box(_ i: CIImage) -> CIImage {
            i.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: r]).cropped(to: ext)
        }
        guard let packed = pack.apply(extent: ext, arguments: [source.base, mask, CIVector(x: 0, y: 0, z: 0, w: 0)]),
              let packedIP = pack.apply(extent: ext, arguments: [source.base, mask, CIVector(x: 1, y: 0, z: 0, w: 0)]),
              let ab = coef.apply(extent: ext, arguments: [box(packed), box(packedIP), CIVector(x: eps, y: 0, z: 0, w: 0)]),
              let q = apply.apply(extent: ext, arguments: [box(ab), source.base])
        else { return mask }
        return Self.materializedMask(q) ?? Self.materialized(q) ?? q
    }

    /// Renders a grey mask into an 8-bit single-channel buffer (a quarter of the memory of a half-float RGBA one).
    static func materializedMask(_ img: CIImage) -> CIImage? {
        let e = img.extent
        let w = Int(e.width.rounded()), h = Int(e.height.rounded())
        guard w > 0, h > 0 else { return nil }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                                      kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_OneComponent8, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }
        LumenGPU.context.render(img, to: buf, bounds: CGRect(x: e.minX, y: e.minY, width: CGFloat(w), height: CGFloat(h)),
                                colorSpace: nil)
        let out = expandRed(CIImage(cvPixelBuffer: buf, options: [.colorSpace: NSNull()]))
        return out.transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
    }

    // MARK: Depth

    /// The depth model (Depth Anything V2 small, Apple's Core ML conversion), compiled into the app by CI.
    /// Tests can point `LUMEN_DEPTH_MODEL` at a compiled .mlmodelc. nil when this build has no model.
    nonisolated(unsafe) static var depthModelURL: URL? = {
        if let p = ProcessInfo.processInfo.environment["LUMEN_DEPTH_MODEL"] { return URL(fileURLWithPath: p) }
        return Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc")
    }()
    private static let depthModel: VNCoreMLModel? = {
        guard let url = depthModelURL else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        guard let ml = try? MLModel(contentsOf: url, configuration: cfg) else { return nil }
        return try? VNCoreMLModel(for: ml)
    }()
    static var hasDepthModel: Bool { depthModel != nil }

    /// Estimates how far away every part of the photo is (on-device, any photo, no depth data needed).
    /// The model sees a landscape frame, so portrait photos are turned a quarter for it and the result turned back.
    func computeDepth(_ source: ImageSource) -> DepthField? {
        guard let model = Self.depthModel else { return nil }
        let ext = source.extent
        let k = min(1, 1024 / max(ext.width, ext.height))
        var small = Self.normalized(source.base.transformed(by: CGAffineTransform(scaleX: k, y: k)))
        let portrait = ext.height > ext.width
        if portrait { small = Self.normalized(small.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))) }
        guard let cg = ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace)
        else { return nil }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request]) } catch { return nil }
        guard let obs = request.results?.first as? VNPixelBufferObservation else { return nil }
        var out = CIImage(cvPixelBuffer: obs.pixelBuffer, options: [.colorSpace: NSNull()])
        if portrait { out = Self.normalized(out.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))) }
        let w = Int(out.extent.width.rounded()), h = Int(out.extent.height.rounded())
        guard w > 1, h > 1 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        LumenGPU.context.render(out, toBitmap: &px, rowBytes: w * 16, bounds: out.extent, format: .RGBAf, colorSpace: nil)
        // the model gives relative nearness (bigger = nearer); spread the 2nd...98th percentile over 0...1, then flip
        // so 0 = nearest. render(toBitmap:) writes the top row first, which is how the field is stored.
        var raw = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { raw[i] = px[i * 4] }
        let sorted = raw.sorted()
        let lo = sorted[sorted.count * 2 / 100], hi = sorted[sorted.count * 98 / 100]
        guard hi - lo > 1e-6 else { return nil }
        var hist = [Float](repeating: 0, count: 64)
        let values = raw.map { v -> Float in
            let d = 1 - min(max((v - lo) / (hi - lo), 0), 1)
            hist[min(Int(d * 64), 63)] += 1
            return d
        }
        let top = max(hist.max() ?? 1, 1)
        return DepthField(width: w, height: h, values: values, histogram: hist.map { $0 / top })
    }

    /// The depth field as a grey image over the photo (white = far), slightly softened.
    static func depthImage(_ d: DepthField, extent ext: CGRect) -> CIImage {
        // bitmap data is read top row first, like the field
        let data = d.values.withUnsafeBufferPointer { Data(buffer: $0) }
        var ci = CIImage(bitmapData: data, bytesPerRow: d.width * 4, size: CGSize(width: d.width, height: d.height),
                         format: .Rf, colorSpace: nil)
        ci = expandRed(ci)
        ci = blur(ci, 0.8, ci.extent)
        if let m = materialized(ci) { ci = m }
        return fit(ci, to: ext)
    }

    /// Apple's on-device foreground segmentation (Vision, iOS 17+).
    private func computeSubject(_ source: ImageSource) -> CIImage? {
        let ext = source.extent
        let k = min(1, 1024 / max(ext.width, ext.height))
        let small = Self.normalized(source.base.transformed(by: CGAffineTransform(scaleX: k, y: k)))
        guard let cg = ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace)
        else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first,
              let buffer = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        else { return nil }
        var ci = Self.expandRed(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]))
        ci = Self.blur(ci, 1.2, ci.extent)
        if let m = Self.materialized(ci) { ci = m }
        return Self.fit(ci, to: ext)
    }
}
