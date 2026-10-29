import Foundation
import CoreImage

/// Real finishing-kernel range/filter tests, independent of RAW tone and analysis.
func runEffectsQualityChecks() {
    guard let kernel = LumenKernels.shared?.finish else { check(false, "effects: finishing kernel unavailable"); return }
    func render(_ width: Int, _ height: Int, size: Double = 0, rough: Double = 0,
                vignette: Double = 0, midpoint: Double = 50, roundness: Double = 100,
                feather: Double = 50) -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let base = EditSession.constant(0.25, extent)
        let cell = (0.5 + size / 100 * 2.5) * Double(max(width, height)) / 2000
        return kernel.apply(extent: extent, arguments: [base,
            CIVector(x: vignette, y: midpoint / 100, z: feather / 100, w: roundness / 100),
            CIVector(x: Double(width), y: Double(height), z: vignette == 0 ? 0.6 : 0, w: cell),
            CIVector(x: rough / 100, y: 1, z: 7, w: 0)])!
    }
    func pixels(_ image: CIImage, bounds: CGRect) -> [Float] {
        let w = Int(bounds.width), h = Int(bounds.height)
        var p = [Float](repeating: 0, count: w * h * 4)
        p.withUnsafeMutableBytes { raw in
            LumenGPU.context.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                                    bounds: bounds, format: .RGBAf, colorSpace: nil)
        }
        return stride(from: 0, to: p.count, by: 4).map { p[$0] }
    }
    let roi = CGRect(x: 128, y: 32, width: 128, height: 64)
    for edge in [640, 1600, 2048] {
        var previous: [Float]?
        for size in [0.0, 5, 10, 20, 50, 80, 100] {
            let t = Date()
            let result = pixels(render(edge, edge / 4, size: size, rough: 50), bounds: roi)
            check(result.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "effects: grain is invalid at \(edge)/\(size)")
            if let previous {
                let delta = zip(previous, result).map { abs($0 - $1) }.reduce(0, +) / Float(result.count)
                check(delta > 0.00005, "effects: Grain Size has dead travel at \(edge)/\(size), delta \(delta)")
            }
            previous = result
            print("EFFECTS grain \(edge)/\(size): \(Date().timeIntervalSince(t)) s for \(result.count) pixels")
        }
    }
    // Exact pixel-footprint integration: a preview pixel equals the mean of its four twice-resolution pixels.
    // This tests antialiasing of the actual random field, rather than only finite output or changed slider inputs.
    for size in [0.0, 25, 100] { for rough in [0.0, 100] {
        let low = pixels(render(640, 160, size: size, rough: rough), bounds: roi)
        let highBounds = CGRect(x: roi.minX * 2, y: roi.minY * 2, width: roi.width * 2, height: roi.height * 2)
        let high = pixels(render(1280, 320, size: size, rough: rough), bounds: highBounds)
        var error: Float = 0
        for y in 0..<64 { for x in 0..<128 {
            let i = y * 2 * 256 + x * 2
            let mean = (high[i] + high[i + 1] + high[i + 256] + high[i + 257]) * 0.25
            error += abs(low[y * 128 + x] - mean)
        } }
        error /= Float(low.count)
        print("EFFECTS grain preview/export integration \(size)/\(rough): mean error \(error)")
        check(error < 0.001, "effects: Grain preview/export footprint disagrees at \(size)/\(rough) (\(error))")
    } }
    for (w, h) in [(400, 400), (600, 400), (900, 300), (300, 900)] {
        for midpoint in [50.0, 75, 85, 95] { for amount in [-1.0, 1] {
            let reference = pixels(render(w, h, vignette: amount, midpoint: 100),
                                   bounds: CGRect(x: w - 2, y: h - 2, width: 1, height: 1))[0]
            let corner = pixels(render(w, h, vignette: amount, midpoint: midpoint),
                                bounds: CGRect(x: w - 2, y: h - 2, width: 1, height: 1))[0]
            check(abs(corner - reference) > 0.001,
                  "effects: Vignette Midpoint dead at \(w)x\(h), \(midpoint), \(amount)")
        } }
    }
    // Feather must change the transition, while Roundness changes shape without losing corner calibration.
    for amount in [-1.0, 1] {
        func value(_ x: Int, _ y: Int, roundness: Double, feather: Double) -> Float {
            pixels(render(900, 300, vignette: amount, midpoint: 40, roundness: roundness, feather: feather),
                   bounds: CGRect(x: x, y: y, width: 1, height: 1))[0]
        }
        let hard = value(765, 150, roundness: 100, feather: 0)
        let soft = value(765, 150, roundness: 100, feather: 100)
        check(amount < 0 ? hard < soft - 0.01 : hard > soft + 0.01,
              "effects: Vignette Feather has no correctly directed transition response (\(amount), \(hard) -> \(soft))")
        // The short-axis side is inside the circular shape and outside the frame-following ellipse.
        let ellipseSide = value(450, 15, roundness: 0, feather: 50)
        let circleSide = value(450, 15, roundness: 100, feather: 50)
        check(amount < 0 ? ellipseSide < circleSide - 0.01 : ellipseSide > circleSide + 0.01,
              "effects: Vignette Roundness endpoints do not change shape (\(amount), \(ellipseSide), \(circleSide))")
        let ellipseCorner = value(898, 298, roundness: 0, feather: 50)
        let circleCorner = value(898, 298, roundness: 100, feather: 50)
        check(abs(ellipseCorner - circleCorner) < 0.003,
              "effects: Vignette Roundness changes calibrated corner strength (\(ellipseCorner), \(circleCorner))")
        print("EFFECTS Vignette \(amount): Feather transition \(hard)/\(soft), Roundness side \(ellipseSide)/\(circleSide), corners \(ellipseCorner)/\(circleCorner)")
    }
    for size in [0.0, 50, 100] {
        let image = render(640, 160, size: size, rough: 50)
        if let cg = LumenGPU.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace) {
            saveJPEG(cg, "effects-grain-\(Int(size)).jpg")
        }
    }
    // A crop microbenchmark misses the cost of two integrated octaves over the whole editing preview.
    for size in [0.0, 100] {
        let began = Date(), image = render(1600, 1067, size: size, rough: 100)
        let cg = LumenGPU.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace)
        let elapsed = Date().timeIntervalSince(began)
        print("EFFECTS full 1600px Grain Size\(size), Roughness100: \(elapsed) s on CI Mac")
        check(cg != nil, "effects: whole-preview grain render failed at Size\(size)")
    }
}
