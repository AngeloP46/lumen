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
        let ready = seeded(), restored = source(2)
        ready.storeMask(EditSession.aiSubject, EditSession.constant(0.7, extent))
        restored.noteFailure(EditSession.aiSubject)
        restored.restoreMasks(ready.snapshotMasks(), scaleX: 2, scaleY: 2)
        check(restored.failures.isEmpty && restored.cachedMask(EditSession.aiSubject)?.extent == restored.extent,
              "mask regression: ready replacement retains stale failure or wrong scaled extent")
        check(abs(mean(session.componentImage(background, source: restored, gain: 1)) - 0.3) < 0.003,
              "mask regression: successful transferred Subject changes Background coverage")

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
    } catch {
        check(false, "mask regression fixture failed: \(error)")
    }
}
