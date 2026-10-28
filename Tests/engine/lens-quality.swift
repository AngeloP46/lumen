import Foundation
import CoreImage

/// Known depth/selection/radiance fixtures for the production Lens Blur graph, independent of model accuracy.
func runLensQualityChecks() {
    guard let file = files.first, let session = EditSession(url: file), let k = LumenKernels.shared else {
        check(false, "lens quality: session/kernels unavailable"); return
    }
    let context = LumenGPU.context
    func image(_ width: Int, _ height: Int, scalar: Bool = false,
               _ pixel: (Int, Int) -> SIMD3<Float>) -> CIImage {
        var data = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let c = pixel(x, y), i = (y * width + x) * 4
            data[i] = c.x; data[i + 1] = c.y; data[i + 2] = c.z
        } }
        return CIImage(bitmapData: data.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf,
                       colorSpace: scalar ? nil : LumenGPU.workingSpace)
    }
    func pixels(_ image: CIImage) -> [SIMD3<Float>] {
        let bounds = image.extent.integral, w = Int(bounds.width), h = Int(bounds.height)
        var data = [Float](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { p in
            context.render(image, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: bounds,
                           format: .RGBAf, colorSpace: nil)
        }
        return (0..<(w * h)).map { SIMD3(data[$0 * 4], data[$0 * 4 + 1], data[$0 * 4 + 2]) }
    }
    func maximumDifference(_ a: CIImage, _ b: CIImage) -> Float {
        let av = pixels(a), bv = pixels(b)
        guard av.count == bv.count, !av.isEmpty else { return .infinity }
        var worst: Float = 0
        for (x, y) in zip(av, bv) {
            worst = max(worst, abs(x.x-y.x), abs(x.y-y.y), abs(x.z-y.z))
        }
        return worst
    }
    func src(_ base: CIImage) -> ImageSource {
        let e = base.extent, log = k.logLum.apply(extent: e, arguments: [base])!
        let l1 = k.pack3.apply(extent: e, arguments: [log, log, log])!
        return ImageSource(base: base, l1: l1, l2: EditSession.constant(0, e), chroma: base,
                           air: SIMD3(repeating: 0.8), darkNorm: 0.2,
                           stats: PixelGrid(width: 1, height: 1, data: [0.18, 0.18, 0.18, 1]))
    }
    let pattern = image(256, 128) { x, _ in SIMD3(repeating: x % 4 < 2 ? 0.6 : 0.08) }
    let point = Pt(x: 0.5, y: 0.5)
    for focus in [0.1, 0.3, 0.6, 0.8] { for width in [0.02, 0.12, 0.3] {
        let source = src(pattern)
        let depth = image(256, 128, scalar: true) { _, _ in SIMD3(repeating: Float(focus)) }
        source.storeMask(EditSession.aiDepth, depth)
        source.storeMask(EditSession.subjectKey(point), nil)
        var edits = EditSettings(); edits.lensBlur.amount = 100
        edits.lensBlur.subjectPoint = point; edits.lensBlur.focusDistance = focus; edits.lensBlur.focusWidth = width
        if let map = session.lensBlurMask(edits, source: source) {
            check(pixels(map).allSatisfy { abs($0.x) < 0.001 },
                  "lens quality: manual focus plane is blurred at \(focus), width \(width)")
        } else { check(false, "lens quality: manual focus map unavailable") }
        check(maximumDifference(pattern, session.applyLensBlur(pattern, settings: edits, source: source)) < 0.002,
              "lens quality: tapping a manual focus plane softens its texture")
    } }

    // A wide focus-width setting can reach the depth endpoint while a genuinely farther plane still exists.
    // Focus .8/width .3 must retain the sharp .8 plane and blur depth1; the old fullFrom guard skipped everything.
    do {
        let source = src(pattern)
        source.storeMask(EditSession.aiDepth, image(256, 128, scalar: true) { x, _ in
            SIMD3(repeating: x < 128 ? 0.8 : 1)
        })
        source.storeMask(EditSession.subjectKey(point), nil)
        var edits = EditSettings(); edits.lensBlur.amount = 100
        edits.lensBlur.focusDistance = 0.8; edits.lensBlur.focusWidth = 0.3; edits.lensBlur.subjectPoint = point
        let original = pixels(pattern), blurred = pixels(session.applyLensBlur(pattern, settings: edits, source: source))
        var nearError: Float = 0, farChange: Float = 0
        var farCount = 0
        for y in 8..<120 { for x in 8..<248 {
            let index = y * 256 + x, delta = abs(original[index].x - blurred[index].x)
            if x < 112 { nearError = max(nearError, delta) }
            if x > 144 { farChange += delta; farCount += 1 }
        } }
        check(nearError < 0.002 && farChange / Float(farCount) > 0.02,
              "lens quality: wide manual focus disables the farther plane (near \(nearError), far \(farChange / Float(farCount)))")
        let initial = session.initialLensRefinement(edits.lensBlur, source: source)
        let automatic = session.lensBlurMask(edits, source: source)
        edits.masks = [initial]; edits.lensBlur.maskID = initial.id
        if let automatic, let refined = session.lensBlurMask(edits, source: source) {
            check(maximumDifference(automatic, refined) < 0.002,
                  "lens quality: wide manual focus loses far blur on Refine entry")
        } else { check(false, "lens quality: wide manual focus refinement unavailable") }
    }

    // The same helper used by Refine in the editor must be identity before painting, including partial subject edges.
    for segmented in [false, true] {
        let source = src(pattern)
        source.storeMask(EditSession.aiDepth, image(256, 128, scalar: true) { x, _ in SIMD3(repeating: Float(x)/255) })
        if segmented {
            source.storeMask(EditSession.aiSubject, image(256, 128, scalar: true) { _, y in
                SIMD3(repeating: y < 40 ? 1 : (y < 64 ? 0.5 : 0))
            })
        } else { source.storeMask(EditSession.aiSubject, nil) }
        var edits = EditSettings(); edits.lensBlur.amount = 100
        guard let automatic = session.lensBlurMask(edits, source: source) else {
            check(false, "lens quality: automatic radius missing"); continue
        }
        let initial = session.initialLensRefinement(edits.lensBlur, source: source)
        edits.masks = [initial]; edits.lensBlur.maskID = initial.id
        guard let linked = session.lensBlurMask(edits, source: source) else {
            check(false, "lens quality: initial linked radius missing"); continue
        }
        let error = maximumDifference(automatic, linked)
        print("LENS refinement entry segmented \(segmented): max map delta \(error)")
        check(error < 0.002, "lens quality: entering Refine changes the existing radius (\(error))")
        var unlinked = edits; unlinked.lensBlur.maskID = nil; unlinked.masks = []
        check(maximumDifference(session.applyLensBlur(pattern, settings: unlinked, source: source),
                                session.applyLensBlur(pattern, settings: edits, source: source)) < 0.004,
              "lens quality: entering Refine changes the rendered picture before painting")
        edits.masks[0].amount = 50
        if let half = session.lensBlurMask(edits, source: source) {
            let before = pixels(linked), after = pixels(half)
            check(zip(before, after).allSatisfy { abs($1.x - $0.x * 0.5) < 0.003 },
                  "lens quality: linked mask opacity no longer scales radius")
        }
        edits.masks[0].amount = 0
        check(maximumDifference(pattern, session.applyLensBlur(pattern, settings: edits, source: source)) < 0.001,
              "lens quality: zero linked mask opacity changes the picture")
        edits.masks[0] = initial
        edits.masks[0].components[0].lumLow = 0.7
        edits.masks[0].components[0].lumLowFeather = 0.05
        if let adjusted = session.lensBlurMask(edits, source: source) {
            check(maximumDifference(linked, adjusted) > 0.05,
                  "lens quality: explicit Near adjustment was cancelled by refinement normalization")
        }
        edits.masks[0] = initial
        edits.masks[0].components[0].lumHigh = 0.8
        edits.masks[0].components[0].lumHighFeather = 0.05
        if let adjusted = session.lensBlurMask(edits, source: source) {
            check(maximumDifference(linked, adjusted) > 0.1,
                  "lens quality: explicit Far adjustment was cancelled by refinement normalization")
        }
        for operation in [MaskOp.add, .subtract] {
            edits.masks[0] = initial
            var brush = MaskComponent.make(.radial, op: operation)
            brush.x0 = 0.7; brush.y0 = 0.75; brush.x1 = 0.08; brush.y1 = 0.12; brush.feather = 50
            edits.masks[0].components.append(brush)
            if let adjusted = session.lensBlurMask(edits, source: source) {
                let baseline = pixels(linked), changed = pixels(adjusted)
                check(zip(baseline, changed).allSatisfy { operation == .add ? $1.x >= $0.x - 0.002 : $1.x <= $0.x + 0.002 },
                      "lens quality: refinement \(operation) moves radius in the wrong direction")
                check(maximumDifference(linked, adjusted) > 0.01,
                      "lens quality: refinement \(operation) has no useful effect")
            }
        }
        let roundTrip = try? JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(edits))
        check(roundTrip == edits, "lens quality: refinement numbers or explicit opacity did not survive saving")
    }

    // Complete develop HDR path: colour lights must spread actual radiance, not separately averaged gain.
    guard k.hdrBlurGain != nil, k.applyRGBGain != nil else { check(false, "lens quality: HDR blur kernels missing"); return }
    let lights = image(256, 128) { x, y in
        if abs(x-80) < 3 && abs(y-64) < 3 { return SIMD3(8, 3, 1) }
        if abs(x-170) < 3 && abs(y-64) < 3 { return SIMD3(1, 3, 8) }
        return SIMD3(repeating: 0.02)
    }
    let source = src(lights)
    source.storeMask(EditSession.aiDepth, image(256, 128, scalar: true) { _, _ in SIMD3(repeating: 1) })
    source.storeMask(EditSession.aiSubject, nil)
    for amount in [23.0, 100] { for quality in [EditSession.LensQuality.full, .preview] {
        var edits = EditSettings(); edits.hdr = true; edits.hdrStops = 2; edits.lensBlur.amount = amount
        let unblurredHDR = session.develop(edits, source: source, geometry: false, hdrWeight: 1, lens: .off)
        let reference = session.applyLensBlur(unblurredHDR, settings: edits, source: source, scale: quality == .preview ? 0.5 : 1)
        let actual = session.develop(edits, source: source, geometry: false, hdrWeight: 1, lens: quality)
        let error = maximumDifference(actual, reference)
        print("LENS HDR colour lights \(amount), preview \(quality == .preview): max radiance error \(error)")
        check(error < 0.015, "lens quality: full HDR graph loses coloured light radiance (\(error))")
        var monochrome = edits; monochrome.blackAndWhite = true
        let bw = pixels(session.develop(monochrome, source: source, geometry: false, hdrWeight: 1, lens: quality))
        check(bw.allSatisfy { abs($0.x - $0.y) < 0.003 && abs($0.x - $0.z) < 0.003 },
              "lens quality: RGB blur gains reintroduce colour into black and white")
        for weight in [0.0, 0.5, 1] {
            var graded = edits; graded.saturation = 25; graded.grading.global.sat = 30
            let result = pixels(session.develop(graded, source: source, geometry: false, hdrWeight: weight, lens: quality))
            check(result.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && min($0.x, $0.y, $0.z) >= -0.001 },
                  "lens quality: graded HDR blur produces invalid channel gains")
        }
        if let cg = context.createCGImage(actual, from: actual.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace) {
            saveJPEG(cg, "lens-quality-hdr-\(Int(amount))-\(quality == .preview ? "preview" : "full").jpg")
        }
    } }
    // Uniform HDR and true black must remain unchanged and finite, including the division's dark denominator.
    for value in [Float(0), 0.02, 1, 4] {
        let base = image(128, 64) { _, _ in SIMD3(repeating: value) }, flat = src(base)
        flat.storeMask(EditSession.aiDepth, image(128, 64, scalar: true) { _, _ in SIMD3(repeating: 1) })
        flat.storeMask(EditSession.aiSubject, nil)
        var edits = EditSettings(); edits.hdr = true; edits.lensBlur.amount = 100
        let original = session.develop(edits, source: flat, geometry: false, hdrWeight: 1, lens: .off)
        let blurred = session.develop(edits, source: flat, geometry: false, hdrWeight: 1)
        check(maximumDifference(original, blurred) < 0.01,
              "lens quality: uniform HDR \(value) changes under blur")
        check(pixels(blurred).allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite },
              "lens quality: uniform HDR \(value) has invalid gain ratios")
        edits.lensBlur.amount = 0
        check(maximumDifference(original, session.develop(edits, source: flat, geometry: false, hdrWeight: 1)) < 0.001,
              "lens quality: explicit zero HDR blur changes pixels")
    }
}
