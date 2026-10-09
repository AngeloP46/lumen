import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// Builds the lazy Core Image graph for a set of edits. Nothing is rendered here, so this is cheap to call per slider tick.
extension EditSession {
    func develop(_ s: EditSettings, source: ImageSource, geometry: Bool, applyCrop: Bool = true, hdrWeight: Double = 0) -> CIImage {
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

    // MARK: Geometry

    /// 90° turns, straighten, then crop to the frame (fractions of the largest rectangle that fits inside the rotated picture).
    /// `applyCrop: false` keeps the whole straightened picture, which is what the crop editor shows.
    func geometry(_ input: CIImage, _ s: EditSettings, applyCrop: Bool = true) -> CIImage {
        var img = input
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
        guard let src = makeSource(maxEdge: maxEdge, materialize: false) else { return nil }
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
        guard let src = makeSource(maxEdge: nil, materialize: false) else { return nil }
        prepareAutoMasks(s, source: src)
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
