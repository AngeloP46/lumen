import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Synthetic photographs with known ordering, colour and detail. These exercise the rendered graph, rather than
/// asserting that a second implementation of the new formulas returns the same numbers.
func runImagingQualityChecks() {
    guard let kernels = LumenKernels.shared else { check(false, "imaging: kernels unavailable"); return }
    let context = LumenGPU.context
    func image(_ width: Int, _ height: Int = 8, _ pixel: (Int, Int) -> SIMD3<Float>) -> CIImage {
        var data = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let c = pixel(x, y), i = (y * width + x) * 4
            data[i] = c.x; data[i + 1] = c.y; data[i + 2] = c.z
        } }
        let bytes = data.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: bytes, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: LumenGPU.workingSpace)
    }
    func pixels(_ img: CIImage) -> [SIMD3<Float>] {
        let e = img.extent.integral, w = Int(e.width), h = Int(e.height)
        var data = [Float](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { p in
            context.render(img, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: nil)
        }
        return (0..<(w * h)).map { SIMD3(data[$0 * 4], data[$0 * 4 + 1], data[$0 * 4 + 2]) }
    }
    func source(_ img: CIImage, air: SIMD3<Float> = SIMD3(repeating: 0.8)) -> ImageSource {
        let e = img.extent, log = kernels.logLum.apply(extent: e, arguments: [img])!
        let l1 = kernels.pack3.apply(extent: e, arguments: [log, log, log])!
        let l2 = kernels.pack3.apply(extent: e, arguments: [log, EditSession.constant(0.1, e), EditSession.constant(0, e)])!
        return ImageSource(base: img, l1: l1, l2: l2, chroma: img, air: air, darkNorm: 0.2,
                           stats: PixelGrid(width: 1, height: 1, data: [0.18, 0.18, 0.18, 1]))
    }
    var fixtures: [URL] = []
    defer { for url in fixtures { try? FileManager.default.removeItem(at: url) } }
    func session(_ img: CIImage, _ name: String) -> EditSession? {
        let url = outDir.appendingPathComponent("imaging-\(name).png")
        fixtures.append(url)
        guard let data = context.pngRepresentation(of: img, format: .RGBA16, colorSpace: LumenGPU.displaySpace, options: [:]),
              (try? data.write(to: url)) != nil, let s = EditSession(url: url) else {
            check(false, "imaging: couldn't create \(name) fixture"); return nil
        }
        return s
    }
    guard let renderSession = session(image(4) { _, _ in SIMD3(repeating: 0.18) }, "session") else { return }
    func render(_ s: EditSettings, _ src: ImageSource) -> [SIMD3<Float>] {
        pixels(renderSession.develop(s, source: src, geometry: false, lens: .off))
    }
    func finite(_ values: [SIMD3<Float>]) -> Bool {
        !values.isEmpty && values.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
    }
    func luma(_ c: SIMD3<Float>) -> Float { c.x * 0.22897 + c.y * 0.69174 + c.z * 0.07929 }
    func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        max(abs(a.x - b.x), max(abs(a.y - b.y), abs(a.z - b.z)))
    }
    func difference(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return zip(a, b).map { distance($0.0, $0.1) }.reduce(0, +) / Float(a.count)
    }
    func increasing(_ row: ArraySlice<SIMD3<Float>>) -> Bool {
        zip(row, row.dropFirst()).allSatisfy { luma($0.1) + 0.0003 >= luma($0.0) }
    }

    // A saved recipe from the previous engine must now render through the single current engine, with all
    // adjustment values preserved. This checks the actual tolerant loader and resulting GPU rendition.
    do {
        let values: [Float] = [0.012, 0.08, 0.18, 0.4, 0.75, 0.99, 1.6]
        let src = source(image(values.count) { x, _ in SIMD3(repeating: values[x]) })
        var s = EditSettings()
        s.exposure = 0.5; s.shadows = 80; s.highlights = -80; s.whites = 50
        s.blacks = -30; s.brightness = 40; s.contrast = 30
        var saved = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        saved["processingVersion"] = 1; saved["formatVersion"] = 1
        let loaded = EditsFile.load(try! JSONSerialization.data(withJSONObject: saved)).settings
        let out = render(loaded, src), current = render(s, src)
        check(finite(out) && difference(out, current) < 0.0001, "imaging: an old recipe bypasses the current renderer")
    }

    // An ordered grey ramp must stay ordered under combinations, including summed masks past one slider's range.
    do {
        let width = 2048
        let ramp = image(width) { x, _ in SIMD3(repeating: Float(0.18 * exp2(-9 + Double(x) / Double(width - 1) * 13))) }
        let src = source(ramp)
        var cases: [EditSettings] = []
        for sign in [-1.0, 1.0] {
            var s = EditSettings(); s.shadows = sign * 100; s.highlights = -sign * 100
            s.whites = -sign * 100; s.blacks = sign * 100; s.brightness = sign * 100; s.contrast = -100
            cases.append(s)
        }
        var high = EditSettings(); high.highlights = -100; high.whites = -100; high.brightness = 100; cases.append(high)
        for (index, s) in cases.enumerated() {
            let out = render(s, src)
            check(finite(out) && increasing(out.prefix(width)), "imaging: combined tone case \(index) reverses a ramp")
            // Uniform accumulated planes represent fully overlapping masks: the shader must bound their sum.
            let ext = src.extent
            func plane(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
                CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1)).cropped(to: ext)
            }
            let local = [plane(0, 2, -2), plane(2, -2, 2), plane(0, 0, 0), plane(0, 0, 0), plane(0, 0, 2)]
            let vectors = [CIVector(x: 0, y: -1, z: -1, w: 1), CIVector(x: -1, y: 1, z: 0, w: 0),
                           CIVector(x: 0, y: 0, z: 0, w: 0), CIVector(x: 0, y: 0, z: 0, w: 0),
                           CIVector(x: 0, y: 1, z: 2, w: 0), CIVector(x: 0.8, y: 0.8, z: 0.8, w: 0.2)]
            var arguments: [Any] = [src.base, src.l1, src.l2, src.chroma]
            arguments += local
            arguments += vectors
            if let outImage = kernels.mainLocal.apply(extent: ext, arguments: arguments) {
                let p = pixels(outImage)
                check(finite(p) && increasing(p.prefix(width)), "imaging: overlapping tone masks reverse a ramp")
            } else { check(false, "imaging: overlapping tone mask render failed") }
        }
    }

    // A tiny negative dehaze tick must not inject HDR lamp brightness into dark parts of the frame.
    do {
        let black = image(32) { x, _ in SIMD3(repeating: 0.001 + Float(x) * 0.0002) }
        let src = source(black, air: SIMD3(8, 6, 5))
        let neutral = render(EditSettings(), src)
        var fresh = EditSettings(); fresh.dehaze = -1
        let p2 = render(fresh, src), d2 = difference(p2, neutral)
        check(finite(p2) && d2 < 0.0005,
              "imaging: -1 dehaze is too strong with HDR atmosphere (\(d2))")
    }

    // The CPU picker solves the exact adaptation used by the real shader, not an obsolete RGB-gain approximation.
    do {
        let cast: (Float, Float, Float) = (0.14, 0.18, 0.24)
        let pick = RelativeWhiteBalance.solve(cast)
        let expected = RelativeWhiteBalance.apply(cast, temperature: pick.temperature, tint: pick.tint)
        var s = EditSettings(); s.temperature = pick.temperature; s.tint = pick.tint
        let p = render(s, source(image(4) { _, _ in SIMD3(cast.0, cast.1, cast.2) }))[0]
        let e = SIMD3(expected.0, expected.1, expected.2)
        check(distance(p, e) < 0.002 && max(p.x, max(p.y, p.z)) - min(p.x, min(p.y, p.z)) < 0.002,
              "imaging: WB picker does not neutralize its sample in the shader (\(p), expected \(e))")
    }

    // A real 16-bit decoded fixture: ordinary NR should reduce known noise while preserving edge contrast and sign.
    do {
        let width = 1280, height = 64
        let noisy = image(width, height) { x, y in
            let base: Float = x < width / 2 ? 0.1 : 0.4
            let noise: Float = ((x * 17 + y * 13) % 11 < 5) ? -0.004 : 0.004
            return SIMD3(repeating: base + noise)
        }
        if let s = session(noisy, "noise"), let src = s.makeSource(maxEdge: nil, materialize: true) {
            let plain = render(EditSettings(), src)
            var nr = EditSettings(); nr.noiseReduction = 100
            let clean = render(nr, src)
            var combined = nr; combined.texture = -100; combined.brightness = 100; combined.highlights = -100
            let smooth = render(combined, src)
            func stats(_ p: [SIMD3<Float>], _ range: Range<Int>) -> (Float, Float) {
                let a = range.map { luma(p[$0]) }, mean = a.reduce(0, +) / Float(a.count)
                return (mean, a.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(a.count))
            }
            let region = 100..<500, before = stats(plain, region), after = stats(clean, region), both = stats(smooth, region)
            let covariance = region.map { (luma(plain[$0]) - before.0) * (luma(smooth[$0]) - both.0) }.reduce(0, +)
            let edgeBefore = stats(plain, 800..<1150).0 - before.0
            let edgeAfter = stats(clean, 800..<1150).0 - after.0
            check(finite(clean) && after.1 < before.1 * 0.85, "imaging: ordinary NR fails to reduce known noise (\(before.1) -> \(after.1))")
            check(edgeAfter > edgeBefore * 0.9, "imaging: ordinary NR destroys the fixture's edge contrast")
            check(finite(smooth) && covariance >= -0.00001, "imaging: Noise plus negative Texture reverses weak detail")
        } else { check(false, "imaging: noise fixture analysis failed") }
    }

    // The guided analysis must preserve constant tones and reduce broad-edge bleed at preview and larger sizes.
    do {
        let step = image(1280, 64) { x, _ in SIMD3(repeating: x < 640 ? 0.03 : 0.65) }
        if let s = session(step, "step") {
            var previews: [[SIMD3<Float>]] = []
            for edge in [CGFloat(640), CGFloat(1280)] {
                guard let fresh = s.makeSource(maxEdge: edge, materialize: true) else {
                    check(false, "imaging: step source at \(edge) unavailable"); continue
                }
                let w = Int(fresh.size.width), x = w / 2 - max(2, w / 128)
                let b = pixels(fresh.l1)
                let log = kernels.logLum.apply(extent: fresh.extent, arguments: [fresh.base])!
                let reference = pixels(log)
                let gaussian = pixels(EditSession.blur(log, 0.035 * fresh.longEdge, fresh.extent))
                let oldBleed = abs(gaussian[x].x - reference[x].x), newBleed = abs(b[x].z - reference[x].x)
                check(finite(b) && newBleed < oldBleed * 0.7,
                      "imaging: guided clarity does not protect an edge at \(edge) (\(oldBleed) -> \(newBleed))")
                var edits = EditSettings(); edits.shadows = 60; edits.highlights = -60; edits.brightness = 30
                let developed = renderSession.develop(edits, source: fresh, geometry: false, lens: .off)
                previews.append(pixels(EditSession.downscaled(developed, 64 / developed.extent.width)))
            }
            if previews.count == 2 {
                // Ignore only the boundary sample: resampling a discontinuity is resolution dependent.
                let low = [previews[0][8], previews[0][55]], high = [previews[1][8], previews[1][55]]
                check(difference(low, high) < 0.005, "imaging: preview/export low-frequency tones disagree")
            }
        }
        // An exact linear constant isolates analysis from the PNG decoder's own unclamped preview resampling.
        // Test the entire border too: the small guide must not introduce transparent-black Lanczos fringes.
        for edge in [640, 1280] {
                let flat = image(edge, 64) { _, _ in SIMD3(repeating: 0.18) }
                guard let src = renderSession.analyse(flat, materialize: true) else {
                    check(false, "imaging: flat source unavailable"); continue
                }
                let a = pixels(src.l1), b = pixels(src.l2)
                let reference = pixels(kernels.logLum.apply(extent: src.extent, arguments: [src.base])!)
                let error = a.indices.map { abs(a[$0].z - reference[$0].x) }.max() ?? .infinity
                print("IMAGING flat \(edge): guide \(reference.map(\.x).min() ?? 0)...\(reference.map(\.x).max() ?? 0), analysis \(a.map(\.z).min() ?? 0)...\(a.map(\.z).max() ?? 0), error \(error)")
                check(finite(a) && finite(b) && error < 0.004, "imaging: guided analysis changes a constant at \(edge) (\(error))")
        }
    }

    // B&W can be toned, while the LUT's true black/white nodes remain neutral.
    do {
        var grade = ColorGrading(); grade.global = GradeZone(hue: 30, sat: 60, lum: 10)
        func cube(_ grading: ColorGrading) -> [Float] {
            let data = ColorCube.make(curves: ToneCurves(), hsl: HSLSettings(), grading: grading,
                                      blackAndWhite: true)
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let modern = cube(grade)
        let n = ColorCube.dim, mid = ((n / 2 * n + n / 2) * n + n / 2) * 4
        check(max(modern[mid], max(modern[mid + 1], modern[mid + 2])) - min(modern[mid], min(modern[mid + 1], modern[mid + 2])) > 0.02,
              "imaging: B&W grading has no colour effect")
        check(modern.prefix(3).allSatisfy { abs($0) < 0.001 } && modern.suffix(4).prefix(3).allSatisfy { abs($0 - 1) < 0.001 },
              "imaging: colour grading tints the LUT black or white endpoint")
        var settings = EditSettings(); settings.blackAndWhite = true; settings.grading = grade
        let grey = source(image(4) { _, _ in SIMD3(repeating: 0.18) })
        let tinted = render(settings, grey)[0]
        check(max(tinted.x, max(tinted.y, tinted.z)) - min(tinted.x, min(tinted.y, tinted.z)) > 0.01,
              "imaging: B&W grading is lost in the actual develop graph")
    }

    // Saturation should preserve red hue and distinct luminance steps instead of flattening them by channel clipping.
    do {
        let red = image(64) { x, _ in SIMD3(0.45 + Float(x) / 63 * 0.45, 0.025, 0.008) }
        let src = source(red), before = render(EditSettings(), src)
        var s = EditSettings(); s.saturation = 100
        let out = render(s, src)
        func hue(_ c: SIMD3<Float>) -> Float { let lab = Ok.toLab(c.x, c.y, c.z); return atan2f(lab.2, lab.1) }
        let drift = zip(before, out).map { abs(hue($0.0) - hue($0.1)) }.max() ?? .infinity
        check(finite(out) && out.allSatisfy { min($0.x, min($0.y, $0.z)) >= -0.001 && max($0.x, max($0.y, $0.z)) <= 1.001 },
              "imaging: saturation produced invalid or out-of-gamut pixels")
        check(drift < 0.04 && increasing(out.prefix(64)) && luma(out[63]) - luma(out[0]) > 0.02,
              "imaging: saturated red hue/gradient damaged (max hue drift \(drift))")
    }
    // The first tiny edit must not switch the gamut algorithm. A setting with no active effect is an exact no-op.
    do {
        let src = source(image(8) { _, _ in SIMD3(1.5, 0.1, 0.05) })
        let plain = render(EditSettings(), src)
        var masked = EditSettings(); masked.sharpenMasking = 80
        var tiny = EditSettings(); tiny.exposure = 0.0001
        check(difference(plain, render(masked, src)) < 0.0001, "imaging: Masking alone changes colours when sharpening is off")
        check(difference(plain, render(tiny, src)) < 0.001, "imaging: a tiny first edit causes a gamut-mapping jump")
    }
    // Active Masking suppresses sharpened flat-field noise while retaining a useful strong-edge response.
    // Use production analysis, not hand-painted residual channels that would duplicate the shader's formula.
    do {
        let width = 2048, height = 32
        let base = image(width, height) { x, y in
            let hash = (x &* 73 &+ y &* 151) % 101
            let noise = (Float(hash) / 100 - 0.5) * 0.008
            return SIMD3(repeating: (x < width / 2 ? Float(0.12) : 0.6) + noise)
        }
        if let src = renderSession.analyse(base, materialize: true) {
            let neutral = render(EditSettings(), src)
            var edits = EditSettings(); edits.sharpness = 100
            let unmasked = render(edits, src)
            edits.sharpenMasking = 100
            let masked = render(edits, src)
            var flatUnmasked: Float = 0, flatMasked: Float = 0, edgeUnmasked: Float = 0, edgeMasked: Float = 0
            var flatCount = 0, edgeCount = 0
            for y in 4..<(height - 4) { for x in 8..<(width - 8) {
                let i = y * width + x
                let a = distance(unmasked[i], neutral[i]), b = distance(masked[i], neutral[i])
                if abs(x - width / 2) > 16 { flatUnmasked += a; flatMasked += b; flatCount += 1 }
                if abs(x - width / 2) <= 3 { edgeUnmasked += a; edgeMasked += b; edgeCount += 1 }
            } }
            flatUnmasked /= Float(flatCount); flatMasked /= Float(flatCount)
            edgeUnmasked /= Float(edgeCount); edgeMasked /= Float(edgeCount)
            print("IMAGING active Sharpen Masking0/100: flat added change \(flatUnmasked)/\(flatMasked), edge \(edgeUnmasked)/\(edgeMasked)")
            check(finite(unmasked) && finite(masked) && flatUnmasked > 0.0001 && flatMasked < flatUnmasked * 0.1,
                  "imaging: active Masking does not suppress sharpened flat noise (\(flatUnmasked), \(flatMasked))")
            check(edgeUnmasked > 0.001 && edgeMasked > edgeUnmasked * 0.15,
                  "imaging: active Masking also disables useful strong-edge sharpening (\(edgeUnmasked), \(edgeMasked))")
        } else { check(false, "imaging: active sharpening fixture analysis failed") }
    }
    // Grading luminance is a photographic tone adjustment too: extreme overlapping zones must not fold a grey ramp.
    do {
        let ramp = source(image(512) { x, _ in SIMD3(repeating: Float(x) / 511 * 0.8) })
        for sign in [-1.0, 1.0] {
            var s = EditSettings(); s.blackAndWhite = true
            s.grading.shadows.lum = sign * 100; s.grading.midtones.lum = -sign * 100
            s.grading.highlights.lum = sign * 100; s.grading.global.lum = sign * 100
            s.grading.blending = 0; s.grading.balance = sign * 100
            let p = render(s, ramp)
            check(finite(p) && increasing(p.prefix(512)), "imaging: grading luminance reverses a grey ramp")
        }
    }
    // Reviewable real-photo sheets through the one current engine.
    // This includes the Sony RAW and all general engine sample JPEGs; image quality still needs phone judgement.
    for file in files.prefix(4) {
        autoreleasepool {
            guard let s = EditSession(url: file) else { return }
            let start = Date()
            guard let fresh = s.makeSource(maxEdge: 1200, materialize: true) else { return }
            let analysisTime = Date().timeIntervalSince(start)
            var tone = EditSettings(); tone.highlights = -100; tone.whites = -100; tone.brightness = 100
            var haze = EditSettings(); haze.dehaze = -10
            var colour = EditSettings(); colour.saturation = 60; colour.vibrance = 30; colour.clarity = 40
            var cells: [(String, CGImage)] = []
            for (name, edits) in [("Original", EditSettings()), ("Tone", tone), ("Dehaze -10", haze), ("Colour / detail", colour)] {
                if let cg = s.renderCGImage(edits, source: fresh) { cells.append((name, cg)) }
            }
            if let comparison = sheet(cells, cell: 400, cols: 2) {
                saveJPEG(comparison, "imaging-compare-\(file.deletingPathExtension().lastPathComponent).jpg")
            }
            print(String(format: "IMAGING analysis %@: %.3f s", file.lastPathComponent, analysisTime))
        }
        context.clearCaches()
    }
    print("Imaging quality synthetic checks complete")
}
