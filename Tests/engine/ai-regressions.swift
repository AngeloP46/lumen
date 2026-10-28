import Foundation
import CoreImage

/// Storage/mask regressions that need no model inference. They exercise the helpers used by the real AI paths.
func runAIRegressionChecks() {
    // A rejected early component must not reappear in the next person's mask through a reused label.
    do {
        let width = 128, height = 128
        var bitmap = [UInt8](repeating: 0, count: width * height)
        for y in 8..<11 { for x in 8..<11 { bitmap[y * width + x] = 255 } }       // 9-pixel rejected crumb
        for y in 60..<80 { for x in 60..<70 { bitmap[y * width + x] = 255 } }    // 200-pixel person
        let people = EditSession.splitPeople(bitmap, width: width, height: height)
        check(people.count == 1, "AI regression: person splitter did not discard the tiny component")
        if let person = people.first {
            // Read the entire left region, independent of the bitmap's top/bottom row convention.
            var left = [UInt8](repeating: 0, count: 30 * height)
            LumenGPU.context.render(person.mask, toBitmap: &left, rowBytes: 30,
                                    bounds: CGRect(x: 0, y: 0, width: 30, height: height), format: .L8, colorSpace: nil)
            check(left.allSatisfy { $0 == 0 }, "AI regression: rejected crumb leaked into an unrelated person's mask")
            check(abs(person.box.minX - 60.0 / 128) < 0.001 && abs(person.area - 200.0 / Double(width * height)) < 0.00001,
                  "AI regression: person bounds/area changed while discarding crumbs")
        }
    }

    // No old/foreign-decoder residual rows may be appended to a new clean. JSON without the key still decodes.
    do {
        var partial = DenoiseStore.Partial(file: "partial.noise", width: 640, height: 480, rows: 224, scale: 1,
                                           hdr: true, model: DenoiseStore.modelVersion, photo: "photo.ARW", decoder: "current")
        func canResume(_ p: DenoiseStore.Partial) -> Bool {
            DenoiseStore.canResume(p, width: 640, height: 480, hdr: true, decoder: "current")
        }
        check(canResume(partial), "AI regression: current-decoder partial cannot resume")
        partial.decoder = "previous"
        check(!canResume(partial), "AI regression: foreign-decoder partial can resume")
        partial.decoder = nil
        check(!canResume(partial), "AI regression: unknown-decoder partial can resume")
        if let data = try? JSONEncoder().encode(partial),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var oldObject = object; oldObject.removeValue(forKey: "decoder")
            if let oldData = try? JSONSerialization.data(withJSONObject: oldObject),
               let old = try? JSONDecoder().decode(DenoiseStore.Partial.self, from: oldData) {
                check(old.decoder == nil && !canResume(old), "AI regression: old paused clean is not safely rejected")
            } else { check(false, "AI regression: old partial JSON does not decode") }
        } else { check(false, "AI regression: partial fixture serialization failed") }
        partial.decoder = "current"; partial.hdr = false
        check(!canResume(partial), "AI regression: other-HDR-mode partial can resume")
        partial.hdr = true; partial.model = "other-model"
        check(!canResume(partial), "AI regression: other-model partial can resume")

        // Tightening partial reuse must not silently change the established completed-cache compatibility policy.
        let previousDirectory = DenoiseStore.directory
        let directory = outDir.appendingPathComponent("ai-cache-\(UUID().uuidString)")
        DenoiseStore.directory = directory
        defer { DenoiseStore.directory = previousDirectory; try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photo = outDir.appendingPathComponent("ai-compat-photo.ARW")
        try? Data(repeating: 0, count: 32).write(to: directory.appendingPathComponent("complete.noise"))
        var info = DenoiseStore.Info(model: DenoiseStore.modelVersion, scale: 1, width: 2, height: 2,
                                     file: "complete.noise", kind: DenoiseStore.noiseKind, decoder: nil)
        func writeInfo() {
            if let data = try? JSONEncoder().encode(info) { try? data.write(to: DenoiseStore.noiseInfoURL(photo)) }
        }
        writeInfo()
        check(DenoiseStore.info(photo, hdr: true, size: CGSize(width: 2, height: 2), decoder: "current") != nil,
              "AI regression: completed legacy cache compatibility changed")
        info.decoder = "foreign"; writeInfo()
        check(DenoiseStore.info(photo, hdr: true, size: CGSize(width: 2, height: 2), decoder: "current") == nil,
              "AI regression: completed foreign-decoder cache accepted")
        info.decoder = "current"; writeInfo()
        check(DenoiseStore.info(photo, hdr: true, size: CGSize(width: 2, height: 2), decoder: "current") != nil,
              "AI regression: completed current-decoder cache rejected")

        // Old previews can contain the former white last row, while the full residual is still correct.
        // Repair must preserve that full file and its model identity, with no ML inference or re-clean.
        var full = [Float16](repeating: 0, count: 10 * 2 * 4)
        for i in stride(from: 3, to: full.count, by: 4) { full[i] = 1 }
        let fullData = full.withUnsafeBytes { Data($0) }
        try? fullData.write(to: directory.appendingPathComponent("repair.noise"))
        let bad = [Float16](repeating: 1, count: 8 * 2 * 4)
        try? bad.withUnsafeBytes { Data($0) }.write(to: directory.appendingPathComponent("bad-preview.noise"))
        info = DenoiseStore.Info(model: DenoiseStore.modelVersion, scale: 1, width: 10, height: 2, file: "repair.noise",
                                 preview: "bad-preview.noise", previewWidth: 8, previewHeight: 2,
                                 kind: DenoiseStore.noiseKind, decoder: "current", previewVersion: nil)
        writeInfo()
        let repaired = DenoiseStore.image(photo, hdr: true, size: CGSize(width: 10, height: 2), maxEdge: 8, decoder: "current")
        check(repaired?.1.previewVersion == DenoiseStore.previewVersion && repaired?.1.file == "repair.noise",
              "AI regression: old noise preview was not upgraded from the full residual")
        if let repaired {
            let e = repaired.0.extent, w = Int(e.width), h = Int(e.height)
            var p = [Float](repeating: 0, count: w * h * 4)
            LumenGPU.context.render(repaired.0, toBitmap: &p, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: nil)
            check(stride(from: 0, to: p.count, by: 4).allSatisfy { p[$0] == 0 && p[$0 + 1] == 0 && p[$0 + 2] == 0 },
                  "AI regression: repaired noise preview contains a white/invalid border")
        }
        check((try? Data(contentsOf: directory.appendingPathComponent("repair.noise"))) == fullData,
              "AI regression: repairing a small preview changed the full-resolution noise")
        // Truncation is no longer treated as an available completed result, and a bad current preview is repaired.
        if var broken = repaired?.1, let preview = broken.preview {
            try? Data([0]).write(to: directory.appendingPathComponent(preview))
            broken.previewVersion = DenoiseStore.previewVersion; info = broken; writeInfo()
            check(DenoiseStore.image(photo, hdr: true, size: CGSize(width: 10, height: 2), maxEdge: 8, decoder: "current") != nil,
                  "AI regression: invalid preview dropped valid full-resolution denoise")
        }
        try? Data([0]).write(to: directory.appendingPathComponent("repair.noise"))
        check(DenoiseStore.info(photo, hdr: true, size: CGSize(width: 10, height: 2), decoder: "current") == nil,
              "AI regression: truncated full-resolution result counts as available")
    }

    // Rounded dimensions must have samples in every last row and column. RGB 1 in a zero noise map produces
    // a black border when the preview subtracts it. Both portrait and landscape cases failed the old scale bins.
    do {
        func shrink<P: ShrinkPixel>(_ type: P.Type, width: Int, height: Int, edge: Int, value: P,
                                    name: String, expected: Float) {
            let url = outDir.appendingPathComponent("row-shrinker-\(name).raw")
            defer { try? FileManager.default.removeItem(at: url) }
            guard let shrinker = RowShrinker<P>(width: width, height: height, maxEdge: edge, url: url) else {
                check(false, "AI regression: couldn't create \(name) row shrinker"); return
            }
            var row = [P](repeating: value, count: width * 4)
            for x in 0..<width { row[x * 4 + 3] = P.opaque }
            row.withUnsafeBufferPointer { p in for _ in 0..<height { shrinker.add(p.baseAddress!) } }
            check(shrinker.finish(), "AI regression: \(name) shrinker did not write every rounded output row")
            guard let data = try? Data(contentsOf: url) else { check(false, "AI regression: \(name) result missing"); return }
            let count = shrinker.smallWidth * shrinker.smallHeight * 4
            check(data.count == count * MemoryLayout<P>.stride, "AI regression: \(name) output byte count wrong")
            guard data.count == count * MemoryLayout<P>.stride else { return }
            let values = data.withUnsafeBytes { raw in Array(raw.bindMemory(to: P.self)) }
            var error: Float = 0
            for i in stride(from: 0, to: count, by: 4) {
                for c in 0..<3 { error = max(error, abs(values[i + c].floatValue - expected)) }
                error = max(error, abs(values[i + 3].floatValue - P.opaque.floatValue))
            }
            check(error == 0, "AI regression: \(name) wrote an empty/incorrect row or column (max error \(error))")
        }
        shrink(Float16.self, width: 10, height: 2, edge: 8, value: 0, name: "noise-landscape", expected: 0)
        shrink(Float16.self, width: 2, height: 10, edge: 8, value: 0, name: "noise-portrait", expected: 0)
        // Same aspect/rounding failure as 6000 x 4000 -> 4096 x 2731, at bounded test size.
        shrink(Float16.self, width: 1500, height: 1000, edge: 1024, value: 0, name: "noise-camera-shape", expected: 0)
        shrink(UInt16.self, width: 10, height: 2, edge: 8, value: 12345, name: "legacy-preview", expected: 12345)
    }
    print("AI storage and mask regression checks complete")
}
