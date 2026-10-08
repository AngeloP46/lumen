import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// Builds the lazy Core Image graph for a set of edits. Nothing is rendered here, so this is cheap to call per slider tick.
extension EditSession {
    func develop(_ s: EditSettings, source: ImageSource, geometry: Bool) -> CIImage {
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

        if geometry { img = self.geometry(img, s) }

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
        return img
    }

    // MARK: Geometry

    /// 90° turns, straighten, then crop (aspect ratio / zoom / pan) inside the largest inscribed rectangle.
    func geometry(_ input: CIImage, _ s: EditSettings) -> CIImage {
        var img = input
        let turns = ((s.quarterTurns % 4) + 4) % 4
        if turns != 0 {
            img = Self.rotateAboutCenter(img, by: -CGFloat(turns) * .pi / 2)
            img = Self.normalized(img)
        }
        let w = img.extent.width, h = img.extent.height
        let theta = CGFloat(abs(s.straighten)) * .pi / 180
        let kfit = 1 / (cos(theta) + sin(theta) * max(w / h, h / w))
        if s.straighten != 0 {
            img = Self.rotateAboutCenter(img, by: -CGFloat(s.straighten) * .pi / 180) // original centre is now the origin
        } else {
            img = img.transformed(by: CGAffineTransform(translationX: -w / 2, y: -h / 2))
        }

        let w0 = w * kfit, h0 = h * kfit
        var cw = w0, ch = h0
        if s.cropAspect > 0 {
            let a = CGFloat(s.cropAspect)
            if a > w0 / h0 { cw = w0; ch = w0 / a } else { ch = h0; cw = h0 * a }
        }
        let z = CGFloat(max(1, s.cropZoom))
        cw /= z
        ch /= z
        let cx = CGFloat(s.cropX) * (w0 - cw) / 2
        let cy = CGFloat(s.cropY) * (h0 - ch) / 2
        let rect = CGRect(x: cx - cw / 2, y: cy - ch / 2, width: cw, height: ch).integral
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

    /// Full-size export.
    func renderData(_ s: EditSettings, format: ExportFormat, quality: Double) -> Data? {
        guard let src = makeSource(maxEdge: nil, materialize: false) else { return nil }
        prepareAutoMasks(s, source: src)
        let img = develop(s, source: src, geometry: true)
        let q = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        switch format {
        case .jpeg: return try? ctx.jpegRepresentation(of: img, colorSpace: LumenGPU.displaySpace, options: q)
        case .heic: return try? ctx.heifRepresentation(of: img, format: .RGBA8, colorSpace: LumenGPU.displaySpace, options: q)
        case .tiff: return try? ctx.tiffRepresentation(of: img, format: .RGBA16, colorSpace: LumenGPU.displaySpace, options: [:])
        }
    }
}
