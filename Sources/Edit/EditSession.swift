import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

struct LookKey: Hashable {
    var curves: ToneCurves
    var hsl: HSLSettings
    var grading: ColorGrading
}

/// One opened photo. RAW files (Sony ARW, ProRAW/DNG, ...) go through Apple's CIRAWFilter;
/// anything else (JPEG/HEIC) is loaded as a plain CIImage. Not thread-safe: call from one queue at a time.
final class EditSession: @unchecked Sendable {
    private let raw: CIRAWFilter?
    private let plain: CIImage?
    private let baseExposure: Float
    private let asShotTemperature: Float
    private let asShotTint: Float
    let nativeSize: CGSize

    // Caches (used by Masks.swift too)
    var cubeKey: LookKey?
    var cubeData: Data?
    var subjectCache: CIImage?
    var subjectTried = false

    static let context: CIContext = {
        let working = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        return CIContext(options: [.workingColorSpace: working])
    }()
    static let outputSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    init?(url: URL) {
        let isRaw = UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .rawImage) ?? false
        if isRaw, let f = CIRAWFilter(imageURL: url) {
            f.extendedDynamicRangeAmount = 0
            raw = f
            plain = nil
            baseExposure = f.exposure
            asShotTemperature = f.neutralTemperature
            asShotTint = f.neutralTint
            nativeSize = f.nativeSize
        } else if let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
            raw = nil
            plain = img
            baseExposure = 0
            asShotTemperature = 6500
            asShotTint = 0
            nativeSize = img.extent.size
        } else {
            return nil
        }
    }

    // MARK: Output

    func render(_ s: EditSettings, maxEdge: CGFloat?, skipGeometry: Bool = false) -> CGImage? {
        guard let img = build(s, maxEdge: maxEdge, skipGeometry: skipGeometry) else { return nil }
        return Self.context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: Self.outputSpace)
    }

    func renderData(_ s: EditSettings, format: ExportFormat, quality: Double) -> Data? {
        guard let img = build(s, maxEdge: nil, skipGeometry: false) else { return nil }
        let ctx = Self.context
        let q = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        switch format {
        case .jpeg: return try? ctx.jpegRepresentation(of: img, colorSpace: Self.outputSpace, options: q)
        case .heic: return try? ctx.heifRepresentation(of: img, format: .RGBA8, colorSpace: Self.outputSpace, options: q)
        case .tiff: return try? ctx.tiffRepresentation(of: img, format: .RGBA16, colorSpace: Self.outputSpace, options: [:])
        }
    }

    /// Red tint showing where `mask` applies, aligned with `render(..., skipGeometry: true)` at the same maxEdge.
    func renderMaskOverlay(_ s: EditSettings, mask: Mask, maxEdge: CGFloat) -> CGImage? {
        guard let (base, _) = baseImage(s, maxEdge: maxEdge) else { return nil }
        let ext = base.extent
        let m = maskImage(mask, over: base)
        let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.15, alpha: 0.55)).cropped(to: ext)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: ext)
        let out = red.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: m,
        ])
        return Self.context.createCGImage(out, from: ext, format: .RGBA8,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: Pipeline

    /// Linear image after RAW decode, global exposure and white balance. `scale` = output size / native size.
    private func baseImage(_ s: EditSettings, maxEdge: CGFloat?) -> (CIImage, CGFloat)? {
        let longEdge = max(nativeSize.width, nativeSize.height)
        let target = maxEdge.map { min(1, $0 / longEdge) } ?? 1

        if let raw {
            raw.exposure = baseExposure + Float(s.exposure)
            raw.neutralTemperature = asShotTemperature * Float(pow(2.0, s.temperature / 100 * 0.75))
            raw.neutralTint = asShotTint + Float(s.tint)
            raw.scaleFactor = Float(target)
            guard let o = raw.outputImage else { return nil }
            let img = Self.normalized(o)
            return (img, max(img.extent.width, img.extent.height) / longEdge)
        }
        guard var img = plain else { return nil }
        if target < 1 {
            img = img.applyingFilter("CILanczosScaleTransform",
                                     parameters: [kCIInputScaleKey: target, kCIInputAspectRatioKey: 1.0])
        }
        img = Self.temperatureTint(img, s.temperature, s.tint)
        if s.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: s.exposure])
        }
        img = Self.normalized(img)
        return (img, max(img.extent.width, img.extent.height) / longEdge)
    }

    private func build(_ s: EditSettings, maxEdge: CGFloat?, skipGeometry: Bool) -> CIImage? {
        guard let (base, scale) = baseImage(s, maxEdge: maxEdge) else { return nil }
        let ext = base.extent

        var img = applyMasks(base, s, scale: scale)

        // Tone and colour edits happen in a gamma-encoded space so the sliders feel familiar.
        img = Self.toGamma(img)
        img = Self.toneAdjust(img, blacks: s.blacks, shadows: s.shadows, highlights: s.highlights, whites: s.whites)
        if s.dehaze != 0 { img = Self.dehaze(img, s.dehaze) }
        img = Self.colorControls(img, saturation: s.saturation, contrast: s.contrast)
        if s.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = img
            f.amount = Float(s.vibrance / 100)
            img = f.outputImage ?? img
        }
        img = applyLook(img, s)

        // Detail
        if s.texture != 0 { img = Self.localContrast(img, radius: max(1, 3 * scale), amount: s.texture / 100 * 1.5) }
        if s.clarity != 0 { img = Self.localContrast(img, radius: max(2, 40 * scale), amount: s.clarity / 100 * 0.8) }
        if s.noiseReduction > 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = img
            f.noiseLevel = Float(s.noiseReduction / 100 * 0.05)
            f.sharpness = 0.4
            img = f.outputImage ?? img
        }
        if s.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = img
            f.sharpness = Float(s.sharpness / 100 * 1.5)
            f.radius = Float(max(0.6, 1.2 * scale))
            img = f.outputImage ?? img
        }
        img = img.cropped(to: ext)

        if s.grain > 0 { img = Self.grain(img, amount: s.grain) }
        if s.vignette != 0 {
            let f = CIFilter.vignette()
            f.inputImage = img
            f.intensity = Float(-s.vignette / 100)
            f.radius = 1.5
            img = f.outputImage ?? img
        }

        img = Self.toLinear(img)
        return skipGeometry ? img : geometry(img, s)
    }

    private func applyLook(_ img: CIImage, _ s: EditSettings) -> CIImage {
        if s.curves.isNeutral && s.hsl.isNeutral && s.grading.isNeutral { return img }
        let key = LookKey(curves: s.curves, hsl: s.hsl, grading: s.grading)
        if cubeKey != key || cubeData == nil {
            cubeData = ColorCube.make(curves: s.curves, hsl: s.hsl, grading: s.grading)
            cubeKey = key
        }
        guard let data = cubeData else { return img }
        let f = CIFilter.colorCube()
        f.inputImage = img
        f.cubeDimension = Float(ColorCube.dim)
        f.cubeData = data
        return f.outputImage ?? img
    }

    // MARK: Geometry

    /// 90° turns, straighten, then crop (aspect ratio / zoom / pan) inside the largest inscribed rectangle.
    private func geometry(_ input: CIImage, _ s: EditSettings) -> CIImage {
        var img = input
        let turns = ((s.quarterTurns % 4) + 4) % 4
        if turns != 0 {
            img = Self.rotateAboutCenter(img, by: -CGFloat(turns) * .pi / 2)
            img = Self.normalized(img)
        }
        let w = img.extent.width, h = img.extent.height
        let theta = CGFloat(abs(s.straighten)) * .pi / 180
        let k = 1 / (cos(theta) + sin(theta) * max(w / h, h / w))
        img = Self.rotateAboutCenter(img, by: -CGFloat(s.straighten) * .pi / 180) // original centre is now the origin

        let w0 = w * k, h0 = h * k
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

    // MARK: Shared helpers (also used for local adjustments)

    static func toGamma(_ i: CIImage) -> CIImage { i.applyingFilter("CILinearToSRGBToneCurve") }
    static func toLinear(_ i: CIImage) -> CIImage { i.applyingFilter("CISRGBToneCurveToLinear") }

    static func rotateAboutCenter(_ img: CIImage, by angle: CGFloat) -> CIImage {
        let e = img.extent
        let t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(rotationAngle: angle))
        return img.transformed(by: t)
    }

    static func normalized(_ img: CIImage) -> CIImage {
        let e = img.extent
        return img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    static func temperatureTint(_ img: CIImage, _ temperature: Double, _ tint: Double) -> CIImage {
        guard temperature != 0 || tint != 0 else { return img }
        return img.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500 + 2000 * temperature / 100, y: tint),
            "inputTargetNeutral": CIVector(x: 6500, y: 0),
        ])
    }

    /// Blacks / shadows / highlights / whites as one 5-point curve (gamma space).
    static func toneAdjust(_ img: CIImage, blacks: Double, shadows: Double, highlights: Double, whites: Double) -> CIImage {
        guard blacks != 0 || shadows != 0 || highlights != 0 || whites != 0 else { return img }
        let p0x = blacks < 0 ? -blacks / 100 * 0.12 : 0
        let p0y = blacks > 0 ? blacks / 100 * 0.12 : 0
        let p4x = whites > 0 ? 1 - whites / 100 * 0.12 : 1
        let p4y = whites < 0 ? 1 + whites / 100 * 0.12 : 1
        let y1 = min(max(0.25 + shadows / 100 * 0.15, p0y + 0.02), 0.48)
        let y3 = max(min(0.75 + highlights / 100 * 0.15, p4y - 0.02), 0.52)

        let f = CIFilter.toneCurve()
        f.inputImage = img
        f.point0 = CGPoint(x: p0x, y: p0y)
        f.point1 = CGPoint(x: 0.25, y: y1)
        f.point2 = CGPoint(x: 0.5, y: 0.5)
        f.point3 = CGPoint(x: 0.75, y: y3)
        f.point4 = CGPoint(x: p4x, y: p4y)
        return f.outputImage ?? img
    }

    static func colorControls(_ img: CIImage, saturation: Double, contrast: Double) -> CIImage {
        guard saturation != 0 || contrast != 0 else { return img }
        let f = CIFilter.colorControls()
        f.inputImage = img
        f.saturation = Float(1 + saturation / 100)
        f.contrast = Float(1 + contrast / 100 * 0.5)
        return f.outputImage ?? img
    }

    static func dehaze(_ img: CIImage, _ d: Double) -> CIImage {
        let f = CIFilter.toneCurve()
        f.inputImage = img
        f.point0 = CGPoint(x: d > 0 ? d / 100 * 0.1 : 0, y: d < 0 ? -d / 100 * 0.08 : 0)
        f.point1 = CGPoint(x: 0.25, y: 0.25)
        f.point2 = CGPoint(x: 0.5, y: 0.5)
        f.point3 = CGPoint(x: 0.75, y: 0.75)
        f.point4 = CGPoint(x: 1, y: 1)
        let toned = f.outputImage ?? img
        return colorControls(toned, saturation: d * 0.2, contrast: d * 0.5)
    }

    /// Positive amount = local contrast (unsharp mask); negative = softening.
    static func localContrast(_ img: CIImage, radius: CGFloat, amount: Double) -> CIImage {
        if amount > 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = img
            f.radius = Float(radius)
            f.intensity = Float(amount)
            return f.outputImage ?? img
        }
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = img.clampedToExtent()
        blur.radius = Float(radius)
        guard let blurred = blur.outputImage?.cropped(to: img.extent) else { return img }
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = img
        mix.targetImage = blurred
        mix.time = Float(min(1, -amount))
        return mix.outputImage ?? img
    }

    static func grain(_ img: CIImage, amount: Double) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return img }
        let a = amount / 100 * 0.5
        let v = CIVector(x: a, y: 0, z: 0, w: 0)
        let gray = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v, "inputGVector": v, "inputBVector": v,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0.5 - a / 2, y: 0.5 - a / 2, z: 0.5 - a / 2, w: 1),
        ]).cropped(to: img.extent)
        return gray.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: img])
    }
}
