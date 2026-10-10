import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Vision

/// Local adjustments. Every mask becomes one grey image (white = fully affected). Each mask's slider offsets are
/// multiplied by that image and summed into five "parameter planes" the develop kernel reads per pixel, so any
/// number of overlapping masks cost almost nothing at render time.
extension EditSession {
    static let aiSubject = "subject"
    static let aiSky = "sky"

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
        case .luminance:
            img = k.lumMask.apply(extent: ext, arguments: [
                source.base,
                CIVector(x: c.lumLow, y: c.lumHigh, z: c.lumLowFeather, w: c.lumHighFeather),
                CIVector(x: gain, y: 0, z: 0, w: 0)]) ?? zero
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
        var needSubject = false, needSky = false
        for m in s.masks {
            for c in m.components {
                if c.kind == .subject || c.kind == .background { needSubject = true }
                if c.kind == .sky { needSky = true }
            }
        }
        var computed = false
        if needSubject, !source.hasTried(Self.aiSubject) {
            source.storeMask(Self.aiSubject, computeSubject(source))
            computed = true
        }
        if needSky, !source.hasTried(Self.aiSky) {
            source.storeMask(Self.aiSky, computeSky(source))
            computed = true
        }
        return computed
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
