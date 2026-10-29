import Foundation
import CoreImage

/// Resampling invariants on analytic slanted fine structure, with a 4x reference through the same geometry path.
func runGeometryQualityChecks() {
    guard let file = files.first, let session = EditSession(url: file) else { check(false, "geometry: session unavailable"); return }
    func image(_ scale: Int) -> CIImage {
        let w = 384 * scale, h = 256 * scale
        var rgba = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let xx = (Double(x) + 0.5) / Double(scale), yy = (Double(y) + 0.5) / Double(scale)
            let wave = sin(2 * Double.pi * (xx + yy * 0.37) / 12)
            let fine = sin(2 * Double.pi * (yy - xx * 0.21) / 8)
            let value = Float(0.35 + 0.12 * wave + 0.08 * fine)
            let i = (y * w + x) * 4
            rgba[i] = value; rgba[i + 1] = value; rgba[i + 2] = value
        } }
        return CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: w * 16,
                       size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
    }
    func sample(_ image: CIImage) -> [Float] {
        let e = image.extent
        let normal = EditSession.normalized(image)
        // Integral crop bounds expand by at most a native pixel. Compare the same normalized picture grid;
        // test aspect separately instead of mistaking different fractional output heights for missing pixels.
        let w = 192, h = 128
        let scale = CGFloat(h) / e.height
        let small = normal.clampedToExtent().applyingFilter("CILanczosScaleTransform",
            parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: CGFloat(w) / (e.width * scale)])
        var p = [Float](repeating: 0, count: w * h * 4)
        p.withUnsafeMutableBytes { raw in
            LumenGPU.context.render(small, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                                    bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
        }
        return stride(from: 0, to: p.count, by: 4).map { p[$0] }
    }
    let low = image(1), high = image(4)
    for turn in 0..<4 { for mirror in [false, true] { for angle in [-9.0, 0, 7.3] {
        var edits = EditSettings(); edits.quarterTurns = turn; edits.flipH = mirror; edits.straighten = angle
        edits.cropL = 0.12; edits.cropT = 0.10; edits.cropR = 0.88; edits.cropB = 0.90
        let a = session.geometry(low, edits), b = session.geometry(high, edits)
        let aspectDelta = abs(a.extent.width / a.extent.height - b.extent.width / b.extent.height)
        check(aspectDelta < 0.02, "geometry: scaled integral crop changes aspect excessively (\(aspectDelta))")
        let pa = sample(a), pb = sample(b)
        check(pa.count == pb.count && !pa.isEmpty, "geometry: scale/crop changes output aspect at turn \(turn), \(angle)")
        if pa.count == pb.count && !pa.isEmpty {
            let mean = zip(pa, pb).map { abs($0 - $1) }.reduce(0, +) / Float(pa.count)
            print("GEOMETRY 4x reference turn\(turn) mirror\(mirror) angle\(angle): mean error \(mean)")
            check(mean < 0.025 && pa.allSatisfy(\.isFinite),
                  "geometry: resampled fine detail differs from 4x reference (\(mean))")
        }
        if turn == 0 && !mirror, let cg = LumenGPU.context.createCGImage(a, from: a.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace) {
            saveJPEG(cg, "geometry-fine-\(angle).jpg")
        }
    } } }
    // Exercise CIPerspectiveTransform on the same analytic structure, rather than checking only a quad's bounds.
    // Central crops stay inside the known warped photo, so transparent margins cannot mask detail errors.
    for (index, vertical, horizontal, turn) in [(0, 35.0, -20.0, 0), (1, -45.0, 35.0, 1)] {
        var edits = EditSettings(); edits.tVertical = vertical; edits.tHorizontal = horizontal
        edits.tFill = false; edits.quarterTurns = turn; edits.flipH = index == 1
        edits.straighten = index == 1 ? 4 : 0
        edits.cropL = 0.2; edits.cropT = 0.2; edits.cropR = 0.8; edits.cropB = 0.8
        check(Homography.corners(edits) != nil, "geometry: perspective reference fixture did not activate the warp")
        let a = session.geometry(low, edits), b = session.geometry(high, edits)
        let aspectDelta = abs(a.extent.width / a.extent.height - b.extent.width / b.extent.height)
        let pa = sample(a), pb = sample(b)
        let error = zip(pa, pb).map { abs($0 - $1) }.reduce(0, +) / Float(pa.count)
        var unwarped = edits; unwarped.tVertical = 0; unwarped.tHorizontal = 0
        let original = sample(session.geometry(low, unwarped))
        let changed = zip(pa, original).map { abs($0 - $1) }.reduce(0, +) / Float(pa.count)
        print("GEOMETRY perspective 4x reference \(index), V\(vertical)/H\(horizontal)/turn\(turn): mean error \(error), warp response \(changed), aspect delta \(aspectDelta)")
        check(aspectDelta < 0.02 && pa.allSatisfy(\.isFinite) && error < 0.025,
              "geometry: perspective fine detail differs from 4x reference (\(index), error \(error), aspect \(aspectDelta))")
        check(changed > 0.015, "geometry: perspective fixture bypassed the actual image warp (\(changed))")
        if let cg = LumenGPU.context.createCGImage(a, from: a.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace) {
            saveJPEG(cg, "geometry-perspective-fine-\(index).jpg")
        }
    }
}
