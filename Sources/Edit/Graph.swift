import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// Builds the lazy Core Image graph for a set of edits. Nothing is rendered here, so this is cheap to call per slider tick.
extension EditSession {
    func develop(_ edits: EditSettings, source: ImageSource, geometry: Bool, applyCrop: Bool = true, hdrWeight: Double = 0) -> CIImage {
        // sections switched off in the Edits sheet render as if untouched
        let s = edits.effective
        guard let k = LumenKernels.shared else { return source.base }
        let ext = source.extent
        let E = source.longEdge

        func v(_ x: Double, _ y: Double, _ z: Double, _ w: Double) -> CIVector { CIVector(x: x, y: y, z: z, w: w) }
        let g0 = v(s.exposure, s.contrast / 100, s.highlights / 100, s.shadows / 100)
        let g1 = v(s.whites / 100, s.blacks / 100, s.temperature / 100, s.tint / 100)
        let g2 = v(s.blackAndWhite ? 0 : s.vibrance / 100, s.blackAndWhite ? 0 : s.saturation / 100,
                   s.texture / 100, s.clarity / 100)
        let g3 = v(s.dehaze / 100, s.sharpness / 100 * 0.9, s.sharpenMasking / 100, s.noiseReduction / 100)
        let g4 = v(s.colorNoise / 100, 0, 0, 0)
        let g6 = v(Double(source.air.x), Double(source.air.y), Double(source.air.z), Double(source.darkNorm))

        var args: [Any] = [source.base, source.l1, source.l2, source.chroma]
        var kernel = k.main
        if let planes = localPlanes(s, source: source) {
            args += planes
            kernel = k.mainLocal
        }
        args += [g0, g1, g2, g3, g4, g6]
        var img = kernel.apply(extent: ext, arguments: args) ?? source.base

        // HDR: the same develop maths, but only the highlight gain (>= 1) is kept; applied again after the look LUT.
        var gainImg: CIImage?
        if s.hdr, hdrWeight > 0, let gk = (kernel === k.mainLocal ? k.gainLocal : k.gain), k.applyGain != nil {
            let gh = v(exp2(s.hdrStops), 0, 0, 0)
            gainImg = gk.apply(extent: ext, arguments: args + [gh])
        }

        img = applyLensBlur(img, settings: s, source: source)
        if let gi = gainImg { gainImg = applyLensBlur(gi, settings: s, source: source) }

        if geometry {
            img = self.geometry(img, s, applyCrop: applyCrop)
            if let gi = gainImg { gainImg = self.geometry(gi, s, applyCrop: applyCrop) }
        }

        // Vignette, grain and the output curve.
        let fe = img.extent
        let lookNeutral = s.curves.isNeutral && s.hsl.isNeutral && s.grading.isNeutral && !s.blackAndWhite
        let cell = max(0.8, (0.5 + s.grainSize / 100 * 2.5) * E / 2000)
        let f0 = v(s.vignette / 100, s.vignetteMidpoint / 100, s.vignetteFeather / 100, s.vignetteRoundness / 100)
        let f1 = v(Double(fe.width), Double(fe.height), s.grain / 100, cell)
        let f2 = v(s.grainRoughness / 100, lookNeutral ? 0 : 1, 7, 0)
        img = k.finish.apply(extent: fe, arguments: [img, f0, f1, f2]) ?? img

        if !lookNeutral, let data = lookCube(s) {
            let f = CIFilter(name: "CIColorCube")!
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(ColorCube.dim, forKey: "inputCubeDimension")
            f.setValue(data, forKey: "inputCubeData")
            if let out = f.outputImage {
                img = k.toLinear.apply(extent: fe, arguments: [out]) ?? out
            }
        }
        if let gi = gainImg, let ag = k.applyGain {
            img = ag.apply(extent: img.extent, arguments: [img, gi, v(min(max(hdrWeight, 0), 1), 0, 0, 0)]) ?? img
        }
        return img
    }

    // MARK: Lens Blur

    /// Uses only cached analysis; prepareAutoMasks performs the model work off the UI thread.
    func lensBlurMask(_ settings: EditSettings, source: ImageSource) -> CIImage? {
        let s = settings.effective
        let blur = s.lensBlur
        guard blur.amount > 0 else { return nil }
        if let id = blur.maskID, let mask = s.masks.first(where: { $0.id == id }) {
            if mask.amount <= 0 { return Self.constant(0, source.extent) }
            if mask.components.contains(where: { $0.kind == .depth && $0.amount > 0 }),
               source.cachedMask(Self.aiDepth) == nil { return nil }
            guard let selection = maskImage(mask, source: source, gain: exp2(s.exposure)) else { return nil }
            if let depth = source.cachedMask(Self.aiDepth), let kernel = LumenKernels.shared?.lensRefinedRamp {
                let edge = mask.components.first(where: { $0.kind == .depth }).map { $0.lumLow - $0.lumLowFeather } ?? blur.focusDistance
                return kernel.apply(extent: source.extent, arguments: [depth, selection, CIVector(x: edge, y: 0, z: 0, w: 0)])
            }
            return selection
        }
        guard let depth = source.cachedMask(Self.aiDepth), let kernel = LumenKernels.shared?.lensRamp else { return nil }
        let subject = source.cachedMask(Self.subjectKey(blur.subjectPoint)) ?? Self.constant(0, source.extent)
        return kernel.apply(extent: source.extent,
                            arguments: [depth, subject, CIVector(x: blur.focusDistance, y: blur.focusWidth, z: 0, w: 0)])
    }

    func applyLensBlur(_ input: CIImage, settings: EditSettings, source: ImageSource) -> CIImage {
        let s = settings.effective
        guard s.lensBlur.amount > 0 else { return input }
        if let id = s.lensBlur.maskID, let editable = s.masks.first(where: { $0.id == id }) {
            guard editable.amount > 0 else { return input }
        } else {
            let width = min(max(s.lensBlur.focusWidth, 0.02), 1)
            guard min(max(s.lensBlur.focusDistance, 0), 1) + width < 0.999 else { return input }
        }
        // A no-op must bypass Core Image's colour conversions, not just blend with a black mask.
        guard let mask = lensBlurMask(s, source: source) else { return input }
        let radius = min(max(settings.effective.lensBlur.amount, 0), 100) / 100 * Double(source.longEdge) * 0.018
        guard radius > 0 else { return input }
        return Self.maskedLensBlur(input, mask: mask, radius: radius)
    }

    /// Radius scales with source pixels, so preview, detail and export show the same apparent blur.
    /// Lens-like: round (disc) blur, so bright points become soft circles as with a real lens, and only the
    /// background feeds it, so the subject's colour does not glow into the blurred area around its edges.
    /// Three blur layers are mixed by the blur map, which keeps the blur growing with distance.
    static func maskedLensBlur(_ input: CIImage, mask: CIImage, radius: Double) -> CIImage {
        let extent = input.extent
        if let k = LumenKernels.shared, let weigh = k.lensWeigh, let compose = k.lensCompose,
           CIFilter(name: "CIBokehBlur") != nil {
            let m = mask.cropped(to: extent)
            guard let weighted = weigh.apply(extent: extent, arguments: [input.clampedToExtent(), m.clampedToExtent()])
            else { return smoothLensBlur(input, mask: mask, radius: radius) }
            // a disc looks about as strong as a smooth blur of ~0.6x its radius: keep the familiar strength
            let disc = radius * 1.6
            let layers = [disc / 3, disc * 2 / 3, disc].map { r -> CIImage in
                weighted.clampedToExtent().applyingFilter("CIBokehBlur", parameters: [
                    kCIInputRadiusKey: max(r, 0.5), "inputRingAmount": 0, "inputRingSize": 0.1, "inputSoftness": 1.0
                ]).cropped(to: extent)
            }
            if let out = compose.apply(extent: extent, arguments: [input, m] + layers) { return out.cropped(to: extent) }
        }
        return smoothLensBlur(input, mask: mask, radius: radius)
    }

    /// The first Lens Blur (smooth, Gaussian-like): the fallback when the lens-like kernels are unavailable.
    static func smoothLensBlur(_ input: CIImage, mask: CIImage, radius: Double) -> CIImage {
        let extent = input.extent
        let filter = CIFilter(name: "CIMaskedVariableBlur")
        filter?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter?.setValue(mask.cropped(to: extent).clampedToExtent(), forKey: "inputMask")
        filter?.setValue(radius, forKey: kCIInputRadiusKey)
        guard let blurred = filter?.outputImage?.cropped(to: extent) else { return input }
        return blurred.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: input, "inputMaskImage": mask.cropped(to: extent)
        ]).cropped(to: extent)
    }

    // MARK: Geometry

    /// 90° turns, straighten, then crop to the frame (fractions of the largest rectangle that fits inside the rotated picture).
    /// `applyCrop: false` keeps the whole straightened picture, which is what the crop editor shows.
    func geometry(_ input: CIImage, _ s: EditSettings, applyCrop: Bool = true) -> CIImage {
        var img = input
        // Transform (perspective, aspect, scale, offset): the photo's corners move, the frame stays the same size
        if let q = Homography.corners(s) {
            let e = img.extent
            func pt(_ p: Pt) -> CIVector { CIVector(x: e.minX + CGFloat(p.x) * e.width, y: e.minY + CGFloat(1 - p.y) * e.height) }
            img = img.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": pt(q[0]), "inputTopRight": pt(q[1]),
                "inputBottomRight": pt(q[2]), "inputBottomLeft": pt(q[3]),
            ])
            // keep the full frame when the photo is made smaller (cropping alone would shrink the extent to the photo)
            img = img.composited(over: CIImage(color: .clear).cropped(to: e)).cropped(to: e)
        }
        // Flip (mirror) about the centre
        if s.flipH || s.flipV {
            let e = img.extent
            img = img.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY)
                .concatenating(CGAffineTransform(scaleX: s.flipH ? -1 : 1, y: s.flipV ? -1 : 1))
                .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY)))
        }
        let turns = ((s.quarterTurns % 4) + 4) % 4
        if turns != 0 {
            img = Self.rotateAboutCenter(img, by: -CGFloat(turns) * .pi / 2)
            img = Self.normalized(img)
        }
        let w = img.extent.width, h = img.extent.height
        let theta = CGFloat(abs(s.straighten)) * .pi / 180
        let kfit = 1 / (cos(theta) + sin(theta) * max(w / h, h / w))
        img = Self.rotateAboutCenter(img, by: -CGFloat(s.straighten) * .pi / 180) // original centre is now the origin

        let w0 = w * kfit, h0 = h * kfit
        var l = 0.0, t = 0.0, r = 1.0, b = 1.0
        if applyCrop {
            l = min(max(s.cropL, 0), 0.95); t = min(max(s.cropT, 0), 0.95)
            r = min(max(s.cropR, l + 0.04), 1); b = min(max(s.cropB, t + 0.04), 1)
        }
        let rect = CGRect(x: -w0 / 2 + CGFloat(l) * w0, y: -h0 / 2 + CGFloat(1 - b) * h0,
                          width: CGFloat(r - l) * w0, height: CGFloat(b - t) * h0).integral
        return Self.normalized(img.cropped(to: rect))
    }

    static func rotateAboutCenter(_ img: CIImage, by angle: CGFloat) -> CIImage {
        let e = img.extent
        let t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(rotationAngle: angle))
        return img.transformed(by: t)
    }

    // MARK: Output

    /// Small renders for thumbnails and presets. Automatic (AI) masks are skipped.
    func renderCGImage(_ s: EditSettings, maxEdge: CGFloat) -> CGImage? {
        heals = s.effective.heals
        guard let src = makeSource(maxEdge: maxEdge, materialize: false) else { return nil }
        if s.effective.lensBlur.amount > 0 { prepareAutoMasks(s, source: src) }
        return renderCGImage(s, source: src)
    }

    func renderCGImage(_ s: EditSettings, source: ImageSource, geometry: Bool = true) -> CGImage? {
        let img = develop(s, source: source, geometry: geometry)
        return ctx.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace)
    }

    /// Export. `quality` 0...1 (JPEG/HEIC), `maxEdge` = long edge in pixels (nil = full size), `includeHDR` adds the
    /// HDR gain map when the photo is edited in HDR.
    func renderData(_ s: EditSettings, format: ExportFormat, quality: Double, maxEdge: CGFloat? = nil,
                    includeHDR: Bool = true) -> Data? {
        heals = s.effective.heals
        guard let src = makeSource(maxEdge: nil, materialize: false) else { return nil }
        prepareAutoMasks(s, source: src)
        // Never quietly export an unblurred photo when a requested focus map could not be prepared.
        if s.effective.lensBlur.amount > 0 && lensBlurMask(s, source: src) == nil { return nil }
        var img = develop(s, source: src, geometry: true)
        let q: [CIImageRepresentationOption: Any] = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        // HDR: the SDR rendition is the base image; the gain-map options need iOS 18 / macOS 15.
        let wantHDR = includeHDR && s.hdr && format != .tiff && LumenKernels.shared?.applyGain != nil
        var hdrImg: CIImage? = wantHDR ? develop(s, source: src, geometry: true, hdrWeight: 1) : nil
        // smaller sizes are made from the full-size result, so they are as sharp as they can be
        let long = max(img.extent.width, img.extent.height)
        if let m = maxEdge, m > 0, long > m {
            let k = m / long
            img = Self.downscaled(img, k)
            hdrImg = hdrImg.map { Self.downscaled($0, k) }
        }
        switch format {
        case .jpeg:
            if let hdrImg, #available(iOS 18.0, macOS 15.0, *) {
                var o = q
                o[.hdrImage] = hdrImg
                if let d = try? ctx.jpegRepresentation(of: img, colorSpace: LumenGPU.displaySpace, options: o) { return d }
            }
            return try? ctx.jpegRepresentation(of: img, colorSpace: LumenGPU.displaySpace, options: q)
        case .heic:
            if let hdrImg {
                if #available(iOS 18.0, macOS 15.0, *) {
                    var o = q
                    o[.hdrImage] = hdrImg
                    if let d = try? ctx.heifRepresentation(of: img, format: .RGBA8, colorSpace: LumenGPU.displaySpace, options: o) { return d }
                } else if let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG),
                          let d = try? ctx.heif10Representation(of: hdrImg, colorSpace: hlg, options: q) {
                    return d
                }
            }
            return try? ctx.heifRepresentation(of: img, format: .RGBA8, colorSpace: LumenGPU.displaySpace, options: q)
        case .tiff: return try? ctx.tiffRepresentation(of: img, format: .RGBA16, colorSpace: LumenGPU.displaySpace, options: [:])
        }
    }

    static func downscaled(_ img: CIImage, _ k: CGFloat) -> CIImage {
        let s = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1.0])
        return s.cropped(to: CGRect(x: 0, y: 0, width: floor(s.extent.width), height: floor(s.extent.height)))
    }
}

/// The photo as stored (the source: masks, brush strokes and colour picks live here) versus the photo as shown after
/// 90° turns, straighten and crop (the output). Same maths as `EditSession.geometry`, so mask handles drawn through
/// it sit exactly on the rendered mask. Normalised coordinates are 0...1 with y down on both sides.
/// A projective map between two quadrilaterals, in normalised photo coordinates (0...1, y down).
struct Homography: Equatable {
    var m: [Double]   // row-major 3 x 3

    /// Where the photo's corners go for a transform (TL, TR, BR, BL), or nil when there is no transform.
    static func corners(_ s: EditSettings) -> [Pt]? {
        guard s.hasTransform else { return nil }
        let kv = s.tVertical / 100 * 0.25, kh = s.tHorizontal / 100 * 0.25
        let a = s.tAspect / 100
        let sx = (a > 0 ? 1 + a * 0.5 : 1) * s.tScale / 100
        let sy = (a < 0 ? 1 - a * 0.5 : 1) * s.tScale / 100
        let ox = s.tOffX / 100 * 0.5, oy = -s.tOffY / 100 * 0.5
        // centred corner positions: Vertical widens the top (narrows the bottom), Horizontal heightens the left side
        let c: [(Double, Double)] = [(-0.5 * (1 + kv), -0.5 * (1 + kh)), (0.5 * (1 + kv), -0.5 * (1 - kh)),
                                     (0.5 * (1 - kv), 0.5 * (1 - kh)), (-0.5 * (1 - kv), 0.5 * (1 + kh))]
        func quad(_ k: Double) -> [Pt] { c.map { Pt(x: 0.5 + $0.0 * sx * k + ox, y: 0.5 + $0.1 * sy * k + oy) } }
        guard s.tFill else { return quad(1) }
        // Fill frame: the smallest extra zoom (about the centre) at which the photo covers the whole frame,
        // i.e. every frame corner lands inside the transformed photo
        func covers(_ k: Double) -> Bool {
            let inv = squareTo(quad(k)).inverse
            return [Pt(x: 0, y: 0), Pt(x: 1, y: 0), Pt(x: 1, y: 1), Pt(x: 0, y: 1)].allSatisfy {
                let q = inv.apply($0)
                return q.x >= -1e-4 && q.x <= 1 + 1e-4 && q.y >= -1e-4 && q.y <= 1 + 1e-4
            }
        }
        if covers(1) { return quad(1) }
        var lo = 1.0, hi = 1.5
        while !covers(hi) && hi < 8 { lo = hi; hi *= 1.5 }
        guard covers(hi) else { return quad(1) }
        for _ in 0..<30 { let mid = (lo + hi) / 2; if covers(mid) { hi = mid } else { lo = mid } }
        return quad(hi)
    }

    /// The unit square's corners (0,0), (1,0), (1,1), (0,1) -> q[0...3] (Heckbert).
    static func squareTo(_ q: [Pt]) -> Homography {
        let x0 = q[0].x, y0 = q[0].y, x1 = q[1].x, y1 = q[1].y, x2 = q[2].x, y2 = q[2].y, x3 = q[3].x, y3 = q[3].y
        let sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3
        var g = 0.0, h = 0.0
        if abs(sx) > 1e-12 || abs(sy) > 1e-12 {
            let dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2
            let den = dx1 * dy2 - dx2 * dy1
            g = (sx * dy2 - dx2 * sy) / den
            h = (dx1 * sy - sx * dy1) / den
        }
        return Homography(m: [x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
                              y1 - y0 + g * y1, y3 - y0 + h * y3, y0,
                              g, h, 1])
    }

    func apply(_ p: Pt) -> Pt {
        let w = m[6] * p.x + m[7] * p.y + m[8]
        guard abs(w) > 1e-12 else { return p }
        return Pt(x: (m[0] * p.x + m[1] * p.y + m[2]) / w, y: (m[3] * p.x + m[4] * p.y + m[5]) / w)
    }

    var inverse: Homography {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        guard abs(det) > 1e-15 else { return self }
        let k = 1 / det
        return Homography(m: [A * k, -(b * i - c * h) * k, (b * f - c * e) * k,
                              B * k, (a * i - c * g) * k, -(a * f - c * d) * k,
                              C * k, -(a * h - b * g) * k, (a * e - b * d) * k])
    }
}

struct SourceGeometry: Equatable {
    var source: CGSize
    var turns = 0
    var straighten = 0.0
    /// Transform (photo -> photo, normalised) and flips, applied before the turns
    var warp: Homography?
    var flipH = false
    var flipV = false
    /// crop fractions of the straightened picture: x = left, y = top, width = right - left, height = bottom - top
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)

    init(source: CGSize, settings s: EditSettings, applyCrop: Bool = true) {
        self.source = source
        turns = ((s.quarterTurns % 4) + 4) % 4
        straighten = s.straighten
        warp = Homography.corners(s).map { Homography.squareTo($0) }
        flipH = s.flipH
        flipV = s.flipV
        if applyCrop {
            // the same limits EditSession.geometry applies
            let l = min(max(s.cropL, 0), 0.95), t = min(max(s.cropT, 0), 0.95)
            let r = min(max(s.cropR, l + 0.04), 1), b = min(max(s.cropB, t + 0.04), 1)
            crop = CGRect(x: l, y: t, width: r - l, height: b - t)
        }
    }

    /// Pictures turned on their side swap width and height.
    private var turned: CGSize { turns % 2 == 0 ? source : CGSize(width: source.height, height: source.width) }
    /// The largest rectangle with the picture's shape that fits inside it once straightened.
    private var inscribed: CGSize {
        let w = turned.width, h = turned.height
        guard w > 0, h > 0 else { return .zero }
        let th = CGFloat(abs(straighten)) * .pi / 180
        let k = 1 / (cos(th) + sin(th) * max(w / h, h / w))
        return CGSize(width: w * k, height: h * k)
    }
    /// Output size in source pixels.
    var output: CGSize { CGSize(width: inscribed.width * crop.width, height: inscribed.height * crop.height) }
    /// How far the source is turned on screen, clockwise, in degrees.
    var clockwise: Double { Double(turns) * 90 + straighten }
    /// A single flip mirrors angles (a radial turned clockwise in the source shows turned anticlockwise).
    var mirrored: Bool { flipH != flipV }

    /// Source pixels (Core Image, y up, origin bottom left) -> output pixels (same convention).
    private var forward: CGAffineTransform {
        let i = inscribed
        let ox = -i.width / 2 + crop.minX * i.width
        let oy = -i.height / 2 + (1 - crop.maxY) * i.height
        return CGAffineTransform(translationX: -source.width / 2, y: -source.height / 2)
            .concatenating(CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2 - CGFloat(straighten) * .pi / 180))
            .concatenating(CGAffineTransform(translationX: -ox, y: -oy))
    }

    /// Source -> the photo after transform and flip (still source-sized, normalised).
    private func pre(_ p: Pt) -> Pt {
        var q = warp?.apply(p) ?? p
        if flipH { q.x = 1 - q.x }
        if flipV { q.y = 1 - q.y }
        return q
    }

    private func unpre(_ p: Pt) -> Pt {
        var q = p
        if flipH { q.x = 1 - q.x }
        if flipV { q.y = 1 - q.y }
        return warp?.inverse.apply(q) ?? q
    }

    func toOutput(_ src: Pt) -> Pt {
        let o = output
        guard o.width > 0, o.height > 0 else { return src }
        let p = pre(src)
        let q = CGPoint(x: CGFloat(p.x) * source.width, y: (1 - CGFloat(p.y)) * source.height).applying(forward)
        return Pt(x: Double(q.x / o.width), y: Double(1 - q.y / o.height))
    }

    func toSource(_ p: Pt) -> Pt {
        let o = output
        guard o.width > 0, o.height > 0, source.width > 0, source.height > 0 else { return p }
        let q = CGPoint(x: CGFloat(p.x) * o.width, y: (1 - CGFloat(p.y)) * o.height).applying(forward.inverted())
        return unpre(Pt(x: Double(q.x / source.width), y: Double(1 - q.y / source.height)))
    }
}
