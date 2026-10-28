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
