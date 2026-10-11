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
    static let aiScene = "scene"
    static func sceneKey(_ parts: [String]) -> String { "scene:" + parts.sorted().joined(separator: "+") }

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
        case .landscape:
            img = c.scene.isEmpty ? zero : (source.cachedMask(Self.sceneKey(c.scene)) ?? zero)
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
        var sceneSets: Set<[String]> = []
        for m in s.masks {
            for c in m.components {
                if c.kind == .subject || c.kind == .background { needSubject = true }
                if c.kind == .sky { needSky = true }
                if c.kind == .people { needPeople = true }
                if c.kind == .depth { needDepth = true }
                if c.kind == .landscape, !c.scene.isEmpty { sceneSets.insert(c.scene.sorted()) }
            }
        }
        var computed = false
        if needSubject, !source.hasTried(Self.aiSubject) {
            source.storeMask(Self.aiSubject, refined(computeSubject(source), source: source))
            computed = true
        }
        // the scene model (one run) serves both the Sky mask and every Landscape part
        // (and the Depth mask: the sky it finds is always the farthest thing)
        if (needSky || needDepth || !sceneSets.isEmpty || s.masks.contains { $0.components.contains { $0.kind == .landscape } }),
           !source.hasTried(Self.aiScene) {
            source.storeScene(computeScene(source))
            source.storeMask(Self.aiScene, nil)
            computed = true
        }
        // the sky is also worked out for Landscape parts: they are kept off it (Vegetation stops where the sky seen
        // through the leaves starts)
        let depthWantsSky = needDepth && !source.hasTried(Self.aiDepth) && source.sceneField?.found.contains(.sky) == true
        if needSky || !sceneSets.isEmpty || depthWantsSky, !source.hasTried(Self.aiSky) {
            if let global = source.sceneField, global.found.contains(.sky) {
                // finer at the sky's edge (four quarters), then the sky seen through trees
                let scene = skyScene(global, source: source) ?? global
                source.storeMask(Self.aiSky, sceneMask([.sky], scene, source: source).map { skyThroughTrees($0, scene: scene, source: source) })
            } else {
                // no scene model in this build, or it saw no sky: the classical finder has a go
                source.storeMask(Self.aiSky, refined(computeSky(source), source: source))
            }
            computed = true
        }
        for parts in sceneSets {
            let key = Self.sceneKey(parts)
            guard !source.hasTried(key) else { continue }
            let ps = parts.compactMap(ScenePart.init(rawValue:))
            source.storeMask(key, source.sceneField.flatMap { landscapeMask(ps, $0, source: source) })
            computed = true
        }
        if needPeople, !source.hasTried(Self.aiPeople) {
            source.storeMask(Self.aiPeople, refined(computePeople(source), source: source))
            computed = true
        }
        if needDepth, !source.hasTried(Self.aiDepth) {
            var field = computeDepth(source)
            // the sky is always the farthest thing: the depth AI sometimes gives patches of it nearer distances, so
            // "Far" missed bits of sky and "Near" leaked into it (owner's idea list, 2026-10-12)
            if let f = field, source.sceneField?.found.contains(.sky) == true, let sky = source.cachedMask(Self.aiSky) {
                field = Self.skyFar(f, sky: sky)
            }
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
              let q = apply.apply(extent: ext, arguments: [box(ab), source.base,
                                                          depth ? CIVector(x: 0, y: 1, z: 0, w: 0) : CIVector(x: 0.12, y: 1 / 0.76, z: 0, w: 0)])
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

    // MARK: Scene (Sky and Landscape)

    nonisolated(unsafe) static var sceneModelURL: URL? = {
        if let p = ProcessInfo.processInfo.environment["LUMEN_SEG_MODEL"] { return URL(fileURLWithPath: p) }
        return Bundle.main.url(forResource: "DETRResnet50SemanticSegmentationF16", withExtension: "mlmodelc")
    }()
    private static let sceneModel: VNCoreMLModel? = {
        guard let url = sceneModelURL else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        guard let ml = try? MLModel(contentsOf: url, configuration: cfg) else { return nil }
        return try? VNCoreMLModel(for: ml)
    }()
    static var hasSceneModel: Bool { sceneModel != nil }

    /// Labels every part of the photo (sky, water, trees, buildings, road, ...) with Apple's on-device DETR
    /// segmentation model (448 x 448, the photo stretched to fit).
    func computeScene(_ source: ImageSource) -> SceneField? {
        guard let model = Self.sceneModel else { return nil }
        let ext = source.extent
        let k = min(1, 1024 / max(ext.width, ext.height))
        let small = Self.normalized(source.base.transformed(by: CGAffineTransform(scaleX: k, y: k)))
        guard let cg = ctx.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace),
              let run = Self.runScene(model, cg) else { return nil }
        let (w, h, labels) = run
        var counts: [Int32: Int] = [:]
        for l in labels { counts[l, default: 0] += 1 }
        let minCells = w * h / 300   // a part must cover at least ~0.3 % of the photo to count as found
        let found = Set(ScenePart.allCases.filter { p in p.classes.reduce(0) { $0 + (counts[$1] ?? 0) } >= minCells })
        return SceneField(width: w, height: h, labels: labels, found: found)
    }

    /// One or more Landscape parts as a mask over the photo, edges snapped onto the photo's real edges.
    func sceneMask(_ parts: [ScenePart], _ scene: SceneField, source: ImageSource) -> CIImage? {
        let cover = scene.coverage(parts)
        guard cover.contains(where: { $0 > 0 }) else { return nil }
        let data = cover.withUnsafeBufferPointer { Data(buffer: $0) }
        var ci = CIImage(bitmapData: data, bytesPerRow: scene.width * 4, size: CGSize(width: scene.width, height: scene.height),
                         format: .Rf, colorSpace: nil)
        ci = Self.expandRed(ci)
        ci = Self.blur(ci, 0.7, ci.extent)
        if let m = Self.materialized(ci) { ci = m }
        return refined(Self.fit(ci, to: source.extent), source: source)
    }

    /// One run of the scene model: its labels (row 0 = the top of `cg`, which is stretched to the model's square).
    private static func runScene(_ model: VNCoreMLModel, _ cg: CGImage) -> (Int, Int, [Int32])? {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request]) } catch { return nil }
        guard let obs = request.results?.first as? VNCoreMLFeatureValueObservation,
              let arr = obs.featureValue.multiArrayValue, arr.shape.count >= 2 else { return nil }
        let h = arr.shape[arr.shape.count - 2].intValue, w = arr.shape[arr.shape.count - 1].intValue
        guard w > 1, h > 1, arr.count >= w * h else { return nil }
        var labels = [Int32](repeating: 0, count: w * h)
        if arr.dataType == .int32 {
            let p = arr.dataPointer.bindMemory(to: Int32.self, capacity: w * h)
            for i in 0..<(w * h) { labels[i] = p[i] }
        } else {
            for i in 0..<(w * h) { labels[i] = arr[i].int32Value }
        }
        return (w, h, labels)
    }

    /// A finer scene for the Sky mask (2026-10-11, the owner's Photomator comparison): the model sees the whole photo
    /// squeezed to 448 px, so sky between and beside trees gets lost. It runs again on four overlapping quarters (each
    /// 60 % of the width and height, about 1.7x the detail), stitched on a grid twice as fine, each point taken from
    /// the quarter it is most central in. The quarters can only ADD sky, and only near the sky the whole-photo run
    /// found: a quarter sees less of the picture and lost real sky among branches in a test photo (the cat), or could
    /// take a white wall for sky. Elsewhere the quarters' finer labels are kept (sharper trees for the next step).
    /// nil when the model is missing.
    func skyScene(_ scene: SceneField, source: ImageSource) -> SceneField? {
        guard let model = Self.sceneModel, scene.width > 1, scene.height > 1 else { return nil }
        let ext = source.extent
        let k = min(1, 1600 / max(ext.width, ext.height))
        let img = Self.normalized(source.base.transformed(by: CGAffineTransform(scaleX: k, y: k)))
        guard let cg = ctx.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace) else { return nil }
        struct Tile { var x, y, w, h: Double; var cols, rows: Int; var labels: [Int32] }
        var tiles: [Tile] = []
        let cw = Double(cg.width), chh = Double(cg.height)
        for ty in [0.0, 0.4] {
            for tx in [0.0, 0.4] {
                let r = CGRect(x: tx * cw, y: ty * chh, width: 0.6 * cw, height: 0.6 * chh).integral
                    .intersection(CGRect(x: 0, y: 0, width: cw, height: chh))
                guard r.width > 8, r.height > 8, let part = cg.cropping(to: r),
                      let run = Self.runScene(model, part) else { return nil }
                tiles.append(Tile(x: r.minX / cw, y: r.minY / chh, w: r.width / cw, h: r.height / chh,
                                  cols: run.0, rows: run.1, labels: run.2))
            }
        }
        let W = scene.width * 2, H = scene.height * 2, n = W * H
        let sky = ScenePart.sky.classes[0]
        // the quarters stitched: every point from the quarter it is most central in
        var fine = [Int32](repeating: 0, count: n)
        for j in 0..<H {
            let v = (Double(j) + 0.5) / Double(H)
            for i in 0..<W {
                let u = (Double(i) + 0.5) / Double(W)
                var best = -1.0
                for t in tiles {
                    let a = (u - t.x) / t.w, b = (v - t.y) / t.h
                    guard a >= 0, a < 1, b >= 0, b < 1 else { continue }
                    let edge = min(a, 1 - a, b, 1 - b)
                    if edge > best {
                        best = edge
                        fine[j * W + i] = t.labels[min(Int(b * Double(t.rows)), t.rows - 1) * t.cols + min(Int(a * Double(t.cols)), t.cols - 1)]
                    }
                }
            }
        }
        // the whole-photo run on the same grid, and its sky grown by 8 %: counts in a square window
        var coarse = [Int32](repeating: 0, count: n)
        for j in 0..<H { for i in 0..<W { coarse[j * W + i] = scene.labels[(j * scene.height / H) * scene.width + i * scene.width / W] } }
        var integral = [Int32](repeating: 0, count: (W + 1) * (H + 1))
        for j in 0..<H {
            var row: Int32 = 0
            for i in 0..<W {
                row += coarse[j * W + i] == sky ? 1 : 0
                integral[(j + 1) * (W + 1) + i + 1] = integral[j * (W + 1) + i + 1] + row
            }
        }
        func count(_ i: Int, _ j: Int, _ r: Int) -> (Int32, Int32) {
            let x0 = max(i - r, 0), x1 = min(i + r, W - 1), y0 = max(j - r, 0), y1 = min(j + r, H - 1)
            let c = integral[(y1 + 1) * (W + 1) + x1 + 1] - integral[y0 * (W + 1) + x1 + 1]
                - integral[(y1 + 1) * (W + 1) + x0] + integral[y0 * (W + 1) + x0]
            return (c, Int32((x1 - x0 + 1) * (y1 - y0 + 1)))
        }
        let grow = max(2, Int(0.08 * Double(max(W, H))))
        var out = fine
        for j in 0..<H {
            for i in 0..<W {
                let idx = j * W + i
                if coarse[idx] == sky { out[idx] = sky; continue }                  // the whole-photo sky stays
                if fine[idx] == sky && count(i, j, grow).0 == 0 { out[idx] = coarse[idx] }   // far from it: not sky
            }
        }
        return SceneField(width: W, height: H, labels: out, found: scene.found)
    }

    /// Sky seen through trees (2026-10-11, the owner's Photomator comparison): the scene model works on a 448 px copy,
    /// so the gaps in the leaves are lost. In the trees near the sky, each pixel is compared with the sky's colour
    /// there and the leaves' colour there (both measured on the photo around it) and joins whichever it is closer to.
    /// Only the model's trees are looked at: grass, flowers, buildings and cars never turn into sky.
    func skyThroughTrees(_ sky: CIImage, scene: SceneField, source: ImageSource) -> CIImage {
        guard let k = LumenKernels.shared, let weigh = k.skyWeigh, let leaf = k.leafWeigh, let gaps = k.skyGaps else { return sky }
        // the trees, a little wider than the model drew them (their edges are where most gaps are), then softened
        guard let t = labelRegion([ScenePart.treeClass], scene, source: source, grow: 2) else { return sky }
        let ext = source.extent
        // the colour fields change slowly: measured on a copy an eighth the size, blurred widely, stretched back
        let f: CGFloat = 0.125
        let sigma = max(2, 0.05 * source.longEdge * f)
        func field(_ img: CIImage?) -> CIImage? {
            guard let img else { return nil }
            let small = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: f, kCIInputAspectRatioKey: 1.0])
            let se = small.extent
            guard se.width >= 2, se.height >= 2 else { return nil }
            var b = small.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma]).cropped(to: se)
            if let m = Self.materialized(b) { b = m }
            return b.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -se.minX, y: -se.minY))
                .transformed(by: CGAffineTransform(scaleX: ext.width / se.width, y: ext.height / se.height))
                .cropped(to: ext)
        }
        let sure = CIVector(x: 0.9, y: 0.98, z: 0, w: 0), sureW = CIVector(x: 0.9, y: 0.98, z: 1, w: 0)
        guard let sn = field(weigh.apply(extent: ext, arguments: [source.base, sky, sure])),
              let sd = field(weigh.apply(extent: ext, arguments: [source.base, sky, sureW])),
              let fn = field(leaf.apply(extent: ext, arguments: [source.base, t, sn, sd, CIVector(x: 0, y: 0, z: 0, w: 0)])),
              let fd = field(leaf.apply(extent: ext, arguments: [source.base, t, sn, sd, CIVector(x: 0, y: 0, z: 1, w: 0)])),
              let out = gaps.apply(extent: ext, arguments: [source.base, sky, t, sn, sd, fn, fd, CIVector(x: 0.05, y: 0.15, z: 0, w: 0)])
        else { return sky }
        return Self.materializedMask(out) ?? out
    }

    /// Where `scene` has any of `classes`, as a soft mask over the source (`grow` = cells added round it first).
    func labelRegion(_ classes: Set<Int32>, _ scene: SceneField, source: ImageSource, grow: CGFloat = 0) -> CIImage? {
        let cover = scene.labels.map { classes.contains($0) ? Float(1) : 0 }
        guard cover.contains(1) else { return nil }
        let data = cover.withUnsafeBufferPointer { Data(buffer: $0) }
        var t = Self.expandRed(CIImage(bitmapData: data, bytesPerRow: scene.width * 4,
                                       size: CGSize(width: scene.width, height: scene.height), format: .Rf, colorSpace: nil))
        if grow > 0 { t = t.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: grow]).cropped(to: t.extent) }
        t = Self.blur(t, 1.0, t.extent)
        if let m = Self.materialized(t) { t = m }
        return Self.fit(t, to: source.extent)
    }

    /// Landscape parts kept off the sky (owner, 2026-10-12): the finer Sky (four quarters + sky through trees) is
    /// taken out of every part, so Vegetation stops where the sky seen through the leaves starts and the parts' edges
    /// meet the sky's exactly. Vegetation also gets back the tree tops the whole-photo run called sky but the finer
    /// sky gave to the trees. Only a sky found by the scene model is used (the classical finder can mistake walls).
    func landscapeMask(_ parts: [ScenePart], _ scene: SceneField, source: ImageSource) -> CIImage? {
        let base = sceneMask(parts, scene, source: source)
        guard scene.found.contains(.sky), let sky = source.cachedMask(Self.aiSky), let k = LumenKernels.shared else { return base }
        let ext = source.extent
        var m = base
        if parts.contains(.vegetation),
           let trees = labelRegion([ScenePart.treeClass], scene, source: source, grow: 2),
           let coarseSky = labelRegion(Set(ScenePart.sky.classes), scene, source: source),
           let topsUnderSky = k.maskMul.apply(extent: ext, arguments: [trees, coarseSky]) {
            m = m.map { topsUnderSky.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]).cropped(to: ext) }
                ?? topsUnderSky
        }
        guard let parts = m else { return nil }
        let notSky = sky.applyingFilter("CIColorInvert").cropped(to: ext)
        guard let out = k.maskMul.apply(extent: ext, arguments: [parts, notSky]) else { return parts }
        return Self.materializedMask(out) ?? out
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
    /// `d` with the sky pushed to the far end (soft at the sky's edge), and its histogram counted again.
    static func skyFar(_ d: DepthField, sky: CIImage) -> DepthField {
        let e = sky.extent
        guard e.width > 0, e.height > 0 else { return d }
        let small = sky.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(d.width) / e.width, y: CGFloat(d.height) / e.height))
        var px = [Float](repeating: 0, count: d.width * d.height * 4)
        LumenGPU.context.render(small, toBitmap: &px, rowBytes: d.width * 16,
                                bounds: CGRect(x: 0, y: 0, width: d.width, height: d.height), format: .RGBAf, colorSpace: nil)
        var out = d
        var hist = [Float](repeating: 0, count: 64)
        for i in 0..<(d.width * d.height) {
            let k = min(max(px[i * 4], 0), 1)       // top row first, like the field
            let v = d.values[i] + (1 - d.values[i]) * k
            out.values[i] = v
            hist[min(Int(v * 64), 63)] += 1
        }
        let top = max(hist.max() ?? 1, 1)
        out.histogram = hist.map { $0 / top }
        return out
    }

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
