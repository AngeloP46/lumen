import Foundation
import Darwin
import CoreImage
import CoreImage.CIFilterBuiltins

/// Clarity must visibly change mid-scale structure, rather than merely render finite values at its endpoints.
/// Exercise the actual analysis and Metal graph on known frequency bands, flat fields, hard edges and real photos.
func runClarityQualityChecks() {
    guard let anchor = files.first, let session = EditSession(url: anchor) else {
        check(false, "clarity: no sample session available"); return
    }
    let context = LumenGPU.context
    func image(_ width: Int, _ height: Int = 96, _ pixel: (Int, Int) -> Float) -> CIImage {
        var data = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let value = pixel(x, y), i = (y * width + x) * 4
            data[i] = value; data[i + 1] = value; data[i + 2] = value
        } }
        return CIImage(bitmapData: data.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf,
                       colorSpace: LumenGPU.workingSpace)
    }
    func row(_ img: CIImage) -> [Float] {
        let width = Int(img.extent.width), y = floor(img.extent.midY)
        var data = [Float](repeating: 0, count: width * 4)
        data.withUnsafeMutableBytes { p in
            context.render(img, toBitmap: p.baseAddress!, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: y, width: CGFloat(width), height: 1), format: .RGBAf, colorSpace: nil)
        }
        var luminance = [Float](repeating: 0, count: width)
        for x in 0..<width {
            let r: Float = 0.22897 * data[x * 4]
            let g: Float = 0.69174 * data[x * 4 + 1]
            let b: Float = 0.07929 * data[x * 4 + 2]
            luminance[x] = r + g + b
        }
        return luminance
    }
    func developed(_ source: ImageSource, _ amount: Double) -> CIImage {
        var edits = EditSettings(); edits.clarity = amount
        return session.develop(edits, source: source, geometry: false, lens: .off)
    }
    func difference(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Float(a.count)
    }
    func amplitude(_ values: [Float], period: Double, range: Range<Int>) -> Double {
        var sine = 0.0, cosine = 0.0
        for x in range {
            let value = log2(Double(max(values[x], 1e-6)) / 0.18), angle = 2 * Double.pi * Double(x) / period
            sine += value * sin(angle); cosine += value * cos(angle)
        }
        return 2 * hypot(sine, cosine) / Double(range.count)
    }
    func finite(_ values: [Float]) -> Bool { !values.isEmpty && values.allSatisfy { $0.isFinite && $0 >= -0.001 } }

    // Mid-scale waves and fine grain occupy different frequency bands. Boost/soften the former visibly,
    // keep the latter close to its original amplitude, and preserve that behaviour when analysis is scaled.
    for width in [1280, 2560] {
        autoreleasepool {
            let scale = Double(width) / 1280, period = 64 * scale, finePeriod = 4 * scale
            let fixture = image(width) { x, _ in
                let xx = Double(x), mid = 0.35 * sin(2 * .pi * xx / period), fine = 0.06 * sin(2 * .pi * xx / finePeriod)
                return Float(0.18 * exp2(mid + fine))
            }
            guard let src = session.analyse(fixture, materialize: true) else {
                check(false, "clarity: multiscale analysis unavailable at \(width)"); return
            }
            let rows = [-100.0, 0, 100].map { row(developed(src, $0)) }
            let region = (width / 10)..<(width - width / 10)
            let middle = rows.map { amplitude($0, period: period, range: region) }
            let fine = rows.map { amplitude($0, period: finePeriod, range: region) }
            print(String(format: "CLARITY %dpx mid EV -100/0/+100 %.4f / %.4f / %.4f; fine %.4f / %.4f / %.4f",
                         width, middle[0], middle[1], middle[2], fine[0], fine[1], fine[2]))
            check(rows.allSatisfy(finite), "clarity: multiscale endpoints produced invalid pixels at \(width)")
            check(middle[2] > middle[1] * 1.90, "clarity: +100 barely changes mid-scale contrast at \(width) (\(middle))")
            check(middle[0] < middle[1] * 0.45 && middle[0] > middle[1] * 0.05,
                  "clarity: -100 does not soften structure without erasing/reversing it at \(width) (\(middle))")
            for direction in [-1.0, 1] {
                let near = difference(row(developed(src, direction * 10)), rows[1])
                let middleTravel = difference(row(developed(src, direction * 50)), rows[1])
                check(near < middleTravel * 0.15, "clarity: travel near zero is not finer than midrange at \(width)")
            }
            check(abs(fine[2] / fine[1] - 1) < 0.12 && abs(fine[0] / fine[1] - 1) < 0.12,
                  "clarity: endpoint strengths also change fine grain too much at \(width) (\(fine))")
            if width == 1280 {
                let cells = zip(["Clarity -100", "Clarity 0", "Clarity +100"], [-100.0, 0, 100]).compactMap { name, amount -> (String, CGImage)? in
                    let img = developed(src, amount)
                    guard let cg = context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace) else { return nil }
                    return (name, cg)
                }
                if let comparison = sheet(cells, cell: 640, cols: 1) { saveJPEG(comparison, "clarity-multiscale.jpg") }
            }
        }
        context.clearCaches()
    }

    // Real scenes contain many bright/dark boundaries. The former expanded maximum vetoed every surface
    // between them, even where medium-scale texture was far from the actual edges (owner's car screenshots).
    do {
        let width = 1280
        let fixture = image(width, 192) { x, _ in
            let cell = x % 96
            if cell < 8 { return 0.02 }
            if cell < 16 { return 0.8 }
            return Float(0.18 * exp2(0.35 * sin(2 * .pi * Double(x) / 64)))
        }
        if let src = session.analyse(fixture, materialize: true) {
            let rows = [-100.0, 0, 100].map { row(developed(src, $0)) }
            let indices = (96..<(width - 96)).filter { (32..<80).contains($0 % 96) }
            let values = rows.map { r in indices.map { log2(Double(max(r[$0], 1e-6)) / 0.18) } }
            func contrast(_ r: [Double]) -> Double {
                let mean = r.reduce(0, +) / Double(r.count)
                return sqrt(r.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(r.count))
            }
            let strength = values.map(contrast)
            print("CLARITY busy scene medium contrast -100/0/+100: \(strength)")
            check(strength[2] > strength[1] * 1.5 && strength[0] < strength[1] * 0.65,
                  "clarity: nearby hard edges disable contrast across the surrounding scene (\(strength))")
            // Scope audit: poisoning the Clarity-only channel must not alter any other adjustment family.
            let poisoned = src.l2.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 1, y: 0, z: 0, w: 0)])
            let alternate = ImageSource(base: src.base, l1: src.l1, l2: poisoned, chroma: src.chroma,
                                        air: src.air, darkNorm: src.darkNorm, stats: src.stats)
            var light = EditSettings(); light.exposure = 0.5; light.brightness = 25; light.contrast = 30
            light.highlights = -30; light.shadows = 35; light.whites = 15; light.blacks = -10
            var colour = EditSettings(); colour.temperature = 15; colour.tint = -10; colour.saturation = 20; colour.vibrance = 25
            colour.hsl.bands[2].hue = 15; colour.grading.shadows = GradeZone(hue: 220, sat: 20, lum: -5)
            var detail = EditSettings(); detail.texture = 30; detail.sharpness = 40; detail.noiseReduction = 25; detail.colorNoise = 30
            var haze = EditSettings(); haze.dehaze = 35
            var local = EditSettings(); var mask = Mask.make(.linear)
            mask.adjust.exposure = 0.5; mask.adjust.brightness = 20; mask.adjust.texture = -25; mask.adjust.noise = 15
            local.masks = [mask]
            for (name, recipe) in [("light", light), ("colour/grade", colour), ("texture/sharpen/noise", detail), ("dehaze", haze), ("local non-Clarity", local)] {
                for hdrWeight in [0.0, 1] {
                    var edits = recipe; edits.hdr = hdrWeight > 0
                    let a = row(session.develop(edits, source: src, geometry: false, hdrWeight: hdrWeight, lens: .off))
                    let b = row(session.develop(edits, source: alternate, geometry: false, hdrWeight: hdrWeight, lens: .off))
                    check(finite(a) && difference(a, b) < 0.00001,
                          "clarity scope: edge channel leaks into \(name), HDR weight \(hdrWeight)")
                }
            }
            for amount in [-100.0, 100] {
                var edits = EditSettings(); edits.clarity = amount; edits.hdr = true
                let hdr = session.develop(edits, source: src, geometry: false, hdrWeight: 1, lens: .off)
                check(finite(row(hdr)), "clarity: busy scene HDR result invalid at \(amount)")
            }
        } else { check(false, "clarity: busy-scene analysis unavailable") }
    }

    // Clarity is local contrast: a perfectly flat tone must remain flat, and a strong isolated boundary
    // must not acquire broad bright/dark bands. This catches both signal inversion and edge-filter mismatch.
    for isStep in [false, true] {
        let fixture = image(1280) { x, _ in isStep ? (x < 640 ? 0.03 : 0.65) : 0.18 }
        guard let src = session.analyse(fixture, materialize: true) else {
            check(false, "clarity: flat/step analysis unavailable"); continue
        }
        // L2.r must contain a positive physical log range, not a signed/reversed blend result.
        var packed = [Float](repeating: 0, count: 4)
        packed.withUnsafeMutableBytes { p in
            context.render(src.l2, toBitmap: p.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: 640, y: 48, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        }
        let expectedRange = isStep ? Float(log2(0.65 / 0.03)) : 0
        let measuredRange = packed[0] * 16
        // Lanczos can overshoot a discontinuity in the small guide; that must strengthen protection,
        // not make this assertion depend on the resampler's exact boundary phase.
        let validRange = isStep ? measuredRange >= expectedRange - 0.15 && measuredRange <= 16.01 : abs(measuredRange) < 0.02
        check(packed[0].isFinite && validRange,
              "clarity: local edge range is wrong (\(packed[0] * 16) EV, expected \(expectedRange))")
        let neutral = row(developed(src, 0))
        for amount in [-100.0, 100] {
            let result = row(developed(src, amount))
            let largest = zip(neutral, result).map { abs($0 - $1) }.max() ?? .infinity
            check(finite(result) && largest < (isStep ? 0.012 : 0.001),
                  "clarity: \(isStep ? "hard boundary halo" : "flat field changes") at \(amount) (max \(largest))")
        }
    }

    // Reviewable before/after material on every fetched photo, including the Sony RAW. Whole-image and
    // centre detail sheets let reviewers judge visible strength, natural texture and edge behaviour.
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        autoreleasepool {
            guard let photo = EditSession(url: file), let src = photo.makeSource(maxEdge: 1600, materialize: true) else {
                check(false, "clarity: sample \(file.lastPathComponent) cannot be analysed"); return
            }
            var cells: [(String, CGImage)] = [], details: [(String, CGImage)] = [], renders: [[Float]] = []
            for amount in [-100.0, 0, 100] {
                var edits = EditSettings(); edits.clarity = amount
                let img = photo.develop(edits, source: src, geometry: false, lens: .off)
                if file.lastPathComponent == "clarity-car-proxy.png" {
                    // The owner's screenshot crop is a scene proxy, not the untouched RAW. Its windscreen
                    // was exactly unchanged in the reported +/- endpoints. Test that region explicitly.
                    func region(_ image: CIImage) -> [Float] {
                        let rect = CGRect(x: 20, y: image.extent.height - 210, width: 350, height: 180)
                        let crop = EditSession.normalized(image.cropped(to: rect))
                        let small = EditSession.downscaled(crop, 64 / max(crop.extent.width, crop.extent.height))
                        let width = Int(small.extent.width.rounded()), height = Int(small.extent.height.rounded())
                        var values = [Float](repeating: 0, count: width * height * 4)
                        context.render(small, toBitmap: &values, rowBytes: width * 16,
                                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: nil)
                        return (0..<(width * height)).map { values[$0 * 4] + values[$0 * 4 + 1] + values[$0 * 4 + 2] }
                    }
                    let neutral = photo.develop(EditSettings(), source: src, geometry: false, lens: .off)
                    if amount != 0 {
                        let delta = difference(region(img), region(neutral)) / 3
                        print("CLARITY owner car windscreen mean change at \(amount): \(delta)")
                        check(delta > 0.003, "clarity: the owner's windscreen remains effectively excluded at \(amount) (\(delta))")
                    }
                }
                renders.append(row(img))
                if let cg = context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace) {
                    cells.append(("Clarity \(Int(amount))", cg))
                }
                let e = img.extent, side = min(e.width, e.height) * 0.55
                let crop = CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side).integral
                if let cg = context.createCGImage(img, from: crop, format: .RGBA8, colorSpace: LumenGPU.displaySpace) {
                    details.append(("Clarity \(Int(amount)) · detail", cg))
                }
            }
            let stem = file.deletingPathExtension().lastPathComponent
            if let comparison = sheet(cells, cell: 560, cols: 3) { saveJPEG(comparison, "clarity-\(stem).jpg") }
            if let comparison = sheet(details, cell: 560, cols: 3) { saveJPEG(comparison, "clarity-detail-\(stem).jpg") }
            check(renders.count == 3 && renders.allSatisfy(finite), "clarity: invalid real-photo result for \(stem)")
            if renders.count == 3 {
                print(String(format: "CLARITY %@ mean row change -100 %.6f / +100 %.6f", stem,
                             difference(renders[0], renders[1]), difference(renders[2], renders[1])))
            }
        }
        context.clearCaches()
    }
    print("Clarity frequency, flat/edge and real-photo checks complete")
}

/// The phone regression was a batch, not one decode: repeated 24 MP RAW thumbnails with Lens Blur masks.
/// Mac residency differs from iOS; enforce a settled baseline rather than claiming a phone memory limit.
func runThumbnailBatchChecks() {
    guard let raw = files.first(where: { $0.pathExtension.lowercased() == "arw" }) else {
        check(false, "thumbnail batch: RAW sample unavailable"); return
    }
    func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
    var readings: [Int] = []
    for index in 0..<32 {
        let rendered = autoreleasepool { () -> Bool in
            guard let session = EditSession(url: raw) else { return false }
            var settings = EditSettings(); settings.lensBlur.amount = 12; settings.lensBlur.activated = true
            guard let cg = session.renderCGImage(settings, maxEdge: 640) else { return false }
            saveJPEG(cg, "thumbnail-batch-\(index).jpg")
            return FileManager.default.fileExists(atPath: outDir.appendingPathComponent("thumbnail-batch-\(index).jpg").path)
        }
        autoreleasepool {
            LumenGPU.context.clearCaches()
            EditSession.releaseMaskModels()
        }
        let memory = footprint(); readings.append(memory)
        print("THUMBNAIL BATCH \(index + 1)/32: \(memory) MB after cleanup")
        check(rendered, "thumbnail batch: image \(index + 1) was not persisted")
    }
    let baseline = readings[4..<12].max() ?? -1
    let end = readings.suffix(8).max() ?? -1
    check(baseline >= 0 && end >= 0 && end - baseline < 256,
          "thumbnail batch: retained memory climbs across the batch (\(baseline) -> \(end) MB)")
}
