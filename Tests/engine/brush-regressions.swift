import Foundation
import CoreImage
import Darwin
import Metal

/// Actual brush raster/develop invariants; no model inference or mirrored compositing implementation.
func runBrushRegressionChecks() {
    guard let file = files.first, let session = EditSession(url: file, expandHDR: false) else {
        check(false, "brush regression: sample session unavailable"); return
    }
    let context = LumenGPU.context
    func source(_ edge: Int) -> ImageSource {
        let ext = CGRect(x: 0, y: 0, width: edge, height: edge * 3 / 4)
        return ImageSource(base: EditSession.constant(0.18, ext), l1: EditSession.constant(0.5, ext),
                           l2: EditSession.constant(0, ext), chroma: EditSession.constant(0.18, ext),
                           air: SIMD3<Float>(repeating: 0.18), darkNorm: 0.18,
                           stats: PixelGrid(width: 1, height: 1, data: [0.18, 0.18, 0.18, 1]))
    }
    func stroke(_ x0: Double, _ x1: Double, _ y: Double, _ size: Double,
                erase: Bool = false, feather: Double = 50) -> BrushStroke {
        BrushStroke(points: [Pt(x: x0, y: y), Pt(x: x1, y: y)], size: size, erase: erase, feather: feather)
    }
    // Fixed output grid, with a finite crop and clamped resampling. These compare the actual native-sized
    // mask/developed graph while avoiding transparent sample coverage at the diagnostic bitmap's borders.
    func values(_ image: CIImage, roi: CGRect = CGRect(x: 0.05, y: 0.25, width: 0.5, height: 0.5)) -> [Float] {
        let ext = image.extent, scale = 512 / max(ext.width, ext.height)
        let target = CGRect(x: 0, y: 0, width: ext.width * scale, height: ext.height * scale)
        let small = image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: target)
        let bounds = CGRect(x: floor(roi.minX * target.width), y: floor(roi.minY * target.height),
                            width: floor(roi.width * target.width), height: floor(roi.height * target.height))
        let width = Int(bounds.width), height = Int(bounds.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { p in
            context.render(small, toBitmap: p.baseAddress!, rowBytes: width * 16, bounds: bounds,
                           format: .RGBAf, colorSpace: nil)
        }
        return (0..<(width * height)).map { pixels[$0 * 4] }
    }
    func maximumDifference(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return zip(a, b).map { abs($0 - $1) }.max() ?? .infinity
    }
    func developed(_ c: MaskComponent, _ src: ImageSource) -> CIImage {
        var edits = EditSettings(); edits.hdr = false
        var mask = Mask(name: "brush regression", components: [c]); mask.adjust.exposure = 1.5
        edits.masks = [mask]
        return session.develop(edits, source: src, geometry: false, lens: .off)
    }
    func mask(_ c: MaskComponent, _ src: ImageSource) -> CIImage { session.componentImage(c, source: src, gain: 1) }
    var previews: [[Float]] = [], exportSized: [[Float]] = []
    for edge in [1024, 4096] {
        autoreleasepool {
            let src = source(edge)
            var c = MaskComponent.make(.brush); c.feather = 50
            let paint = stroke(0.15, 0.43, 0.5, 0.1)
            let erase = stroke(0.15, 0.43, 0.5, 0.1, erase: true)
            c.strokes = [paint, erase]
            let beforeMask = values(mask(c, src)), beforePhoto = values(developed(c, src))
            c.strokes.append(stroke(0.80, 0.86, 0.5, 0.04, feather: 100))
            let afterMask = values(mask(c, src)), afterPhoto = values(developed(c, src))
            let maskDelta = maximumDifference(beforeMask, afterMask)
            let photoDelta = maximumDifference(beforePhoto, afterPhoto)
            print("BRUSH remote feather \(edge)px: old-region mask max delta \(maskDelta), developed \(photoDelta)")
            check(maskDelta < 0.004 && photoDelta < 0.002,
                  "brush regression: remote feather change reinterprets earlier paint/erase at \(edge)px (mask \(maskDelta), photo \(photoDelta))")
            let right = CGRect(x: 0.73, y: 0.35, width: 0.22, height: 0.3)
            check((values(mask(c, src), roi: right).max() ?? 0) > 0.08,
                  "brush regression: new remote stroke was omitted at \(edge)px")
            // Undo and redo exercise the existing final-component cache, including removing stale versions.
            c.strokes.removeLast()
            let undone = values(mask(c, src))
            check(maximumDifference(beforeMask, undone) < 0.001,
                  "brush regression: undo cannot restore the earlier brush at \(edge)px")
            c.strokes.append(stroke(0.80, 0.86, 0.5, 0.04, feather: 100))
            check(maximumDifference(afterMask, values(mask(c, src))) < 0.001,
                  "brush regression: redo changes the saved brush result at \(edge)px")
            check(source(edge).cachedRaster(c) == nil && src.cachedRaster(c) != nil,
                  "brush regression: component raster is not scoped to its source")

            // Erasing is monotonic, and repainting works in chronological order for both hard and soft brushes.
            for feather in [0.0, 50, 100] {
                var p = MaskComponent.make(.brush)
                p.strokes = [stroke(0.15, 0.43, 0.5, 0.1, feather: feather)]
                let painted = values(mask(p, src)), paintedPhoto = values(developed(p, src))
                p.strokes.append(stroke(0.15, 0.43, 0.5, 0.1, erase: true, feather: feather))
                let erased = values(mask(p, src)), erasedPhoto = values(developed(p, src))
                check(zip(painted, erased).allSatisfy { $1 <= $0 + 0.004 }
                      && maximumDifference(painted, erased) > 0.1,
                      "brush regression: erase adds coverage or does nothing at feather \(feather), \(edge)px")
                check(zip(paintedPhoto, erasedPhoto).allSatisfy { $1 <= $0 + 0.002 },
                      "brush regression: erase reverses local exposure at feather \(feather), \(edge)px")
                p.strokes.append(stroke(0.15, 0.43, 0.5, 0.1, feather: feather))
                check(maximumDifference(painted, values(mask(p, src))) < 0.008,
                      "brush regression: paint after erase fails to restore coverage at feather \(feather), \(edge)px")
            }
            if edge == 1024 { previews = [afterMask, afterPhoto] } else { exportSized = [afterMask, afterPhoto] }

            // Legacy strokes with no stored feather use the component's feather consistently too.
            var legacy = c
            for i in legacy.strokes.indices { legacy.strokes[i].feather = nil }
            legacy.strokes.removeLast()
            let legacyBefore = values(mask(legacy, src))
            legacy.strokes.append(stroke(0.80, 0.86, 0.5, 0.04, feather: 100))
            check(maximumDifference(legacyBefore, values(mask(legacy, src))) < 0.004,
                  "brush regression: old implicit feather strokes change after a remote explicit feather at \(edge)px")
            // A new remote run must also be harmless when it crosses a bounded-graph checkpoint.
            if edge == 1024 {
                for count in [7, 8, 15, 16] {
                    var many = MaskComponent.make(.brush)
                    many.strokes = (0..<count).map { i in
                        stroke(0.15, 0.43, 0.5, 0.1, erase: i % 2 == 1, feather: i % 3 == 0 ? 50 : 25)
                    }
                    let before = values(mask(many, src))
                    many.strokes.append(stroke(0.80, 0.86, 0.5, 0.04, feather: 100))
                    check(maximumDifference(before, values(mask(many, src))) < 0.004,
                          "brush regression: remote run changes old coverage across checkpoint \(count)")
                }
            }
        }
        context.clearCaches()
    }
    if previews.count == 2 && exportSized.count == 2 {
        check(maximumDifference(previews[0], exportSized[0]) < 0.008,
              "brush regression: preview/export-sized mask coverage differs")
        check(maximumDifference(previews[1], exportSized[1]) < 0.004,
              "brush regression: preview/export-sized local exposure differs")
    }

    func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
    func settleGPUResources() {
        // Both contexts use this Metal queue. Wait for submitted GPU work before releasing their reusable
        // resources, then drain the barrier's own autoreleases before calling the footprint settled.
        autoreleasepool {
            if let barrier = LumenGPU.queue?.makeCommandBuffer() {
                barrier.commit(); barrier.waitUntilCompleted()
            }
            context.clearCaches()
            LumenGPU.drawContext.clearCaches()
        }
    }
    // Render real 1/20/100-run graphs, then time cached reuse and report retained process footprint. Each rebuild
    // uses the same component ID so storeRaster must replace its old version rather than retaining history.
    let benchmarkSource = source(1024)
    var component = MaskComponent.make(.brush)
    let previousProbe = EditSession.brushCheckpointProbe
    var checkpointUsage: [(renders: Int, buffers: Int, pooled: Bool)] = []
    EditSession.brushCheckpointProbe = { checkpointUsage.append(($0, $1, $2)) }
    defer { EditSession.brushCheckpointProbe = previousProbe }
    for runs in [1, 20, 100] {
        autoreleasepool {
            component.strokes = (0..<runs).map { i in
                let y = 0.12 + Double(i % 9) * 0.085
                return stroke(0.10 + Double(i % 3) * 0.06, 0.82, y, 0.06,
                              erase: i % 2 == 1, feather: i % 3 == 0 ? 25 : 75)
            }
            let memoryBefore = footprint(), start = ProcessInfo.processInfo.systemUptime
            let rendered = values(mask(component, benchmarkSource))
            let buildMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let held = footprint(), reuseStart = ProcessInfo.processInfo.systemUptime
            let cached = values(mask(component, benchmarkSource))
            let reuseMS = (ProcessInfo.processInfo.systemUptime - reuseStart) * 1000
            print(String(format: "BRUSH BENCH %d runs: rebuild+GPU %.1f ms, cache+GPU %.1f ms, footprint %d -> %d MB",
                         runs, buildMS, reuseMS, memoryBefore, held))
            check(rendered.allSatisfy { $0.isFinite && $0 >= -0.001 && $0 <= 1.001 }
                  && maximumDifference(rendered, cached) < 0.001,
                  "brush regression: \(runs)-run raster invalid or cached reuse differs")
        }
        settleGPUResources()
        print("BRUSH BENCH \(runs) runs after GPU cache release, final component retained: \(footprint()) MB")
    }
    var retained: [Int] = []
    var fingerprints: [Int: UInt64] = [:]
    // Warm the GPU's reusable texture heaps before measuring retention. Early cold allocations vary by the
    // preceding RAW/model checks; they must not be mistaken for a component retaining its earlier graphs.
    // Sixteen measured rebuilds after eight warm-ups still expose linear growth, with the same 64 MB bound.
    for repeatIndex in 0..<24 {
        let before = footprint(), started = ProcessInfo.processInfo.systemUptime
        autoreleasepool {
            // The benchmark ends at .10: start at .11 so every iteration really rebuilds.
            component.strokes[0].points[0].x = repeatIndex % 2 == 0 ? 0.11 : 0.10
            let pixels = values(mask(component, benchmarkSource))
            let fingerprint = pixels.reduce(UInt64(1469598103934665603)) {
                ($0 ^ UInt64($1.bitPattern)) &* 1099511628211
            }
            if let expected = fingerprints[repeatIndex % 2] {
                check(fingerprint == expected, "brush regression: checkpoint pool reuse changes identical rebuilt pixels")
            } else { fingerprints[repeatIndex % 2] = fingerprint }
        }
        let afterBuild = footprint()
        settleGPUResources()
        let settled = footprint()
        if repeatIndex >= 8 { retained.append(settled) }
        print(String(format: "BRUSH REBUILD %d: %.1f ms, footprint %d -> %d -> %d MB after cache release; cached component rasters %d",
                     repeatIndex + 1, (ProcessInfo.processInfo.systemUptime - started) * 1000,
                     before, afterBuild, settled, benchmarkSource.cachedRasterCount))
        check(benchmarkSource.cachedRasterCount == 1,
              "brush regression: repeated rebuild retains multiple component-cache entries")
    }
    print("BRUSH BENCH 100-run replacement settled footprints MB: \(retained)")
    if let first = retained.first, let highest = retained.max() {
        check(first >= 0 && highest - first < 64,
              "brush regression: replacing one component retains prior 100-run graphs (\(retained) MB)")
    }
    let longRebuilds = checkpointUsage.filter { $0.renders >= 12 }
    print("BRUSH checkpoint pool long-rebuild usage (renders, distinct buffers, pooled): \(longRebuilds)")
    check(longRebuilds.count >= 24 && longRebuilds.allSatisfy { $0.pooled && $0.buffers <= 3 },
          "brush regression: 100-run rebuild does not reuse its bounded checkpoint backings (\(longRebuilds))")
}
