import Foundation
import CoreImage

/// Failure/empty/result state and export requirements, using actual mask/export helpers without model inference.
func runMaskRegressionChecks() {
    let directory = outDir.appendingPathComponent("mask-state-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photo = directory.appendingPathComponent("photo.png")
        let extent = CGRect(x: 0, y: 0, width: 32, height: 24)
        let base = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18)).cropped(to: extent)
        try LumenGPU.context.writePNGRepresentation(of: base, to: photo, format: .RGBA8,
                                                    colorSpace: LumenGPU.displaySpace)
        guard let session = EditSession(url: photo, expandHDR: false) else {
            check(false, "mask regression: fixture cannot be opened"); return
        }
        func source(_ scale: CGFloat = 1) -> ImageSource {
            let ext = extent.applying(CGAffineTransform(scaleX: scale, y: scale))
            return ImageSource(base: EditSession.constant(0.18, ext), l1: EditSession.constant(0.5, ext),
                               l2: EditSession.constant(0, ext), chroma: EditSession.constant(0.18, ext),
                               air: SIMD3<Float>(repeating: 0.18), darkNorm: 0.18,
                               stats: PixelGrid(width: 1, height: 1, data: [0.18, 0.18, 0.18, 1]))
        }
        func recipe(_ kind: MaskKind) -> EditSettings {
            var s = EditSettings(); s.hdr = false
            var mask = Mask.make(kind); mask.adjust.exposure = 1
            if kind == .landscape { mask.components[0].scene = [ScenePart.water.rawValue] }
            s.masks = [mask]
            return s
        }
        let landscape = EditSession.sceneKey([ScenePart.water.rawValue])
        let ordinaryKeys = [EditSession.aiSubject, EditSession.aiSky, EditSession.aiPeople,
                            EditSession.aiDepth, EditSession.aiScene, landscape]
        func seeded() -> ImageSource {
            let s = source()
            for key in ordinaryKeys { s.storeMask(key, nil) }
            return s
        }
        func mean(_ image: CIImage) -> Float {
            let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
            var pixels = [Float](repeating: 0, count: 4)
            LumenGPU.context.render(average, toBitmap: &pixels, rowBytes: 16,
                                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return pixels[0]
        }

        // Same successful-empty input and same request failure must produce different Background selections.
        let empty = seeded(), failed = seeded()
        failed.noteFailure(EditSession.aiSubject)
        let background = MaskComponent.make(.background)
        check(abs(mean(session.componentImage(background, source: empty, gain: 1)) - 1) < 0.001,
              "mask regression: successful no-subject detection no longer selects the whole background")
        check(abs(mean(session.componentImage(background, source: failed, gain: 1))) < 0.001,
              "mask regression: failed Subject changes Background into the whole photo")
        for kind in [MaskKind.subject, .background, .sky, .people] {
            for whole in [false, true] {
                var mask = Mask.make(kind)
                if whole { mask.invert = true } else { mask.components[0].invert = true }
                let unavailable = seeded()
                if let key = EditSession.automaticMaskKey(mask.components[0]) { unavailable.noteFailure(key) }
                check(session.maskImage(mask, source: unavailable, gain: 1) == nil,
                      "mask regression: failed \(kind) becomes a white preview via \(whole ? "mask" : "component") inversion")
                if let legitimate = session.maskImage(mask, source: empty, gain: 1) {
                    let expected: Float = kind == .background ? 0 : 1
                    check(abs(mean(legitimate) - expected) < 0.001,
                          "mask regression: successful empty \(kind) loses its legitimate inversion")
                } else { check(false, "mask regression: successful empty \(kind) is incorrectly suppressed") }
            }
        }

        for (kind, key) in [(MaskKind.subject, EditSession.aiSubject), (.background, EditSession.aiSubject),
                            (.sky, EditSession.aiSky), (.people, EditSession.aiPeople), (.depth, EditSession.aiDepth),
                            (.landscape, landscape)] {
            let edits = recipe(kind), noResult = seeded(), unavailable = seeded()
            unavailable.noteFailure(key)
            let expectedEmpty: EditSession.ExportFailure? = kind == .depth ? .automaticMaskUnavailable : nil
            check(session.prepareExportMasks(edits, source: noResult) == expectedEmpty,
                  "mask regression: \(kind == .depth ? "missing depth is accepted" : "valid empty detection blocks export")")
            check(session.prepareExportMasks(edits, source: unavailable) == .automaticMaskUnavailable,
                  "mask regression: failed \(kind) silently loses requested edits on export")
        }
        var pointed = recipe(.subject)
        let point = Pt(x: 0.2, y: 0.4), pointKey = EditSession.subjectKey(point)
        pointed.masks[0].components[0].subjectPoint = point
        let pointFailure = seeded(); pointFailure.storeMask(pointKey, nil); pointFailure.noteFailure(pointKey)
        check(session.prepareExportMasks(pointed, source: pointFailure) == .automaticMaskUnavailable,
              "mask regression: failed selected Subject instance silently exports")

        // Failure of optional analysis must not reject a successful fallback result, or unrelated/disabled edits.
        let skyFallback = seeded(); skyFallback.noteFailure(EditSession.aiScene)
        skyFallback.storeMask(EditSession.aiSky, EditSession.constant(0.7, extent))
        check(session.prepareExportMasks(recipe(.sky), source: skyFallback) == nil,
              "mask regression: optional Scene failure rejects a valid Sky fallback")
        check(session.maskImage(recipe(.sky).masks[0], source: skyFallback, gain: 1) != nil,
              "mask regression: optional Scene failure suppresses valid Sky in the preview")
        var inactive = recipe(.people); inactive.setOn(.masks, false)
        let untouched = source()
        check(session.prepareExportMasks(inactive, source: untouched) == nil && untouched.snapshotMasks().tried.isEmpty,
              "mask regression: disabled Masks triggers inference or blocks export")
        inactive = recipe(.people); inactive.masks[0].amount = 0
        check(session.prepareExportMasks(inactive, source: untouched) == nil && untouched.snapshotMasks().tried.isEmpty,
              "mask regression: zero-opacity mask triggers inference or blocks export")
        inactive = recipe(.people); inactive.masks[0].adjust = LocalAdjust()
        check(session.prepareExportMasks(inactive, source: untouched) == nil && untouched.snapshotMasks().tried.isEmpty,
              "mask regression: neutral mask triggers inference or blocks export")
        inactive = recipe(.people); inactive.masks[0].components[0].amount = 0
        check(session.prepareExportMasks(inactive, source: untouched) == nil && untouched.snapshotMasks().tried.isEmpty,
              "mask regression: zero-opacity component triggers inference or blocks export")
        inactive = recipe(.landscape); inactive.masks[0].components[0].scene = []
        check(session.prepareExportMasks(inactive, source: untouched) == nil && untouched.snapshotMasks().tried.isEmpty,
              "mask regression: empty Landscape selection runs unnecessary Scene analysis")
        var brushBlur = EditSettings(); brushBlur.lensBlur.amount = 20
        let manual = Mask.make(.brush); brushBlur.masks = [manual]; brushBlur.lensBlur.maskID = manual.id
        check(session.prepareExportMasks(brushBlur, source: untouched) == nil && untouched.snapshotMasks().tried.isEmpty,
              "mask regression: brush-only linked Lens Blur runs unnecessary depth analysis")

        // The real small-source export hand-off, plus the same restore helper used by detail and undo memos.
        for failure in [false, true] {
            let preview = seeded(), full = source(2)
            if failure { preview.noteFailure(EditSession.aiSubject) }
            let result = session.prepareExportMasks(recipe(.background), source: full, preview: preview)
            check(result == (failure ? .automaticMaskUnavailable : nil),
                  "mask regression: export transfer confuses failed and empty Subject (failed \(failure))")
            check(full.failures.contains(EditSession.aiSubject) == failure,
                  "mask regression: export transfer loses failure identity")
            let restored = source(); restored.restoreMasks(full.snapshotMasks())
            check(restored.hasTried(EditSession.aiSubject) && restored.failures == full.failures,
                  "mask regression: detail/memo restoration loses attempted/error state")
            check(abs(mean(session.componentImage(background, source: full, gain: 1)) - (failure ? 0 : 1)) < 0.001,
                  "mask regression: transferred Background has the wrong coverage")
        }
        func rgba(_ image: CIImage, inset: CGFloat = 0) -> (mean: SIMD4<Float>, minAlpha: Float) {
            let bounds = image.extent.insetBy(dx: inset, dy: inset).integral
            let width = Int(bounds.width), height = Int(bounds.height)
            var values = [Float](repeating: 0, count: width * height * 4)
            values.withUnsafeMutableBytes { p in
                LumenGPU.context.render(image, toBitmap: p.baseAddress!, rowBytes: width * 16,
                                        bounds: bounds, format: .RGBAf, colorSpace: nil)
            }
            var sum = SIMD4<Float>.zero, minAlpha: Float = 1
            for i in 0..<(width * height) {
                sum += SIMD4(values[i * 4], values[i * 4 + 1], values[i * 4 + 2], values[i * 4 + 3])
                minAlpha = min(minAlpha, values[i * 4 + 3])
            }
            return (sum / Float(width * height), minAlpha)
        }
        // CIColor carries its own colour space, so its 0.7 may be converted rather than treated as a scalar. Compare its
        // native result with the transfer, and separately use raw scalar data for the exact 0.3 assertion.
        var scalar = [Float](repeating: 0.7, count: 32 * 24 * 4)
        for i in stride(from: 3, to: scalar.count, by: 4) { scalar[i] = 1 }
        let rawSubject = CIImage(bitmapData: scalar.withUnsafeBytes { Data($0) }, bytesPerRow: 32 * 16,
                                 size: extent.size, format: .RGBAf, colorSpace: nil)
        for (name, subject) in [("CIColor", EditSession.constant(0.7, extent)), ("raw scalar", rawSubject)] {
            let ready = seeded(), restored = source(2)
            ready.storeMask(EditSession.aiSubject, subject)
            restored.noteFailure(EditSession.aiSubject)
            restored.restoreMasks(ready.snapshotMasks(), scaleX: 2, scaleY: 2)
            check(restored.failures.isEmpty && restored.cachedMask(EditSession.aiSubject)?.extent == restored.extent,
                  "mask regression: ready replacement retains stale failure or wrong scaled extent")
            let native = rgba(session.componentImage(background, source: ready, gain: 1))
            let transferred = session.componentImage(background, source: restored, gain: 1)
            let full = rgba(transferred), interior = rgba(transferred, inset: 2)
            let maskPixels = rgba(restored.cachedMask(EditSession.aiSubject)!)
            let old = source(2)
            old.storeMask(EditSession.aiSubject, subject.transformed(by: CGAffineTransform(scaleX: 2, y: 2)))
            let unclamped = rgba(session.componentImage(background, source: old, gain: 1))
            print("MASK transfer \(name): native RGBA \(native.mean), scaled \(full.mean), interior \(interior.mean), unclamped \(unclamped.mean); subject min alpha \(maskPixels.minAlpha), background min alpha \(full.minAlpha)")
            check(abs(full.mean.x - native.mean.x) < 0.003 && abs(interior.mean.x - native.mean.x) < 0.003,
                  "mask regression: \(name) Background transfer changes native \(native.mean) to full \(full.mean), interior \(interior.mean)")
            check(native.minAlpha > 0.999 && full.minAlpha > 0.999 && maskPixels.minAlpha > 0.999,
                  "mask regression: \(name) transfer weakens finite mask opacity (\(native.minAlpha), \(full.minAlpha), \(maskPixels.minAlpha))")
            if name == "raw scalar" {
                check(abs(native.mean.x - 0.3) < 0.003 && abs(full.mean.x - 0.3) < 0.003,
                      "mask regression: unmanaged Subject 0.7 fails exact Background 0.3 (native \(native.mean), scaled \(full.mean))")
            }
        }

        // Scene errors propagate to derived parts, so Try again invalidates the nil Landscape cache too.
        let retry = source()
        retry.noteFailure(EditSession.aiScene); retry.storeMask(EditSession.aiScene, nil)
        retry.storeMask(EditSession.aiSky, nil)
        check(session.prepareExportMasks(recipe(.landscape), source: retry) == .automaticMaskUnavailable
              && retry.failures.contains(landscape), "mask regression: derived Landscape hides Scene failure")
        retry.clearFailures()
        check(!retry.hasTried(EditSession.aiScene) && !retry.hasTried(landscape),
              "mask regression: retry keeps failed Landscape cached as a successful empty result")
        guard let water = ScenePart.water.classes.first else {
            check(false, "mask regression: water class missing"); return
        }
        retry.storeScene(SceneField(width: 2, height: 2, labels: [Int32](repeating: water, count: 4), found: [.water]))
        retry.storeMask(EditSession.aiScene, nil)
        check(session.prepareExportMasks(recipe(.landscape), source: retry) == nil && retry.cachedMask(landscape) != nil,
              "mask regression: successful Scene retry never rebuilds Landscape")
        check(!session.prepareAutoMasks(recipe(.landscape), source: retry),
              "mask regression: successful/empty outcomes run repeatedly")

        // Public export also reaches the failure gate. Missing compiled models are deterministic, with no inference.
        let oldDepth = EditSession.depthModelURL, oldScene = EditSession.sceneModelURL
        EditSession.releaseMaskModels(); EditSession.depthModelURL = nil; EditSession.sceneModelURL = nil
        defer {
            EditSession.releaseMaskModels(); EditSession.depthModelURL = oldDepth; EditSession.sceneModelURL = oldScene
        }
        for kind in [MaskKind.depth, .landscape] {
            if case .failed(.automaticMaskUnavailable) = session.renderDataOutcome(recipe(kind), format: .jpeg,
                                                                                 quality: 0.9, includeHDR: false) {
                check(true, "")
            } else { check(false, "mask regression: public export omits unavailable \(kind) adjustments") }
        }
        var blur = EditSettings(); blur.hdr = false; blur.lensBlur.amount = 20
        let missingDepth = seeded(); missingDepth.noteFailure(EditSession.aiDepth)
        check(session.prepareExportMasks(blur, source: missingDepth) == .depthUnavailable,
              "mask regression: Lens Blur loses its specific depth failure/without-blur option")

        // The memory barrier materializes signed guided-filter coefficients. Compare the production path with
        // the former lazy graph on both covariance signs, keeping its exact window, epsilon and final quantizer.
        if let kernels = LumenKernels.shared, let pack = kernels.gfPack, let coef = kernels.gfCoef, let apply = kernels.gfApply {
            let width = 640, height = 64
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            func field(_ inverse: Bool, guide: Bool) -> CIImage {
                var values = [Float](repeating: 1, count: width * height * 4)
                for y in 0..<height { for x in 0..<width {
                    let ramp = Float(x) / Float(width - 1)
                    let value = 0.05 + ramp * 0.65 + (x >= width / 2 ? Float(0.2) : 0)
                    let scalar = inverse ? 1 - value : value
                    let i = (y * width + x) * 4
                    values[i] = scalar; values[i + 1] = scalar; values[i + 2] = scalar
                } }
                return CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                               size: frame.size, format: .RGBAf, colorSpace: guide ? LumenGPU.workingSpace : nil)
            }
            func red(_ image: CIImage) -> [Float] {
                var values = [Float](repeating: 0, count: width * height * 4)
                values.withUnsafeMutableBytes { p in
                    LumenGPU.context.render(image, toBitmap: p.baseAddress!, rowBytes: width * 16,
                                            bounds: frame, format: .RGBAf, colorSpace: nil)
                }
                return stride(from: 0, to: values.count, by: 4).map { values[$0] }
            }
            let guide = field(false, guide: true)
            let testSource = ImageSource(base: guide, l1: EditSession.constant(0, frame), l2: EditSession.constant(0, frame),
                chroma: guide, air: SIMD3(repeating: 0.5), darkNorm: 0.2,
                stats: PixelGrid(width: 1, height: 1, data: [0.2, 0.2, 0.2, 1]))
            for inverse in [false, true] { for depth in [false, true] {
                let mask = field(inverse, guide: false)
                let radius = max(4, testSource.longEdge * (depth ? 0.014 : 0.008))
                func box(_ image: CIImage) -> CIImage {
                    image.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: frame)
                }
                guard let packed = pack.apply(extent: frame, arguments: [guide, mask, CIVector(x: 0, y: 0, z: 0, w: 0)]),
                      let packedIP = pack.apply(extent: frame, arguments: [guide, mask, CIVector(x: 1, y: 0, z: 0, w: 0)]),
                      let coefficients = coef.apply(extent: frame, arguments: [box(packed), box(packedIP),
                                                                                            CIVector(x: depth ? 0.004 : 0.0015, y: 0, z: 0, w: 0)]),
                      let reference = apply.apply(extent: frame, arguments: [box(coefficients), guide,
                          depth ? CIVector(x: 0, y: 1, z: 0, w: 0) : CIVector(x: 0.12, y: 1 / 0.76, z: 0, w: 0)]),
                      let expected = EditSession.materializedMask(reference),
                      let actual = session.refined(mask, source: testSource, depth: depth) else {
                    check(false, "mask regression: coefficient barrier fixture could not render"); continue
                }
                let signed = red(coefficients)
                check(inverse ? (signed.min() ?? 0) < -0.01 : (signed.max() ?? 0) > 0.01,
                      "mask regression: coefficient fixture lacks the intended covariance sign")
                let before = red(expected), after = red(actual)
                var worst: Float = 0, squared: Float = 0
                for (a, b) in zip(before, after) { let d = abs(a - b); worst = max(worst, d); squared += d * d }
                let rms = sqrt(squared / Float(before.count))
                print("MASK coefficient barrier inverse \(inverse), depth \(depth): worst \(worst), RMS \(rms)")
                check(after.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } && worst < 0.01 && rms < 0.01,
                      "mask regression: coefficient barrier changes signed guided refinement (worst \(worst), RMS \(rms))")
            } }
        } else { check(false, "mask regression: guided coefficient kernels unavailable") }
    } catch {
        check(false, "mask regression fixture failed: \(error)")
    }
}
