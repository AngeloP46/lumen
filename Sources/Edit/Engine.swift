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
    /// HDR kernels are optional: a broken one must only disable HDR, never SDR editing.
    var gain, gainLocal, applyGain: CIColorKernel?
    /// Clipping warning (optional too: a broken one only hides the warning).
    var clip: CIColorKernel?
    /// Band of a grey image (depth mask). Optional: a broken one only disables the Depth mask.
    var rangeMask: CIColorKernel?
    /// Edge refinement for AI masks (optional: without it masks keep their soft edges).
    var gfPack: CIColorKernel?, gfCoef: CIColorKernel?, gfApply: CIColorKernel?

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
                            combine: o, maskFinish: p, maskMul: q, overlay: r,
                            gain: k("lumenGain"), gainLocal: k("lumenGainLocal"), applyGain: k("lumenApplyGain"),
                            clip: k("lumenClip"), rangeMask: k("lumenRangeMask"),
                            gfPack: k("lumenGFPack"), gfCoef: k("lumenGFCoef"), gfApply: k("lumenGFApply"))
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
    private var depth: DepthField?
    private var scene: SceneField?

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
    func snapshotMasks() -> (masks: [String: CIImage], tried: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        return (masks, tried)
    }
    func hasTried(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return tried.contains(key) }

    /// Estimated depth (see Masks.swift computeDepth), kept for picking a depth by tapping and for the range graph.
    var depthField: DepthField? { lock.lock(); defer { lock.unlock() }; return depth }
    func storeDepth(_ d: DepthField?) { lock.lock(); defer { lock.unlock() }; if let d { depth = d } }
    /// What the scene model saw (Sky and Landscape masks).
    var sceneField: SceneField? { lock.lock(); defer { lock.unlock() }; return scene }
    func storeScene(_ s: SceneField?) { lock.lock(); defer { lock.unlock() }; if let s { scene = s } }

    func cachedRaster(_ c: MaskComponent) -> CIImage? { lock.lock(); defer { lock.unlock() }; return raster[c] }
    func storeRaster(_ c: MaskComponent, _ img: CIImage) {
        lock.lock(); defer { lock.unlock() }
        if raster.count > 24 { raster.removeAll() }
        raster[c] = img
    }
}

/// Depth estimated for a photo: 0 = nearest ... 1 = farthest, row-major, top row first.
struct DepthField: Sendable {
    var width: Int
    var height: Int
    var values: [Float]
    /// 64 bins over 0...1, scaled so the tallest is 1 (drawn behind the depth range editor).
    var histogram: [Float]

    /// Depth at a normalised point (x right, y down), averaged over a small neighbourhood.
    func value(atNormalized x: Double, _ y: Double) -> Float {
        let cx = Int((min(max(x, 0), 1) * Double(width - 1)).rounded())
        let cy = Int((min(max(y, 0), 1) * Double(height - 1)).rounded())
        var sum: Float = 0, n: Float = 0
        for dy in -2...2 { for dx in -2...2 {
            let px = cx + dx, py = cy + dy
            guard px >= 0, py >= 0, px < width, py < height else { continue }
            sum += values[py * width + px]; n += 1
        } }
        return n > 0 ? sum / n : 0.5
    }
}

/// Scene labels for a photo (one model class per cell, top row first) and the Landscape parts found in it.
struct SceneField: Sendable {
    var width: Int
    var height: Int
    var labels: [Int32]
    var found: Set<ScenePart>

    func coverage(_ parts: [ScenePart]) -> [Float] {
        let set = Set(parts.flatMap(\.classes))
        return labels.map { set.contains($0) ? 1 : 0 }
    }
}

/// Where healed patches live: `<id>.png` (the rebuilt pixels, sRGB, divided by the spot's `scale`) and
/// `<id>-mask.png` (where to blend them in, soft-edged). The app points `directory` at its library folder; files are
/// never changed once written, so a spot's id names its pixels for good (undo, reopening, export all find them).
enum HealStore {
    nonisolated(unsafe) static var directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("LumenHeals")
    private static let cache = NSCache<NSString, CIImage>()

    static func patchURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).png") }
    static func maskURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString)-mask.png") }

    private static func load(_ url: URL, raw: Bool) -> CIImage? {
        let key = url.lastPathComponent as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let opts: [CIImageOption: Any] = raw ? [.colorSpace: NSNull()] : [:]
        guard let img = CIImage(contentsOf: url, options: opts) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    /// Paints every spot's rebuilt pixels into `img` (any size: the spot's rectangle is a fraction of the photo).
    static func apply(_ heals: [HealSpot], to img: CIImage) -> CIImage {
        var out = img
        let ext = img.extent
        for h in heals {
            guard let patch = load(patchURL(h.id), raw: false), let mask = load(maskURL(h.id), raw: true) else { continue }
            // the spot's rectangle on this image (Core Image counts rows from the bottom)
            let r = CGRect(x: ext.minX + h.x * ext.width, y: ext.minY + (1 - h.y - h.h) * ext.height,
                           width: h.w * ext.width, height: h.h * ext.height)
            func fit(_ i: CIImage) -> CIImage {
                let e = i.extent
                return i.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                    .transformed(by: CGAffineTransform(scaleX: r.width / e.width, y: r.height / e.height))
                    .transformed(by: CGAffineTransform(translationX: r.minX, y: r.minY))
            }
            var p = fit(patch)
            if h.scale != 1 {
                let s = CGFloat(h.scale)
                p = p.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0)])
            }
            let m = fit(mask)
            out = p.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: m])
                .cropped(to: ext)
        }
        return out
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
    /// Healed spots to paint into every decode (preview, full resolution, export, thumbnails). Set from the edits
    /// before decoding; `renderCGImage(_:maxEdge:)` and `renderData` do it themselves.
    var heals: [HealSpot] {
        get { decodeLock.lock(); defer { decodeLock.unlock() }; return healList }
        set { decodeLock.lock(); healList = newValue; decodeLock.unlock() }
    }
    private var healList: [HealSpot] = []

    // Look table cache
    private let cubeLock = NSLock()
    private var cubeKey: LookKey?
    private var cubeData: Data?

    var ctx: CIContext { LumenGPU.context }

    /// `expandHDR` (HDR mode only): RAW files are decoded with all the highlight range Apple's RAW engine can give
    /// (extended dynamic range 2: about twice as much above white as the default 1), and JPEG/HEIC files that carry a
    /// gain map (iOS 18+) with their highlights above 1.0 instead of the SDR rendition. Default false keeps the SDR
    /// path unchanged.
    init?(url: URL, expandHDR: Bool = false) {
        let isRaw = UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .rawImage) ?? false
        if isRaw, let f = CIRAWFilter(imageURL: url) {
            f.extendedDynamicRangeAmount = expandHDR ? 2.0 : 1.0
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
        } else if let img = Self.loadPlain(url, expandHDR: expandHDR) {
            raw = nil
            plain = img
            nativeSize = img.extent.size
        } else {
            return nil
        }
    }

    private static func loadPlain(_ url: URL, expandHDR: Bool) -> CIImage? {
        if expandHDR, #available(iOS 18.0, macOS 15.0, *),
           let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: true]) {
            return img
        }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    // MARK: Decoding

    /// Linear working-space image whose long edge is at most `maxEdge` (nil = full size), origin at (0,0).
    func decode(maxEdge: CGFloat?) -> CIImage? {
        decodeLock.lock(); defer { decodeLock.unlock() }
        guard let img = decodeUnhealed(maxEdge: maxEdge) else { return nil }
        return HealStore.apply(healList, to: img)
    }

    /// The photo as the camera made it, without heals (Heal needs it to rebuild a spot from scratch).
    func decodeUnhealed(maxEdge: CGFloat?) -> CIImage? {
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

    /// Decode with heals for an explicit list (used while making a new heal, which must see the earlier ones).
    func decode(maxEdge: CGFloat?, heals list: [HealSpot]) -> CIImage? {
        decodeLock.lock(); defer { decodeLock.unlock() }
        guard let img = decodeUnhealed(maxEdge: maxEdge) else { return nil }
        return HealStore.apply(list, to: img)
    }

    /// Decodes and analyses the photo. `materialize` renders the pieces into GPU buffers so slider drags are cheap.
    func makeSource(maxEdge: CGFloat?, materialize: Bool) -> ImageSource? {
        guard LumenKernels.shared != nil, let decoded = decode(maxEdge: maxEdge) else { return nil }
        var base = decoded
        if materialize, let m = Self.materialized(decoded) { base = m }
        return analyse(base, materialize: materialize)
    }

    /// The same with an explicit heal list (the before view and the split compare use the photo without heals).
    func makeSource(maxEdge: CGFloat?, materialize: Bool, heals list: [HealSpot]) -> ImageSource? {
        guard LumenKernels.shared != nil, let decoded = decode(maxEdge: maxEdge, heals: list) else { return nil }
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
            if let mm = Self.materialized(img) { m = mm }   // always: these are small, and it stops the RAW decoding twice
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
        let n = min(darks.count, max(4, darks.count / 100))
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
