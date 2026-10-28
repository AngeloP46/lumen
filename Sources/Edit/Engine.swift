import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Metal
import ImageIO
import UniformTypeIdentifiers

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

    /// The context the canvas draws and freezes with. Like `context`, but it does not keep the intermediate results of a
    /// render: the shared one holds on to them (until `clearCaches`) so that the next render of the same graph is quicker,
    /// and for a picture with Lens Blur, masks and HDR that is a gigabyte or more standing between frames (owner's phone,
    /// 0.1.599, 18:09: 2.5 GB in use before a render storm ran out). Drawing is edit-by-edit anyway: the layers an edit
    /// reads are bitmaps already, so there is little to reuse.
    static let drawContext: CIContext = {
        let opts: [CIContextOption: Any] = [.workingColorSpace: workingSpace, .workingFormat: CIFormat.RGBAh,
                                            .cacheIntermediates: false]
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
    var lensRamp: CIColorKernel?
    var lensRefinedRamp: CIColorKernel?
    /// Lens-like Lens Blur (optional: without them the older smooth blur is used).
    var lensWeigh: CIColorKernel?, lensCompose: CIColorKernel?
    /// Edge refinement for AI masks (optional: without it masks keep their soft edges).
    var gfPack: CIColorKernel?, gfCoef: CIColorKernel?, gfApply: CIColorKernel?
    /// Reconstruct the broad base from a medium guide and its small bilateral detail field.
    var clarityBase: CIColorKernel?
    /// Sky seen through trees (optional: without them the sky mask is the scene model's alone).
    var skyWeigh: CIColorKernel?, leafWeigh: CIColorKernel?, skyGaps: CIColorKernel?
    /// Full-resolution texture for big heals (optional: without it big heals keep the model's softer fill).
    var healDetail: CIColorKernel?, healEnergy: CIColorKernel?
    /// AI Denoise: the stored noise taken out of a decode (optional: without it AI Denoise is off).
    var noiseRemove: CIColorKernel?

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
                            clip: k("lumenClip"), rangeMask: k("lumenRangeMask"), lensRamp: k("lumenLensRamp"), lensRefinedRamp: k("lumenLensRefinedRamp"),
                            lensWeigh: k("lumenLensWeigh"), lensCompose: k("lumenLensCompose"),
                            gfPack: k("lumenGFPack"), gfCoef: k("lumenGFCoef"), gfApply: k("lumenGFApply"),
                            clarityBase: k("lumenClarityBase"),
                            skyWeigh: k("lumenSkyWeigh"), leafWeigh: k("lumenLeafWeigh"), skyGaps: k("lumenSkyGaps"),
                            healDetail: k("lumenHealDetail"), healEnergy: k("lumenHealEnergy"),
                            noiseRemove: k("lumenNoiseRemove"))
    }()
}

private final class BundleToken {}

/// A decoded image at a working size plus the analysis layers the develop kernel needs.
/// Layer encoding: e = (log2(Y / 0.18) + 8) / 16.
///  - l1: R = log-luminance blurred finely (sharpening), G = medium (texture), B = wide (clarity)
///  - l2: R = strictly local edge range (never expanded across the scene), G = dark channel (dehaze)
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
    /// Brush masks by component and a cheap summary of its strokes. Keying by the whole component hashed every point
    /// ever painted on each lookup, and each new point's version pushed the cache over its limit and emptied it,
    /// other brushes included (code review, 19 Oct). Only the newest version of each component is kept.
    struct RasterKey: Hashable {
        let id: UUID, feather: Double, autoMask: Bool, strokes: [StrokeSummary]
        struct StrokeSummary: Hashable { let count: Int, size: Double, erase: Bool, feather: Double?, first: Pt?, middle: Pt?, last: Pt? }
        init(_ c: MaskComponent) {
            id = c.id; feather = c.feather; autoMask = c.autoMask
            strokes = c.strokes.map {
                StrokeSummary(count: $0.points.count, size: $0.size, erase: $0.erase, feather: $0.feather,
                              first: $0.points.first, middle: $0.points.isEmpty ? nil : $0.points[$0.points.count / 2], last: $0.points.last)
            }
        }
    }
    private var raster: [RasterKey: CIImage] = [:]
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
    struct MaskSnapshot {
        let masks: [String: CIImage]
        let tried: Set<String>
        let failures: Set<String>
    }
    func snapshotMasks() -> MaskSnapshot {
        lock.lock(); defer { lock.unlock() }
        return MaskSnapshot(masks: masks, tried: tried, failures: failedKeys)
    }
    /// Preview, detail, export and undo use the same outcomes. A failed request must never turn into a
    /// successful empty selection just because its cached masks were copied to another decoded source.
    func restoreMasks(_ snapshot: MaskSnapshot, scaleX: CGFloat = 1, scaleY: CGFloat = 1) {
        let images = snapshot.masks.mapValues { image in
            guard scaleX != 1 || scaleY != 1 else { return image }
            let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            // These are scalar fields over the whole photo. Keep the border value during interpolation;
            // transparent samples outside a finite preview must not weaken the full-size selection's edge.
            return image.clampedToExtent().transformed(by: transform).cropped(to: image.extent.applying(transform))
        }
        lock.lock(); defer { lock.unlock() }
        masks = images; tried = snapshot.tried; failedKeys = snapshot.failures
    }
    func hasTried(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return tried.contains(key) }

    /// An AI step that failed (the request threw, the model wouldn't load, no memory) as opposed to one that ran and found
    /// nothing. Before, both came back as nil and were remembered as "tried", so a failure read "No people found in this
    /// photo" and could never be retried (quality checklist A18).
    private var failedKeys: Set<String> = []
    func noteFailure(_ key: String) { lock.lock(); failedKeys.insert(key); lock.unlock() }
    var failures: Set<String> { lock.lock(); defer { lock.unlock() }; return failedKeys }
    /// Lets the AI try again for everything that failed.
    func clearFailures() {
        lock.lock(); defer { lock.unlock() }
        tried.subtract(failedKeys)
        for k in failedKeys { masks[k] = nil }
        failedKeys = []
    }

    /// Estimated depth (see Masks.swift computeDepth), kept for picking a depth by tapping and for the range graph.
    var depthField: DepthField? { lock.lock(); defer { lock.unlock() }; return depth }
    func storeDepth(_ d: DepthField?) { lock.lock(); defer { lock.unlock() }; if let d { depth = d } }
    /// What the scene model saw (Sky and Landscape masks).
    var sceneField: SceneField? { lock.lock(); defer { lock.unlock() }; return scene }
    func storeScene(_ s: SceneField?) { lock.lock(); defer { lock.unlock() }; if let s { scene = s } }

    func cachedRaster(_ c: MaskComponent) -> CIImage? { lock.lock(); defer { lock.unlock() }; return raster[RasterKey(c)] }
    func storeRaster(_ c: MaskComponent, _ img: CIImage) {
        lock.lock(); defer { lock.unlock() }
        raster = raster.filter { $0.key.id != c.id }   // older versions of this brush
        if raster.count > 48 { raster.removeAll() }
        raster[RasterKey(c)] = img
    }
}

/// Depth estimated for a photo: 0 = nearest ... 1 = farthest, row-major, top row first.
struct DepthField: Sendable {
    var width: Int
    var height: Int
    var values: [Float]
    /// 64 bins over 0...1, scaled so the tallest is 1 (drawn behind the depth range editor).
    var histogram: [Float]

    /// Percentiles give the distance slider useful travel even when estimated depths occupy a narrow band.
    var usefulRange: ClosedRange<Double> {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return 0...1 }
        let low = Double(sorted[(sorted.count - 1) / 50])
        let high = Double(sorted[(sorted.count - 1) * 49 / 50])
        return max(0, low - 0.02)...min(1, max(high + 0.02, low + 0.04))
    }

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
    private static let lifecycleLock = NSLock()
    private static var readers: [UUID: Int] = [:]
    private static var pendingRemoval: Set<UUID> = []
    private static var deletedOwners: Set<String> = []

    /// A queued thumbnail/export keeps the immutable patches until it has finished rendering.
    final class Lease: @unchecked Sendable {
        private var ids: Set<UUID>
        init(_ ids: Set<UUID>) { self.ids = ids }
        func close() {
            HealStore.lifecycleLock.lock(); defer { HealStore.lifecycleLock.unlock() }
            for id in ids {
                let remaining = (HealStore.readers[id] ?? 1) - 1
                if remaining > 0 { HealStore.readers[id] = remaining }
                else {
                    HealStore.readers.removeValue(forKey: id)
                    if HealStore.pendingRemoval.remove(id) != nil { HealStore.removeFiles(id) }
                }
            }
            ids.removeAll()
        }
        deinit { close() }
    }

    static func retain(_ ids: Set<UUID>) -> Lease {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        for id in ids { readers[id, default: 0] += 1 }
        return Lease(ids)
    }

    /// Finds every Heal reference, including disabled edits and all saved undo/redo snapshots.
    /// Reading the JSON rather than decoding settings preserves references from older sidecars.
    static func references(in value: Any) -> Set<UUID> {
        var ids = Set<UUID>()
        if let object = value as? [String: Any] {
            if let spots = object["heals"] as? [[String: Any]] {
                for spot in spots {
                    if let text = spot["id"] as? String, let id = UUID(uuidString: text) { ids.insert(id) }
                }
            }
            for child in object.values { ids.formUnion(references(in: child)) }
        } else if let array = value as? [Any] {
            for child in array { ids.formUnion(references(in: child)) }
        }
        return ids
    }

    private static func ownerURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString)-owner.json") }

    /// Serialises patch writes against deletion. A late Heal result cannot recreate deleted photo data.
    static func write(_ id: UUID, owner: URL, body: () throws -> Void) throws -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        let key = owner.standardizedFileURL.path
        guard !deletedOwners.contains(key) else { return false }
        do {
            try body()
            // Imported photo filenames contain their UUID and survive iOS container relocation.
            try JSONEncoder().encode(owner.lastPathComponent).write(to: ownerURL(id), options: .atomic)
            return true
        } catch { removeFiles(id); throw error }
    }

    /// Includes patches no longer present in the latest capped history. Only owner records are scanned;
    /// unrelated patches and active writes are never swept. Older patches are recovered from sidecar IDs.
    static func markDeleted(owner: URL) -> Set<UUID> {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        let key = owner.standardizedFileURL.path
        deletedOwners.insert(key)
        var ids = Set<UUID>()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasSuffix("-owner.json") {
            guard let data = try? Data(contentsOf: file), let recorded = try? JSONDecoder().decode(String.self, from: data),
                  recorded == owner.lastPathComponent, let id = UUID(uuidString: String(file.lastPathComponent.dropLast(11))) else { continue }
            ids.insert(id)
        }
        return ids
    }

    static func remove(_ ids: Set<UUID>) {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        for id in ids {
            if readers[id, default: 0] > 0 { pendingRemoval.insert(id) }
            else { removeFiles(id) }
        }
    }

    private static func removeFiles(_ id: UUID) {
        for url in [patchURL(id), maskURL(id), ownerURL(id)] {
            cache.removeObject(forKey: url.lastPathComponent as NSString)
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func patchURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).png") }
    static func maskURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString)-mask.png") }

    private static func load(_ url: URL, raw: Bool) -> CIImage? {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
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
            guard let loaded = load(patchURL(h.id), raw: false), let mask = load(maskURL(h.id), raw: true) else { continue }
            let patch = loaded.settingAlphaOne(in: loaded.extent)   // patches are always opaque
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
    let originalURL: URL
    private let decodeLock = NSLock()
    /// Healed spots to paint into every decode (preview, full resolution, export, thumbnails). Set from the edits
    /// before decoding; `renderCGImage(_:maxEdge:)` and `renderData` do it themselves.
    var heals: [HealSpot] {
        get { decodeLock.lock(); defer { decodeLock.unlock() }; return healList }
        set { decodeLock.lock(); healList = newValue; decodeLock.unlock() }
    }
    private var healList: [HealSpot] = []
    /// AI Denoise amount (0...1) mixed into every decode when the cleaned copy exists (Denoise.swift). Set from the
    /// edits like `heals`.
    var denoiseAmount: Double {
        get { decodeLock.lock(); defer { decodeLock.unlock() }; return denoiseValue }
        set { decodeLock.lock(); denoiseValue = newValue; decodeLock.unlock() }
    }
    private var denoiseValue: Double = 0
    /// Decoded in HDR mode (RAW with extended range, gain-map photos expanded): AI Denoise keeps one copy per mode.
    let hdrDecode: Bool
    /// Which RAW decoder reads this photo (an iOS update can bring a new one, and the noise AI Denoise stored is only
    /// right for the decoder it was made with; quality checklist B8). "plain" for JPEG, HEIC and the like.
    let decoderTag: String

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
        originalURL = url
        hdrDecode = expandHDR
        let isRaw = UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .rawImage) ?? false
        if isRaw, let f = CIRAWFilter(imageURL: url) {
            // Deliberate hybrid pipeline: retain Apple's camera-specific base rendering (tone/gamut mapping,
            // baseline exposure and RAW noise reduction), then apply Lumen's relative edits in linear P3.
            // Linear colour encoding does not make that default rendering scene-referred sensor data.
            // Changing this base would also invalidate the saved Heal patches and AI Denoise residuals.
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
            decoderTag = f.decoderVersion.rawValue
            // the size AS SHOWN: CIRAWFilter.nativeSize is the sensor's (landscape) size even for a portrait photo,
            // which made Heal measure portrait RAWs sideways (wrong spot, black fills off the edge). The output's
            // extent at full scale has the orientation applied (nothing is rendered to read it).
            f.scaleFactor = 1
            nativeSize = f.outputImage.map { $0.extent.size } ?? f.nativeSize
        } else if let img = Self.loadPlain(url, expandHDR: expandHDR) {
            raw = nil
            plain = img
            decoderTag = "plain"
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

    /// The photo without heals (Heal needs it to rebuild a spot from scratch), with AI Denoise if it is on.
    func decodeUnhealed(maxEdge: CGFloat?) -> CIImage? {
        guard let img = decodeCamera(maxEdge: maxEdge) else { return nil }
        return withDenoise(img, amount: denoiseValue)
    }

    /// `decodeCamera` taking the decode lock (AI Denoise reads the photo this way).
    func decodeCameraLocked(maxEdge: CGFloat?) -> CIImage? {
        decodeLock.lock(); defer { decodeLock.unlock() }
        return decodeCamera(maxEdge: maxEdge)
    }

    /// The photo exactly as the camera made it (no heals, no AI Denoise).
    func decodeCamera(maxEdge: CGFloat?) -> CIImage? {
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
        return analyse(materializedOrLazy(decoded, materialize), materialize: materialize)
    }

    /// The decoded photo in a GPU buffer. If that fails the lazy graph is used, which re-runs the RAW engine for every
    /// render (21 Oct review: a likely cause of memory running out), so it is tried again once and logged.
    private func materializedOrLazy(_ decoded: CIImage, _ materialize: Bool) -> CIImage {
        guard materialize else { return decoded }
        if let m = Self.materialized(decoded) { return m }
        ctx.clearCaches()
        if let m = Self.materialized(decoded) { return m }
        Self.stepNote?("couldn't keep a \(Int(decoded.extent.width))x\(Int(decoded.extent.height)) copy in memory: working from the file")
        return decoded
    }

    /// The same with an explicit heal list (the before view and the split compare use the photo without heals).
    func makeSource(maxEdge: CGFloat?, materialize: Bool, heals list: [HealSpot], denoise: Bool = true) -> ImageSource? {
        guard LumenKernels.shared != nil else { return nil }
        let decoded: CIImage?
        if denoise { decoded = decode(maxEdge: maxEdge, heals: list) }
        else {
            // the original: as the camera made it (no AI Denoise), with only the heals asked for
            decodeLock.lock()
            decoded = decodeCamera(maxEdge: maxEdge).map { HealStore.apply(list, to: $0) }
            decodeLock.unlock()
        }
        guard let decoded else { return nil }
        return analyse(materializedOrLazy(decoded, materialize), materialize: materialize)
    }

    /// Kept internal so engine invariants can be checked with exact linear fixtures, without encoding/resampling
    /// a test image first (those operations can introduce their own boundary pixels).
    func analyse(_ base: CIImage, materialize: Bool) -> ImageSource? {
        guard let k = LumenKernels.shared, let reconstruct = k.clarityBase else { return nil }
        let ext = base.extent
        let E = max(ext.width, ext.height)

        // Small copy for the wide blurs and the statistics.
        let f = min(1, 640 / E)
        var small = base
        if f < 1 {
            // Clamp before resampling so transparent pixels cannot contaminate the edge coefficients.
            let target = ext.applying(CGAffineTransform(scaleX: f, y: f))
            small = base.clampedToExtent().applyingFilter("CILanczosScaleTransform",
                parameters: [kCIInputScaleKey: f, kCIInputAspectRatioKey: 1.0]).cropped(to: target)
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
        let sigmaClar = 0.035 * E * f
        let sigmaChroma = max(1, 0.004 * E * f)

        let minS = k.minChannel.apply(extent: sext, arguments: [small])!
        let eroded = Self.cropped(minS.clampedToExtent().applyingFilter("CIMorphologyMinimum",
                                                                        parameters: [kCIInputRadiusKey: max(2, 0.006 * E * f)]), sext)
        let darkS = Self.blur(eroded, max(2, 0.01 * E * f), sext)
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
        // A bilateral grid preserves boundaries through its averaging weights, not by switching off whole
        // neighborhoods. Analyze the already-smoothed medium guide so fine grain is outside this band.
        let guide = Self.normalized(texF.clampedToExtent().applyingFilter("CILanczosScaleTransform",
            parameters: [kCIInputScaleKey: f, kCIInputAspectRatioKey: 1.0]).cropped(to: sext))
        let gw = Int(guide.extent.width.rounded()), gh = Int(guide.extent.height.rounded())
        var pixels = [Float](repeating: 0, count: gw * gh * 4)
        pixels.withUnsafeMutableBytes { p in
            ctx.render(guide.clampedToExtent(), toBitmap: p.baseAddress!, rowBytes: gw * 16,
                       bounds: CGRect(x: 0, y: 0, width: gw, height: gh), format: .RGBAf, colorSpace: nil)
        }
        let values = (0..<(gw * gh)).map { pixels[$0 * 4] * 16 - 8 }
        let residual = BilateralClarity.residual(values, width: gw, height: gh, spatialSigma: Float(sigmaClar))
        for i in residual.indices { pixels[i * 4] = residual[i]; pixels[i * 4 + 1] = 0; pixels[i * 4 + 2] = 0; pixels[i * 4 + 3] = 1 }
        let field = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: gw * 16,
                            size: CGSize(width: gw, height: gh), format: .RGBAf, colorSpace: nil)
        guard let clarity = reconstruct.apply(extent: ext, arguments: [texF, upscaled(field)]) else { return nil }
        // Only the immediate true-edge pixels need resampling-fringe protection. NEVER dilate this range
        // across the broad filter radius: that was the 0.1.737 car-photo coverage failure.
        let rangeRadius: CGFloat = 3
        let logMax = logS.clampedToExtent().applyingFilter("CIMorphologyMaximum",
            parameters: [kCIInputRadiusKey: rangeRadius]).cropped(to: sext)
        let logMin = logS.clampedToExtent().applyingFilter("CIMorphologyMinimum",
            parameters: [kCIInputRadiusKey: rangeRadius]).cropped(to: sext)
        // max >= min, so symmetric difference is exactly the range without relying on blend operand order.
        let localRange = logMax.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: logMin])
            .cropped(to: sext)
        var l1 = k.pack3.apply(extent: ext, arguments: [sharpF, texF, clarity])!
        if materialize, let m = Self.materialized(l1) { l1 = m }

        let l2 = k.pack3.apply(extent: ext, arguments: [upscaled(localRange), upscaled(darkS), Self.constant(0, ext)])!

        return ImageSource(base: base, l1: l1, l2: l2, chroma: upscaled(chromaS),
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
