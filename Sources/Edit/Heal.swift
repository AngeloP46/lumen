import CoreImage
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Heal: paint over something and the on-device LaMa model (large-mask inpainting, Apache-2.0) rebuilds that spot
/// from its surroundings. Lightroom-style: the rebuilt pixels are made once from the full-resolution photo and kept
/// (HealStore), and every decode paints them back in, so preview, 100 % view, export and thumbnails all agree.
extension EditSession {
    /// The model (compiled by CI into the app as LaMa.mlmodelc). Tests point `LUMEN_HEAL_MODEL` at one.
    nonisolated(unsafe) static var healModelURL: URL? = {
        if let p = ProcessInfo.processInfo.environment["LUMEN_HEAL_MODEL"] { return URL(fileURLWithPath: p) }
        return Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc")
    }()
    /// CPU only, full precision. The GPU (0.1.137: black) and the Neural Engine (0.1.139: dark fills on bright,
    /// saturated colours such as red paint or yellow plates) both run it in float16, which this model overflows.
    /// The CPU is slower (a few seconds) but gives the same answer as the Mac the engine test runs on.
    private static let healModel: MLModel? = loadHealModel(.cpuOnly)
    private static let healModelCPU: MLModel? = nil
    private static func loadHealModel(_ units: MLComputeUnits) -> MLModel? {
        guard let url = healModelURL else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        return try? MLModel(contentsOf: url, configuration: cfg)
    }
    static var hasHealModel: Bool { healModel != nil }
    /// What the last heal measured (engine test diagnostics).
    nonisolated(unsafe) static var healDiagnostics = ""

    static let healSide = 800   // the model's fixed input size

    /// Rebuilds the painted spot. `earlier` = the heals already made (the new one is built on top of them).
    /// Returns nil when the model is missing or fails. Slow (about a second): call off the main thread.
    func makeHeal(strokes: [BrushStroke], earlier: [HealSpot]) -> HealSpot? {
        guard let model = Self.healModel, !strokes.isEmpty else { return nil }
        let W = nativeSize.width, H = nativeSize.height, L = max(W, H)

        // 1. the painted area in photo pixels (y down), brush radius included
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for st in strokes where !st.erase {
            let r = CGFloat(st.size) * L / 2
            for p in st.points {
                minX = min(minX, CGFloat(p.x) * W - r); maxX = max(maxX, CGFloat(p.x) * W + r)
                minY = min(minY, CGFloat(p.y) * H - r); maxY = max(maxY, CGFloat(p.y) * H + r)
            }
        }
        guard minX.isFinite, maxX > minX, maxY > minY else { return nil }

        // 2. a square around it with plenty of context (the model copies from what it can see), kept inside the photo
        var side = max(maxX - minX, maxY - minY) * 2.4
        side = min(max(side, 192), min(W, H))
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let rx = min(max(cx - side / 2, 0), W - side), ry = min(max(cy - side / 2, 0), H - side)
        let region = CGRect(x: rx, y: ry, width: side, height: side)          // y down
        let n = CGFloat(Self.healSide)
        let k = n / side

        // 3. the photo there, full resolution, with the earlier heals, scaled to the model's 800 x 800
        guard let full = decode(maxEdge: nil, heals: earlier) else { return nil }
        let ciRegion = CGRect(x: region.minX, y: H - region.maxY, width: side, height: side)  // Core Image: y up
        let crop = full.cropped(to: ciRegion)
            .transformed(by: CGAffineTransform(translationX: -ciRegion.minX, y: -ciRegion.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1.0])
            .cropped(to: CGRect(x: 0, y: 0, width: n, height: n))
        // HDR highlights go above 1: squeeze the patch so its brightest pixel is 1 (8-bit for the model), undo later
        var peak = [Float](repeating: 0, count: 4)
        let mx = crop.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: crop.extent)])
        LumenGPU.context.render(mx, toBitmap: &peak, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                format: .RGBAf, colorSpace: nil)
        let scale = Double(max(1, peak[0], peak[1], peak[2]))
        var input = crop
        if scale > 1 {
            let s = CGFloat(1 / scale)
            input = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0)])
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = ctx.createCGImage(input, from: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBA8, colorSpace: srgb)
        else { return nil }

        // 4. the hole: the strokes on the 800 x 800 square (white = rebuild), a little wider than painted
        func strokeMask(grow: CGFloat, soften: CGFloat) -> CGImage? {
            guard let g = CGContext(data: nil, width: Self.healSide, height: Self.healSide, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            g.setFillColor(gray: 0, alpha: 1); g.fill(CGRect(x: 0, y: 0, width: n, height: n))
            g.setLineCap(.round); g.setLineJoin(.round)
            // CGContext rows go up: flip so photo y (down) maps correctly
            func pt(_ p: Pt) -> CGPoint { CGPoint(x: (CGFloat(p.x) * W - region.minX) * k, y: n - (CGFloat(p.y) * H - region.minY) * k) }
            for st in strokes {
                guard let first = st.points.first else { continue }
                g.setStrokeColor(gray: st.erase ? 0 : 1, alpha: 1)
                g.setLineWidth(max(2, CGFloat(st.size) * L * k + (st.erase ? -grow : grow) * 2))
                g.beginPath(); g.move(to: pt(first)); g.addLine(to: pt(first))
                for p in st.points.dropFirst() { g.addLine(to: pt(p)) }
                g.strokePath()
            }
            guard let img = g.makeImage() else { return nil }
            guard soften > 0 else { return img }
            let ci = Self.blur(Self.expandRed(CIImage(cgImage: img, options: [.colorSpace: NSNull()])), soften,
                               CGRect(x: 0, y: 0, width: n, height: n))
            return ctx.createCGImage(ci, from: ci.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        guard let hole = strokeMask(grow: 6, soften: 0), let blend = strokeMask(grow: 10, soften: 4) else { return nil }

        // 5. the model; an answer that is black (or far darker than its surroundings) inside the hole is a numeric
        //    failure, not a fill: try once more on the CPU, and never keep a broken patch
        func run(_ m: MLModel) -> CIImage? {
            // The pixels go in exactly as they are (sRGB-encoded bytes, mask 0/255). MLFeatureValue(cgImage:)
            // colour-matched them first, so the model saw (and painted) a much darker picture (0.1.139 and before).
            guard let imageC = m.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
                  let maskC = m.modelDescription.inputDescriptionsByName["mask"]?.imageConstraint,
                  let imagePB = Self.pixelBuffer(CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()]),
                                                 format: imageC.pixelFormatType, side: Self.healSide),
                  let maskPB = Self.pixelBuffer(Self.expandRed(CIImage(cgImage: hole, options: [.colorSpace: NSNull()])),
                                                format: maskC.pixelFormatType, side: Self.healSide),
                  case let imageV = MLFeatureValue(pixelBuffer: imagePB),
                  case let maskV = MLFeatureValue(pixelBuffer: maskPB),
                  let features = try? MLDictionaryFeatureProvider(dictionary: ["image": imageV, "mask": maskV]),
                  let result = try? m.prediction(from: features),
                  let buffer = result.featureValue(for: "output")?.imageBufferValue
            else { return nil }
            return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: srgb])
        }
        let ring = Self.meanInside(CIImage(cgImage: cgImage), mask: blend, invert: true)
        func plausible(_ o: CIImage) -> Bool {
            let inHole = Self.meanInside(o, mask: hole, invert: false)
            return inHole.isFinite && !(ring > 0.06 && inHole < ring * 0.3)
        }
        var answer = run(model)
        if let a = answer {
            Self.healDiagnostics = String(format: "ring %.3f, input hole %.3f, output hole %.3f, output ring %.3f, scale %.3f",
                                          ring, Self.meanInside(CIImage(cgImage: cgImage), mask: hole, invert: false),
                                          Self.meanInside(a, mask: hole, invert: false), Self.meanInside(a, mask: blend, invert: true), scale)
        }
        if answer == nil || !plausible(answer!), let cpu = Self.healModelCPU {
            answer = run(cpu)
        }
        guard let out = answer, plausible(out) else { return nil }

        // 6. keep it: the rebuilt square and where to blend it in
        let id = UUID()
        try? FileManager.default.createDirectory(at: HealStore.directory, withIntermediateDirectories: true)
        do {
            try ctx.writePNGRepresentation(of: out, to: HealStore.patchURL(id), format: .RGBA8, colorSpace: srgb)
            try Self.writeGrayPNG(blend, to: HealStore.maskURL(id))
        } catch { return nil }
        return HealSpot(id: id, strokes: strokes, x: Double(region.minX / W), y: Double(region.minY / H),
                        w: Double(side / W), h: Double(side / H), scale: scale)
    }

    /// Renders `img` into a new pixel buffer byte for byte (no colour conversion).
    static func pixelBuffer(_ img: CIImage, format: OSType, side: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                                      kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, side, side, format, attrs as CFDictionary, &pb) == kCVReturnSuccess, let buf = pb
        else { return nil }
        LumenGPU.context.render(img, to: buf, bounds: CGRect(x: 0, y: 0, width: side, height: side), colorSpace: nil)
        return buf
    }

    /// Mean brightness of `img` where `mask` is white (or, with `invert`, where it is black).
    static func meanInside(_ img: CIImage, mask: CGImage, invert: Bool) -> Float {
        let n = CGFloat(healSide)
        var m = expandRed(CIImage(cgImage: mask, options: [.colorSpace: NSNull()]))
        if invert { m = m.applyingFilter("CIColorInvert") }
        let r = CGRect(x: 0, y: 0, width: n, height: n)
        let weighted = img.cropped(to: r).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: m])
        var a = [Float](repeating: 0, count: 4), b = [Float](repeating: 0, count: 4)
        let ea = weighted.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
        let eb = m.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
        LumenGPU.context.render(ea, toBitmap: &a, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        LumenGPU.context.render(eb, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        guard b[0] > 1e-4 else { return 0 }
        return (a[0] + a[1] + a[2]) / 3 / b[0]
    }

    static func writeGrayPNG(_ img: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
