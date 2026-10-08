import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Metal
import ImageIO
import UniformTypeIdentifiers

/// GPU objects shared by the whole app (preview view, thumbnails, export).
enum LumenGPU {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static let queue: MTLCommandQueue? = device?.makeCommandQueue()
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    static let displaySpace = CGColorSpace(name: CGColorSpace.displayP3)!

    static let context: CIContext = {
        let opts: [CIContextOption: Any] = [.workingColorSpace: workingSpace, .workingFormat: CIFormat.RGBAh]
        if let q = queue { return CIContext(mtlCommandQueue: q, options: opts) }
        return CIContext(options: opts)
    }()

    /// Tests point this at a metallib built from Kernels.metal; the app finds default.metallib in its bundle.
    nonisolated(unsafe) static var libraryURL: URL?
}

/// The compiled Core Image kernels (see Kernels.metal).
struct LumenKernels {
    let logLum, minChannel, pack3, main, mainLocal, finish, toLinear, accum: CIColorKernel
    let linearMask, radialMask, lumMask, colorMask, similarMask, combine, maskFinish, maskMul, overlay: CIColorKernel

    static let shared: LumenKernels? = {
        var url = LumenGPU.libraryURL
        if url == nil { url = Bundle.main.url(forResource: "default", withExtension: "metallib") }
        if url == nil { url = Bundle(for: BundleToken.self).url(forResource: "default", withExtension: "metallib") }
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        func k(_ name: String) -> CIColorKernel? {
            do { return try CIColorKernel(functionName: name, fromMetalLibraryData: data) }
            catch { NSLog("Lumen kernel \(name) failed: \(error)"); return nil }
        }
        guard let a = k("lumenLogLum"), let b = k("lumenMinChannel"), let c = k("lumenPack3"),
              let d = k("lumenMain"), let e = k("lumenMainLocal"), let f = k("lumenFinish"),
              let g = k("lumenToLinear"), let h = k("lumenAccum"), let i = k("lumenLinearMask"),
              let j = k("lumenRadialMask"), let l = k("lumenLumMask"), let m = k("lumenColorMask"),
              let n = k("lumenSimilarMask"), let o = k("lumenMaskCombine"), let p = k("lumenMaskFinish"),
              let q = k("lumenMaskMul"), let r = k("lumenOverlay") else { return nil }
        return LumenKernels(logLum: a, minChannel: b, pack3: c, main: d, mainLocal: e, finish: f, toLinear: g,
                            accum: h, linearMask: i, radialMask: j, lumMask: l, colorMask: m, similarMask: n,
                            combine: o, maskFinish: p, maskMul: q, overlay: r)
    }()
}

private final class BundleToken {}

/// A decoded image at a working size plus the analysis layers the develop kernel needs.
/// Layer encoding: e = (log2(Y / 0.18) + 8) / 16.
///  - l1: R = log-luminance blurred finely (sharpening), G = medium (texture), B = wide (clarity)
///  - l2: R = log-luminance blurred very widely (shadows/highlights regions), G = dark channel (dehaze)
///  - chroma: RGB blurred (colour noise)
final class ImageSource: @unchecked Sendable {
    let base: CIImage
    let l1: CIImage
    let l2: CIImage
    let chroma: CIImage
    let size: CGSize
    let air: SIMD3<Float>
    let darkNorm: Float
    /// 96-px linear RGB(A float) snapshot for cheap CPU statistics.
    let stats: PixelGrid

    private let lock = NSLock()
    private var masks: [String: CIImage] = [:]
    private var tried: Set<String> = []
    private var raster: [MaskComponent: CIImage] = [:]

    var longEdge: CGFloat { max(size.width, size.height) }
    var extent: CGRect { CGRect(origin: .zero, size: size) }

    init(base: CIImage, l1: CIImage, l2: CIImage, chroma: CIImage, air: SIMD3<Float>, darkNorm: Float, stats: PixelGrid) {
        self.base = base
        self.l1 = l1
        self.l2 = l2
        self.chroma = chroma
        self.size = base.extent.size
        self.air = air
        self.darkNorm = darkNorm
        self.stats = stats
    }

    func cachedMask(_ key: String) -> CIImage? { lock.lock(); defer { lock.unlock() }; return masks[key] }
    func storeMask(_ key: String, _ img: CIImage?) {
        lock.lock(); defer { lock.unlock() }
        tried.insert(key)
        if let img { masks[key] = img }
    }
    func hasTried(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return tried.contains(key) }

    func cachedRaster(_ c: MaskComponent) -> CIImage? { lock.lock(); defer { lock.unlock() }; return raster[c] }
    func storeRaster(_ c: MaskComponent, _ img: CIImage) {
        lock.lock(); defer { lock.unlock() }
        if raster.count > 24 { raster.removeAll() }
        raster[c] = img
    }
}

/// Small row-major float RGBA grid (linear working space).
struct PixelGrid: Sendable {
    var width: Int
    var height: Int
    var data: [Float]

    func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return SIMD3(data[i], data[i + 1], data[i + 2])
    }
    /// Average colour around a normalised (top-left origin) point.
    func average(atNormalized x: Double, _ y: Double, radius: Int = 1) -> SIMD3<Float> {
        let cx = Int(min(max(x, 0), 1) * Double(width - 1))
        let cy = Int(min(max(y, 0), 1) * Double(height - 1))
        var sum = SIMD3<Float>(0, 0, 0)
        var n: Float = 0
        for dy in -radius...radius {
            for dx in -radius...radius {
                sum += rgb(cx + dx, cy + dy)
                n += 1
            }
        }
        return sum / n
    }
}

/// One opened photo. RAW files (Sony ARW, ProRAW/DNG, ...) go through Apple's CIRAWFilter;
/// anything else (JPEG/HEIC) is loaded as a plain CIImage.
final class EditSession: @unchecked Sendable {
    private let raw: CIRAWFilter?
    private let plain: CIImage?
    let nativeSize: CGSize
    private let decodeLock = NSLock()

    // Look table cache
    private let cubeLock = NSLock()
    private var cubeKey: LookKey?
    private var cubeData: Data?

    var ctx: CIContext { LumenGPU.context }

    init?(url: URL) {
        let isRaw = UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .rawImage) ?? false
        if isRaw, let f = CIRAWFilter(imageURL: url) {
            f.extendedDynamicRangeAmount = 1.0
            f.sharpnessAmount = 0
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let o = props[kCGImagePropertyOrientation] as? UInt32,
               let orientation = CGImagePropertyOrientation(rawValue: o) {
                f.orientation = orientation
            }
            raw = f
            plain = nil
            nativeSize = f.nativeSize
        } else if let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
            raw = nil
            plain = img
            nativeSize = img.extent.size
        } else {
            return nil
        }
    }

    // MARK: Decoding

    /// Linear working-space image whose long edge is at most `maxEdge` (nil = full size), origin at (0,0).
    func decode(maxEdge: CGFloat?) -> CIImage? {
        decodeLock.lock(); defer { decodeLock.unlock() }
        let longEdge = max(nativeSize.width, nativeSize.height)
        let target = maxEdge.map { min(1, $0 / longEdge) } ?? 1
        if let raw {
            raw.scaleFactor = Float(target)
            guard let o = raw.outputImage else { return nil }
            return Self.normalized(o)
        }
        guard var img = plain else { return nil }
        if target < 1 {
            img = img.applyingFilter("CILanczosScaleTransform",
                                     parameters: [kCIInputScaleKey: target, kCIInputAspectRatioKey: 1.0])
        }
        return Self.normalized(img)
    }

    /// Decodes and analyses the photo. `materialize` renders the pieces into GPU buffers so slider drags are cheap.
    func makeSource(maxEdge: CGFloat?, materialize: Bool) -> ImageSource? {
        guard LumenKernels.shared != nil, let decoded = decode(maxEdge: maxEdge) else { return nil }
        var base = decoded
        if materialize, let m = Self.materialized(decoded) { base = m }
        return analyse(base, materialize: materialize)
    }

    private func analyse(_ base: CIImage, materialize: Bool) -> ImageSource? {
        guard let k = LumenKernels.shared else { return nil }
        let ext = base.extent
        let E = max(ext.width, ext.height)

        // Small copy for the wide blurs and the statistics.
        let f = min(1, 640 / E)
        var small = base
        if f < 1 {
            small = base.applyingFilter("CILanczosScaleTransform",
                                        parameters: [kCIInputScaleKey: f, kCIInputAspectRatioKey: 1.0])
            small = Self.normalized(small)
        }
        let sext = small.extent
        let sx = ext.width / sext.width, sy = ext.height / sext.height

        // Statistics grid for dehaze, auto and masks (96 px).
        let gs = min(1, 96 / max(sext.width, sext.height))
        let tiny = Self.normalized(small.transformed(by: CGAffineTransform(scaleX: gs, y: gs)))
        let grid = readGrid(tiny)

        // Dark channel + atmospheric light.
        let (air, darkNorm) = Self.estimateAir(grid)

        // log-luminance of the small copy
        let logS = k.logLum.apply(extent: sext, arguments: [small])!
        let sigmaClar = 0.011 * E * f
        let sigmaBase = 0.04 * E * f
        let sigmaChroma = max(1, 0.004 * E * f)

        let clarS = Self.blur(logS, sigmaClar, sext)
        let baseS = Self.blur(logS, sigmaBase, sext)
        let minS = k.minChannel.apply(extent: sext, arguments: [small])!
        let eroded = Self.cropped(minS.clampedToExtent().applyingFilter("CIMorphologyMinimum",
                                                                        parameters: [kCIInputRadiusKey: max(2, 0.006 * E * f)]), sext)
        let darkS = Self.blur(eroded, max(2, 0.01 * E * f), sext)
        let l2S = k.pack3.apply(extent: sext, arguments: [baseS, darkS, Self.constant(0, sext)])!
        let chromaS = Self.blur(small, sigmaChroma, sext)

        func upscaled(_ img: CIImage) -> CIImage {
            var m = img
            if materialize, let mm = Self.materialized(img) { m = mm }
            if f >= 1 { return m }
            return m.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .cropped(to: ext)
        }

        // Full-resolution fine blurs.
        let logF = k.logLum.apply(extent: ext, arguments: [base])!
        let sharpF = Self.blur(logF, max(0.5, 0.00045 * E), ext)
        let texF = Self.blur(logF, max(1.2, 0.0016 * E), ext)
        var l1 = k.pack3.apply(extent: ext, arguments: [sharpF, texF, upscaled(clarS)])!
        if materialize, let m = Self.materialized(l1) { l1 = m }

        return ImageSource(base: base, l1: l1, l2: upscaled(l2S), chroma: upscaled(chromaS),
                           air: air, darkNorm: darkNorm, stats: grid)
    }

    // MARK: Statistics

    func readGrid(_ img: CIImage) -> PixelGrid {
        let w = max(1, Int(img.extent.width.rounded())), h = max(1, Int(img.extent.height.rounded()))
        var data = [Float](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { p in
            ctx.render(img, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .RGBAf, colorSpace: LumenGPU.workingSpace)
        }
        return PixelGrid(width: w, height: h, data: data)
    }

    private static func estimateAir(_ g: PixelGrid) -> (SIMD3<Float>, Float) {
        var darks: [(Float, Int)] = []
        darks.reserveCapacity(g.width * g.height)
        for i in 0..<(g.width * g.height) {
            let c = SIMD3(g.data[i * 4], g.data[i * 4 + 1], g.data[i * 4 + 2])
            darks.append((max(0, min(c.x, min(c.y, c.z))), i))
        }
        darks.sort { $0.0 > $1.0 }
        let n = max(4, darks.count / 100)
        var air = SIMD3<Float>(0, 0, 0)
        var dsum: Float = 0
        for j in 0..<n {
            let i = darks[j].1
            air += SIMD3(g.data[i * 4], g.data[i * 4 + 1], g.data[i * 4 + 2])
            dsum += darks[j].0
        }
        air /= Float(n)
        let dn = max(dsum / Float(n), 0.03)
        return (SIMD3(max(air.x, 0.05), max(air.y, 0.05), max(air.z, 0.05)), dn)
    }

    // MARK: Look table

    func lookCube(_ s: EditSettings) -> Data? {
        let key = LookKey(curves: s.curves, hsl: s.hsl, grading: s.grading, bw: s.blackAndWhite)
        cubeLock.lock(); defer { cubeLock.unlock() }
        if cubeKey != key || cubeData == nil {
            cubeData = ColorCube.make(curves: s.curves, hsl: s.hsl, grading: s.grading, blackAndWhite: s.blackAndWhite)
            cubeKey = key
        }
        return cubeData
    }

    // MARK: Small helpers

    static func normalized(_ img: CIImage) -> CIImage {
        let e = img.extent
        if e.minX == 0 && e.minY == 0 { return img }
        return img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    static func cropped(_ img: CIImage, _ ext: CGRect) -> CIImage { img.cropped(to: ext) }

    static func constant(_ v: CGFloat, _ ext: CGRect) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1)).cropped(to: ext)
    }

    static func blur(_ img: CIImage, _ sigma: CGFloat, _ ext: CGRect) -> CIImage {
        guard sigma > 0.3 else { return img }
        return img.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
            .cropped(to: ext)
    }

    /// Renders into a half-float GPU buffer and wraps it as an image (no colour conversion).
    static func materialized(_ img: CIImage) -> CIImage? {
        let e = img.extent
        let w = Int(e.width.rounded()), h = Int(e.height.rounded())
        guard w > 0, h > 0 else { return nil }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }
        LumenGPU.context.render(img, to: buf, bounds: CGRect(x: e.minX, y: e.minY, width: CGFloat(w), height: CGFloat(h)),
                                colorSpace: LumenGPU.workingSpace)
        return CIImage(cvPixelBuffer: buf, options: [.colorSpace: NSNull()])
    }
}

struct LookKey: Hashable {
    var curves: ToneCurves
    var hsl: HSLSettings
    var grading: ColorGrading
    var bw: Bool
}
