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
    private static let healModel: MLModel? = {
        guard let url = healModelURL else { return nil }
        let cfg = MLModelConfiguration()
        // GPU (and CPU): the conversion's notes warn its attention layers can overflow in the Neural Engine's
        // float16, so it is not given the Neural Engine
        cfg.computeUnits = .cpuAndGPU
        return try? MLModel(contentsOf: url, configuration: cfg)
    }()
    static var hasHealModel: Bool { healModel != nil }

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

        // 5. the model
        guard let imageC = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              let maskC = model.modelDescription.inputDescriptionsByName["mask"]?.imageConstraint,
              let imageV = try? MLFeatureValue(cgImage: cgImage, constraint: imageC, options: nil),
              let maskV = try? MLFeatureValue(cgImage: hole, constraint: maskC, options: nil),
              let features = try? MLDictionaryFeatureProvider(dictionary: ["image": imageV, "mask": maskV]),
              let result = try? model.prediction(from: features),
              let buffer = result.featureValue(for: "output")?.imageBufferValue
        else { return nil }
        let out = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: srgb])

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

    static func writeGrayPNG(_ img: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
