import CoreImage
import CoreML
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Metal
import Vision

// Headless render test: `engine-test <metallib> <inputDir> <outDir>`
setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
LumenGPU.libraryURL = URL(fileURLWithPath: args[1])
let inDir = URL(fileURLWithPath: args[2])
let outDir = URL(fileURLWithPath: args[3])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
print("Metal:", LumenGPU.device?.name ?? "none", "kernels:", LumenKernels.shared != nil)
guard LumenKernels.shared != nil else { print("KERNELS FAILED TO LOAD"); exit(1) }


// ---- Orientation probe: render a CIImage (top half red, bottom half blue) into a Metal texture.
do {
    guard let dev = LumenGPU.device, let q = LumenGPU.queue else { fatalError("no metal") }
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
    td.usage = [.shaderRead, .shaderWrite, .renderTarget]
    td.storageMode = .shared
    let tex = dev.makeTexture(descriptor: td)!
    let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 32, width: 64, height: 32)) // CI top half
    let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
    let img = red.composited(over: blue)
    let cb = q.makeCommandBuffer()!
    LumenGPU.context.render(img, to: tex, commandBuffer: cb, bounds: CGRect(x: 0, y: 0, width: 64, height: 64), colorSpace: LumenGPU.displaySpace)
    cb.commit(); cb.waitUntilCompleted()
    var px = [UInt8](repeating: 0, count: 4)
    tex.getBytes(&px, bytesPerRow: 256, from: MTLRegionMake2D(32, 2, 1, 1), mipmapLevel: 0)
    print("PROBE texture row 2 (top row of memory) BGRA:", px, px[2] > 200 ? "=> CI top is texture top (NO flip needed)" : "=> FLIPPED (need flip)")
}

// ---- Pass/fail harness: each failed check prints "FAIL: ..."; the summary goes to stdout and RESULT.txt,
// and the tool exits 1 if anything failed.
var checkCount = 0
var failures: [String] = []
func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    checkCount += 1
    if !ok {
        let m = message()
        failures.append(m)
        print("FAIL:", m)
        // also as a GitHub annotation, readable through the API without downloading logs
        print("::error::" + m.replacingOccurrences(of: "\n", with: " ").prefix(900))
    }
}
func finishChecks() -> Never {
    let summary = failures.isEmpty
        ? "PASS: all \(checkCount) checks passed"
        : "FAILED: \(failures.count) of \(checkCount) checks failed\n" + failures.map { "  - " + $0 }.joined(separator: "\n")
    print("==== TEST SUMMARY ====")
    print(summary)
    try? (summary + "\n").write(to: outDir.appendingPathComponent("RESULT.txt"), atomically: true, encoding: .utf8)
    exit(failures.isEmpty ? 0 : 1)
}

// Clipping must mark real black/white pixels while leaving transparent letterboxing empty.
do {
    let kernel = LumenKernels.shared!.clip!
    let bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
    for (name, color, expected) in [
        ("transparent", CIColor(red: 0, green: 0, blue: 0, alpha: 0), [Float](repeating: 0, count: 4)),
        ("black", CIColor(red: 0, green: 0, blue: 0), [Float(0.1), 0.4, 1, 1]),
        ("white", CIColor(red: 1, green: 1, blue: 1), [Float(1), 0.08, 0.08, 1])
    ] {
        let image = CIImage(color: color).cropped(to: bounds)
        guard let result = kernel.apply(extent: bounds, arguments: [image, CIVector(x: 1, y: 0.0007, z: 0, w: 0)]) else {
            check(false, "clipping kernel failed for \(name)"); continue
        }
        var pixel = [Float](repeating: 0, count: 4)
        LumenGPU.context.render(result, toBitmap: &pixel, rowBytes: 16,
                                bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        for i in 0..<4 { check(abs(pixel[i] - expected[i]) < 0.015, "clipping \(name) channel \(i): \(pixel)") }
    }
}

func now() -> Double { Date().timeIntervalSinceReferenceDate }

func saveJPEG(_ cg: CGImage, _ name: String) {
    let url = outDir.appendingPathComponent(name)
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    CGImageDestinationFinalize(d)
}

func sheet(_ items: [(String, CGImage)], cell: Int = 420, cols: Int = 3) -> CGImage? {
    guard let first = items.first else { return nil }
    let aspect = CGFloat(first.1.height) / CGFloat(first.1.width)
    let ch = Int(CGFloat(cell) * aspect)
    let rows = (items.count + cols - 1) / cols
    let labelH = 22
    let W = cols * cell, H = rows * (ch + labelH)
    guard let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    c.setFillColor(CGColor(gray: 0.1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    for (i, it) in items.enumerated() {
        let col = i % cols, row = i / cols
        let x = col * cell, y = H - (row + 1) * (ch + labelH)
        c.interpolationQuality = .high
        c.draw(it.1, in: CGRect(x: x, y: y, width: cell - 2, height: ch))
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attr = NSAttributedString(string: it.0, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
        let line = CTLineCreateWithAttributedString(attr)
        c.textPosition = CGPoint(x: x + 6, y: y + ch + 5)
        CTLineDraw(line, c)
    }
    return c.makeImage()
}

func edit(_ f: (inout EditSettings) -> Void) -> EditSettings { var s = EditSettings(); f(&s); return s }

/// RGBA8 bytes of a CGImage (rows top to bottom, 4 bytes per pixel), drawn into a display-P3 bitmap so every
/// image compared in the checks below has the same layout.
func rgbaBytes(_ cg: CGImage) -> [UInt8]? {
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ok = buf.withUnsafeMutableBytes { p -> Bool in
        guard let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: LumenGPU.displaySpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? buf : nil
}

/// Small display-P3 RGBA8 render of a CIImage, `width` pixels wide (same scaling for every image of the same size).
func smallRender(_ img: CIImage, width: CGFloat = 96) -> CGImage? {
    let k = width / img.extent.width
    let out = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
    return LumenGPU.context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace)
}

/// Per-channel comparison of two images over their common area, in 0...255 units.
/// `all` = mean |a - b| over every pixel; `mid` = the same over pixels whose reference (b) channels are all below 200,
/// i.e. away from the highlight shoulder; `midCount` = how many such pixels there were.
func compareImages(_ a: CGImage, _ b: CGImage) -> (all: Double, mid: Double, midCount: Int)? {
    guard let pa = rgbaBytes(a), let pb = rgbaBytes(b) else { return nil }
    let w = min(a.width, b.width), h = min(a.height, b.height)
    guard w > 0, h > 0 else { return nil }
    var sumAll = 0.0, sumMid = 0.0, nMid = 0
    for y in 0..<h {
        for x in 0..<w {
            let ia = (y * a.width + x) * 4, ib = (y * b.width + x) * 4
            var d = 0.0
            for c in 0..<3 { d += abs(Double(pa[ia + c]) - Double(pb[ib + c])) }
            sumAll += d / 3
            if pb[ib] < 200 && pb[ib + 1] < 200 && pb[ib + 2] < 200 { sumMid += d / 3; nMid += 1 }
        }
    }
    return (sumAll / Double(w * h), nMid > 0 ? sumMid / Double(nMid) : 0, nMid)
}

/// Mean and standard deviation of the (display-encoded) luma 0.2126 R + 0.7152 G + 0.0722 B, in 0...255 units.
func lumaStats(_ cg: CGImage) -> (mean: Double, std: Double)? {
    guard let p = rgbaBytes(cg), cg.width > 0, cg.height > 0 else { return nil }
    let n = cg.width * cg.height
    var sum = 0.0, sum2 = 0.0
    for i in 0..<n {
        let y = 0.2126 * Double(p[i * 4]) + 0.7152 * Double(p[i * 4 + 1]) + 0.0722 * Double(p[i * 4 + 2])
        sum += y; sum2 += y * y
    }
    let mean = sum / Double(n)
    return (mean, (max(sum2 / Double(n) - mean * mean, 0)).squareRoot())
}

/// Mean over all pixels of (max channel - min channel), in 0...255 units: 0 = perfectly neutral grey.
func meanChannelSpread(_ cg: CGImage) -> Double? {
    guard let p = rgbaBytes(cg), cg.width > 0, cg.height > 0 else { return nil }
    let n = cg.width * cg.height
    var sum = 0.0
    for i in 0..<n {
        let r = Int(p[i * 4]), g = Int(p[i * 4 + 1]), b = Int(p[i * 4 + 2])
        sum += Double(max(r, g, b) - min(r, g, b))
    }
    return sum / Double(n)
}

/// Float values (0...1, red channel) of a finished mask image, `width` pixels wide, rows in whatever order Core Image
/// writes them. Rendered with no colour management so the numbers are the raw mask values.
func maskValues(_ img: CIImage, width: Int = 64) -> (v: [Float], w: Int, h: Int)? {
    let k = CGFloat(width) / img.extent.width
    let scaled = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
    // Whole pixels strictly inside the scaled extent, minus a one pixel border: the edge pixels of a fractionally
    // sized image are only partly covered and would read as bogus values.
    let e = scaled.extent
    let x0 = ceil(e.minX) + 1, y0 = ceil(e.minY) + 1
    let r = CGRect(x: x0, y: y0, width: floor(e.maxX) - 1 - x0, height: floor(e.maxY) - 1 - y0)
    let w = Int(r.width), h = Int(r.height)
    guard w > 0, h > 0 else { return nil }
    var buf = [Float](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { p in
        LumenGPU.context.render(scaled, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: nil)
    }
    return ((0..<(w * h)).map { buf[$0 * 4] }, w, h)
}

/// Mean display luma (0...255) of the darkest 10% and the brightest 10% of pixels.
func lumaTails(_ cg: CGImage) -> (low: Double, high: Double)? {
    guard let p = rgbaBytes(cg), cg.width > 0, cg.height > 0 else { return nil }
    let n = cg.width * cg.height
    var ys = [Double](repeating: 0, count: n)
    for i in 0..<n { ys[i] = 0.2126 * Double(p[i * 4]) + 0.7152 * Double(p[i * 4 + 1]) + 0.0722 * Double(p[i * 4 + 2]) }
    ys.sort()
    let k = max(1, n / 10)
    return (ys[0..<k].reduce(0, +) / Double(k), ys[(n - k)..<n].reduce(0, +) / Double(k))
}

/// Raw float RGBA values of an image `width` pixels wide (no colour management), for NaN/Inf checks.
func floatPixels(_ img: CIImage, width: Int = 64) -> [Float]? {
    let k = CGFloat(width) / img.extent.width
    let scaled = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
    let r = scaled.extent.integral
    let w = Int(r.width), h = Int(r.height)
    guard w > 0, h > 0 else { return nil }
    var buf = [Float](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { p in
        LumenGPU.context.render(scaled, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: nil)
    }
    return buf
}

let files = (try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)) ?? []

// ---- Memory budget (`--memory`, its own process so nothing else is counted): the 24 MP Sony ARW opened the way
// the phone opens it (HDR), the 100 % view's full-size copy, a subject mask, a big heal and a full-size export.
// iOS closes Lumen at about 3.4 GB (owner's JetsamEvent, 18 Oct: killed at 3388 MB). The Mac counts GPU memory a
// little differently, so the budget leaves room; the point is to catch a change that suddenly needs much more.
if args.contains("--memory") {
    func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
    final class Peak: @unchecked Sendable { var mb = 0; var stop = false; let lock = NSLock() }
    let peak = Peak()
    Thread.detachNewThread {
        while true {
            peak.lock.lock(); let done = peak.stop; peak.mb = max(peak.mb, footprintMB()); peak.lock.unlock()
            if done { break }
            usleep(10_000)
        }
    }
    func stepPeak(_ name: String, _ work: () -> Void) -> Int {
        peak.lock.lock(); peak.mb = footprintMB(); peak.lock.unlock()
        let t = now()
        work()
        LumenGPU.context.clearCaches()
        peak.lock.lock(); let p = peak.mb; peak.lock.unlock()
        print("MEMORY \(name): peak \(p) MB, after \(footprintMB()) MB, \(String(format: "%.1f", now() - t)) s")
        return p
    }
    // budgets per step (MB); the whole run must stay under `total`
    let budget: [String: Int] = ["open": 1400, "full-size view": 2200, "subject": 2200, "heal": 2600, "export": 2600]
    let total = 2800
    guard let arw = files.first(where: { $0.pathExtension.lowercased() == "arw" }),
          let session = EditSession(url: arw, expandHDR: true) else {
        check(false, "memory test needs the Sony ARW"); finishChecks()
    }
    EditSession.healProbe = { print("MEMORY   \($0): \(footprintMB()) MB") }
    print("MEMORY start \(footprintMB()) MB, photo \(Int(session.nativeSize.width))x\(Int(session.nativeSize.height))")
    var preview: ImageSource?
    var detail: ImageSource?
    var peaks: [String: Int] = [:]
    var s = EditSettings(); s.hdr = true; s.exposure = 0.3; s.clarity = 20
    peaks["open"] = stepPeak("open") {
        preview = session.makeSource(maxEdge: 2560, materialize: true)
        if let p = preview { _ = session.renderCGImage(s, source: p) }
    }
    peaks["full-size view"] = stepPeak("full-size view") {
        let edge = min(max(session.nativeSize.width, session.nativeSize.height), 4096)
        detail = session.makeSource(maxEdge: edge, materialize: true)
        if let d = detail { _ = session.renderCGImage(s, source: d) }
    }
    peaks["subject"] = stepPeak("subject") { if let p = preview { session.ensureSubject(p) } }
    // the app lets go of the full-size copy before healing (freeMemoryForHeal)
    detail = nil
    // where a heal's memory goes: the full-size decode of the area, and the model itself
    _ = stepPeak("heal: full decode, 1 square") {
        if let full = session.decode(maxEdge: nil) {
            let r = CGRect(x: 1000, y: 1000, width: 2400, height: 2400)
            let sq = full.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 800.0 / 2400.0, kCIInputAspectRatioKey: 1.0])
            _ = LumenGPU.context.createCGImage(sq, from: CGRect(x: 0, y: 0, width: 800, height: 800))
        }
    }
    if ProcessInfo.processInfo.environment["LUMEN_HEAL_MODEL"] != nil {
        _ = stepPeak("heal: model load") { EditSession.prepareHealModel() }
        let stroke = BrushStroke(points: [Pt(x: 0.4, y: 0.35), Pt(x: 0.5, y: 0.5), Pt(x: 0.6, y: 0.65)], size: 0.08, erase: false, feather: nil)
        var spot: HealSpot?
        peaks["heal"] = stepPeak("heal") { spot = session.makeHeal(strokes: [stroke], earlier: []) }
        check(spot != nil, "memory test: the heal failed")
        if let spot { s.heals = [spot] }
    }
    peaks["export"] = stepPeak("export") { _ = session.renderData(s, format: .jpeg, quality: 0.9, maxEdge: nil, includeHDR: true) }
    peak.lock.lock(); peak.stop = true; peak.lock.unlock()
    for (name, mb) in peaks.sorted(by: { $0.key < $1.key }) {
        let limit = budget[name] ?? total
        check(mb <= limit, "memory: \(name) peaked at \(mb) MB, budget \(limit) MB")
        if mb > limit * 8 / 10 { print("::warning::memory: \(name) at \(mb) MB is near its \(limit) MB budget") }
    }
    let top = peaks.values.max() ?? 0
    check(top <= total, "memory: peak \(top) MB, budget \(total) MB")
    print("::notice::memory peak \(top) MB (budget \(total) MB): " + peaks.sorted(by: { $0.key < $1.key }).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    _ = preview
    finishChecks()
}
// Lens Blur: controlled foreground/background detail, independent of model accuracy.
if let file = files.first, let session = EditSession(url: file),
   let sample = session.makeSource(maxEdge: 128, materialize: false) {
    let extent = CGRect(x: 0, y: 0, width: 256, height: 128)
    var pattern = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: extent)
    // fine stripes (period 4 px): the gentler 15 Oct scale gives a ~2.6 px disc at amount 100 on this 256 px test
    for x in stride(from: 0, to: 256, by: 4) {
        let stripe = CIImage(color: CIColor(red: 0.7, green: 0.7, blue: 0.7))
            .cropped(to: CGRect(x: x, y: 0, width: 2, height: 128))
        pattern = stripe.composited(over: pattern)
    }
    func source(_ image: CIImage) -> ImageSource {
        ImageSource(base: image, l1: image, l2: image, chroma: image,
                    air: sample.air, darkNorm: sample.darkNorm, stats: sample.stats)
    }
    let src = source(pattern)
    let near = EditSession.constant(0.1, extent)
    let far = EditSession.constant(0.9, CGRect(x: 128, y: 0, width: 128, height: 128))
    src.storeMask(EditSession.aiDepth, far.composited(over: near))
    var settings = EditSettings()
    settings.lensBlur.amount = 100
    let output = session.applyLensBlur(pattern, settings: settings, source: src)
    check(output.extent == extent, "Lens Blur changed image bounds")
    func values(_ image: CIImage, _ region: CGRect) -> [Float] {
        var p = [Float](repeating: 0, count: Int(region.width * region.height) * 4)
        p.withUnsafeMutableBytes { bytes in
            LumenGPU.context.render(image, toBitmap: bytes.baseAddress!, rowBytes: Int(region.width) * 16,
                                    bounds: region, format: .RGBAf, colorSpace: nil)
        }
        return p
    }
    let foreground = CGRect(x: 16, y: 16, width: 80, height: 80)
    let fp = values(pattern, foreground), fo = values(output, foreground)
    check(zip(fp, fo).allSatisfy { abs($0.0 - $0.1) < 0.002 }, "Lens Blur altered the sharp foreground")
    let background = CGRect(x: 160, y: 16, width: 80, height: 80)
    func spread(_ p: [Float]) -> Float {
        let red = stride(from: 0, to: p.count, by: 4).map { p[$0] }
        let mean = red.reduce(0, +) / Float(red.count)
        return red.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(red.count)
    }
    check(spread(values(output, background)) < spread(values(pattern, background)) * 0.45,
          "Lens Blur did not reduce background detail")
    // Live preview (half resolution while sliding) must look like the full blur and keep the sharp part sharp
    let liveMask = session.lensBlurMask(settings, source: src)!
    let live = EditSession.maskedLensBlur(pattern, mask: liveMask, radius: 100.0 / 100 * 256 * LensBlurSettings.radiusScale * 4, scale: 0.5)
    let fullBlur = EditSession.maskedLensBlur(pattern, mask: liveMask, radius: 100.0 / 100 * 256 * LensBlurSettings.radiusScale * 4)
    check(live.extent == extent, "Live Lens Blur preview changed image bounds")
    let lv = values(live, background), fv = values(fullBlur, background)
    let liveDelta = zip(lv, fv).map { abs($0.0 - $0.1) }.reduce(0, +) / Float(lv.count)
    check(liveDelta < 0.06 && lv.allSatisfy { $0.isFinite }, "Live Lens Blur preview differs from the full blur: \(liveDelta)")
    check(zip(values(live, foreground), values(pattern, foreground)).allSatisfy { abs($0.0 - $0.1) < 0.002 },
          "Live Lens Blur preview softened the sharp foreground")
    // Lens-like: a bright subject must not glow into the blurred background next to it.
    let bright = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        .composited(over: CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02)).cropped(to: extent))
    let edge = values(session.applyLensBlur(bright, settings: settings, source: src), CGRect(x: 130, y: 16, width: 8, height: 96))
    let edgeMean = stride(from: 0, to: edge.count, by: 4).map { edge[$0] }.reduce(0, +) / Float(edge.count / 4)
    check(edgeMean < 0.05, "Lens Blur let the subject's colour bleed into the background: \(edgeMean)")
    // and a lone bright point in the background spreads into a round disc, not a soft dot
    let point = CIImage(color: CIColor(red: 8, green: 8, blue: 8)).cropped(to: CGRect(x: 191, y: 63, width: 2, height: 2))
        .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent))
    let spot = values(session.applyLensBlur(point, settings: settings, source: src), CGRect(x: 184, y: 64, width: 16, height: 1))
    let reds = stride(from: 0, to: spot.count, by: 4).map { spot[$0] }
    print("Lens Blur point profile:", reds.map { String(format: "%.3f", $0) }.joined(separator: " "))
    check(reds.max()! > 0.01 && reds.allSatisfy { $0.isFinite }, "Lens Blur point light vanished")
    settings.lensBlur.amount = 0
    check(values(session.applyLensBlur(pattern, settings: settings, source: src), background) == values(pattern, background),
          "Zero Lens Blur amount changed pixels")
    settings.lensBlur.amount = 100
    let noDepth = source(pattern)
    check(values(session.applyLensBlur(pattern, settings: settings, source: noDepth), background) == values(pattern, background),
          "Missing depth produced an unexpected blur")
    settings.lensBlur.focusDistance = 1
    check(values(session.applyLensBlur(pattern, settings: settings, source: src), background) == values(pattern, background),
          "Farthest focus plane should leave no background blur")
    settings.lensBlur.focusDistance = 0.3
    settings.setOn(.lensBlur, false)
    check(values(session.applyLensBlur(pattern, settings: settings, source: src), background) == values(pattern, background),
          "Disabled Lens Blur still rendered")
    settings.setOn(.lensBlur, true)
    var mask = Mask.make(.linear)
    mask.components[0].x0 = 0.5; mask.components[0].y0 = 0
    mask.components[0].x1 = 0.5; mask.components[0].y1 = 1
    mask.amount = 0
    settings.masks = [mask]; settings.lensBlur.maskID = mask.id
    check(values(session.applyLensBlur(pattern, settings: settings, source: src), background) == values(pattern, background),
          "Lens Blur ignored an editable mask's zero opacity")
    var depthRefinement = Mask.make(.depth)
    settings.masks = [depthRefinement]; settings.lensBlur.maskID = depthRefinement.id
    check(session.lensBlurMask(settings, source: noDepth) == nil,
          "Refined depth blur must report missing depth instead of silently exporting unblurred")
    depthRefinement.components[0].amount = 0
    settings.masks = [depthRefinement]
    check(session.lensBlurMask(settings, source: noDepth) != nil,
          "Inactive depth component must not require depth")
    settings.masks = []
    settings.lensBlur.maskID = nil
    let scale = CGAffineTransform(scaleX: 2, y: 2)
    let large = source(pattern.transformed(by: scale))
    large.storeMask(EditSession.aiDepth, src.cachedMask(EditSession.aiDepth)!.transformed(by: scale))
    let resized = EditSession.downscaled(session.applyLensBlur(large.base, settings: settings, source: large), 0.5)
    let a = values(output, background), b = values(resized, background)
    let delta = zip(a, b).map { abs($0.0 - $0.1) }.reduce(0, +) / Float(a.count)
    check(delta < 0.035, "Lens Blur strength changed with render size: \(delta)")
    settings.quarterTurns = 1; settings.cropL = 0.1; settings.cropR = 0.8
    let transformed = session.geometry(output, settings)
    check(transformed.extent.width < transformed.extent.height,
          "Lens Blur crop/rotation dimensions were incorrect")
    check(values(transformed, transformed.extent).allSatisfy { $0.isFinite },
          "Lens Blur rotation/crop produced nonfinite pixels")
    var json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
    json.removeValue(forKey: "lensBlur")
    let legacy = try! JSONDecoder().decode(EditSettings.self, from: JSONSerialization.data(withJSONObject: json))
    check(legacy.lensBlur == LensBlurSettings(), "Older sidecar did not default Lens Blur to off")
    let roundTrip = try! JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(settings))
    check(roundTrip == settings, "Lens Blur did not survive sidecar round trip")
    check(!EditSection.lensBlur.canPaste, "Photo-specific Lens Blur should not be pasted to another photo")
    let rampSource = source(pattern)
    func dataDepth(_ value: Float) -> CIImage {
        EditSession.depthImage(DepthField(width: 8, height: 8, values: Array(repeating: value, count: 64), histogram: []), extent: extent)
    }
    let depthRamp = dataDepth(0.6)
    rampSource.storeMask(EditSession.aiDepth, depthRamp)
    var rampSettings = EditSettings(); rampSettings.lensBlur.amount = 100
    let middleMap = session.lensBlurMask(rampSettings, source: rampSource)!
    rampSource.storeMask(EditSession.aiDepth, dataDepth(0.9))
    let farMap = session.lensBlurMask(rampSettings, source: rampSource)!
    check(values(farMap, background)[0] > values(middleMap, background)[0] + 0.3,
          "Far blur must keep increasing past the old short feather ramp")
    rampSource.storeMask(EditSession.aiSubject, EditSession.constant(1, extent))
    check(values(session.lensBlurMask(rampSettings, source: rampSource)!, background)[0] < 0.001,
          "Detected subject must remain protected despite wrong far depth")
    let tight = DepthField(width: 4, height: 2, values: [0.72, 0.74, 0.76, 0.78, 0.80, 0.82, 0.84, 0.86], histogram: [])
    check(tight.usefulRange.lowerBound > 0.6 && tight.usefulRange.upperBound < 0.95,
          "Distance slider should calibrate to this photo's depth distribution")
    let oldBlur = try! JSONDecoder().decode(LensBlurSettings.self, from: Data("{\"amount\":0,\"focusDistance\":0.3,\"focusWidth\":0.12}".utf8))
    check(oldBlur.activated && oldBlur.amount == 0, "Saved legacy zero must not activate blur")
    var upgraded = oldBlur
    check(upgraded.beginEditing() && upgraded.amount == LensBlurSettings.startAmount, "Old untouched zero must start at the start amount when Lens Blur is opened")
    upgraded.amount = 0
    let savedOff = try! JSONDecoder().decode(LensBlurSettings.self, from: JSONEncoder().encode(upgraded))
    var reopened = savedOff
    check(!reopened.beginEditing() && reopened.amount == 0, "New explicit zero must survive migration/reopen")
    var existingOff = oldBlur; existingOff.focusDistance = 0.4
    check(!existingOff.beginEditing() && existingOff.amount == 0, "Previously adjusted zero must stay off")
    let oldScale = try! JSONDecoder().decode(LensBlurSettings.self, from: Data("{\"amount\":35,\"activated\":true,\"controlsVersion\":1}".utf8))
    check(abs(oldScale.amount - 100) < 0.01 && oldScale.scaleVersion == 2, "Old-scale 35 must become 100 on the gentler scale")
    let newScale = try! JSONDecoder().decode(LensBlurSettings.self, from: JSONEncoder().encode(oldScale))
    check(abs(newScale.amount - 100) < 0.01, "New-scale amounts must not be converted twice")
    var untouched = LensBlurSettings()
    check(untouched.amount == 0 && untouched.beginEditing() && untouched.amount == LensBlurSettings.startAmount, "New photos change only on explicit Lens Blur entry")

    check(!LensBlurSettings().activated && LensBlurSettings().amount == 0, "Untouched photos must start unchanged")
    check(!EditSettings().hasEdits(.lensBlur), "Activation bookkeeping must not mark untouched photos edited")
    var resetBlur = EditSettings(); resetBlur.reset(.lensBlur)
    check(resetBlur.lensBlur.activated && resetBlur.lensBlur.amount == 0, "Reset must remember the user's off choice")
    check(!resetBlur.lensBlur.beginEditing() && resetBlur.lensBlur.amount == 0, "Explicit Reset must not restart at 8")
    if let rangeKernel = LumenKernels.shared?.rangeMask {
        let nearDepth = dataDepth(0.2), farDepth = dataDepth(0.8)
        let nearSoft = rangeKernel.apply(extent: extent, arguments: [nearDepth, CIVector(x: 0, y: 0.35, z: 1, w: 0)])!
        let farSoft = rangeKernel.apply(extent: extent, arguments: [farDepth, CIVector(x: 0.65, y: 1, z: 0, w: 1)])!
        check(values(nearSoft, background)[0] < 0.2, "Near endpoint feather must affect the depth mask")
        check(values(farSoft, background)[0] < 0.2, "Far endpoint feather must affect the depth mask")
    }
    rampSource.storeDepth(tight)
    if let band = session.lensSubjectRange(rampSource, point: nil) {
        check(band.lowerBound > 0.7 && band.upperBound > 0.8, "Focus range must measure the whole subject")
    } else { check(false, "Subject depth distribution unavailable") }

    if let cg = smallRender(output, width: 256) { saveJPEG(cg, "lens-blur-synthetic.jpg") }
}

// Standard EXIF is independent of camera make. These fixtures test metadata extraction, not RAW decoding.
if let image = CGImageSourceCreateWithURL(files[0] as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
    for make in ["Sony", "Canon", "Nikon", "FUJIFILM", "Panasonic", "OM Digital Solutions", "PENTAX", "Leica", "Apple"] {
        let url = outDir.appendingPathComponent("metadata-fixture.jpg")
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) {
            let exif: [CFString: Any] = [kCGImagePropertyExifLensModel: "24-70mm F2.8", kCGImagePropertyExifFocalLength: 35,
                kCGImagePropertyExifExposureTime: 1.0 / 800, kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [100], kCGImagePropertyExifDateTimeOriginal: "2026:10:03 11:01:30"]
            let properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: make, kCGImagePropertyTIFFModel: "Example camera"], kCGImagePropertyExifDictionary: exif]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            check(CGImageDestinationFinalize(destination), "Metadata fixture failed")
            let info = PhotoInformation.read(url)
            check(info.camera == "\(make) Example camera" && info.lens.contains("35 mm") && info.lens.contains("24-70"), "Camera/lens EXIF failed for \(make)")
            check(info.shutter == "1/800 sec" && info.aperture == "\u{0192}/2.8" && info.iso == "100", "Exposure EXIF failed for \(make)")
            check(info.date == "3 October 2026 \u{00B7} 11:01:30" && info.dimensions.contains("MP"), "Date/dimensions EXIF failed for \(make)")
        }
    }
    let missing = PhotoInformation.read(outDir.appendingPathComponent("missing-photo.jpg"))
    check(missing.camera == "Not recorded" && missing.shutter == "\u{2014}", "Missing metadata invented camera settings")
    try? FileManager.default.removeItem(at: outDir.appendingPathComponent("metadata-fixture.jpg"))
}

// Narrow follow-up after the full engine passed: new blur cases plus a real Sony camera RAW/export.
if args.contains("--lens-blur") {
    check(checkCount >= 20, "Focused Lens Blur assertions did not run")
    guard let raw = files.first(where: { $0.pathExtension.lowercased() == "arw" }),
          let session = EditSession(url: raw),
          let source = session.makeSource(maxEdge: 1200, materialize: true) else {
        check(false, "Focused blur check requires the Sony ARW sample"); finishChecks()
    }
    var s = EditSettings(); s.lensBlur.amount = 65
    session.prepareAutoMasks(s, source: source)
    check(source.depthField != nil, "Sony ARW depth estimation failed")
    if let d = source.depthField { s.lensBlur.focusDistance = Double(d.value(atNormalized: 0.5, 0.65)) }
    check(session.lensBlurMask(s, source: source) != nil, "Sony ARW blur map unavailable")
    if let before = session.renderCGImage(EditSettings(), source: source),
       let after = { () -> CGImage? in
           let t0 = Date(); let cg = session.renderCGImage(s, source: source)
           print(String(format: "Lens Blur Sony preview render %.0f ms (source %.0f px)", Date().timeIntervalSince(t0) * 1000,
                        Double(max(source.extent.width, source.extent.height))))
           return cg }(),
       let composite = sheet([("Sony ARW original", before), ("Lens Blur", after)]) {
        saveJPEG(composite, "lens-blur-sony-preview.jpg")
    } else { check(false, "Sony ARW blur preview failed") }
    if let data = session.renderData(s, format: .jpeg, quality: 0.9, maxEdge: 512, includeHDR: false),
       let reopened = CIImage(data: data) {
        check(max(reopened.extent.width, reopened.extent.height) == 512, "Blurred ARW JPEG export dimensions changed")
        try? data.write(to: outDir.appendingPathComponent("lens-blur-sony-export.jpg"))
    } else { check(false, "Sony ARW Lens Blur export failed") }
    finishChecks()
}

var opened = 0
for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    let stem = file.deletingPathExtension().lastPathComponent
    let t0 = now()
    guard let session = EditSession(url: file) else {
        check(false, "\(file.lastPathComponent): EditSession could not open it (or the sample download failed)")
        continue
    }
    let t1 = now()
    guard let source = session.makeSource(maxEdge: 1800, materialize: true) else {
        check(false, "\(stem): makeSource(maxEdge: 1800) returned nil")
        continue
    }
    opened += 1
    let t2 = now()
    print("\(stem): native \(session.nativeSize) preview \(source.size) open \(Int((t1 - t0) * 1000))ms source \(Int((t2 - t1) * 1000))ms air \(source.air) dn \(source.darkNorm)")

    func render(_ s: EditSettings, geometry: Bool = true, overlay: Mask? = nil) -> CGImage? {
        session.prepareAutoMasks(s, source: source)
        var img = session.develop(s, source: source, geometry: geometry)
        if let m = overlay { img = session.overlay(img, mask: m, source: source, gain: exp2(s.exposure)) }
        let out = img.transformed(by: CGAffineTransform(scaleX: 420 / img.extent.width, y: 420 / img.extent.width))
        return LumenGPU.context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace)
    }
    func timeIt(_ s: EditSettings) {
        let a = now()
        for _ in 0..<5 {
            let img = session.develop(s, source: source, geometry: true)
            let c = img.transformed(by: CGAffineTransform(scaleX: 0.7, y: 0.7))
            _ = LumenGPU.context.createCGImage(c, from: c.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace)
        }
        print("  render @1260px avg", Int((now() - a) / 5 * 1000), "ms")
    }

    var groups: [(String, [(String, EditSettings)])] = []
    groups.append(("tone", [
        ("default", EditSettings()),
        ("exp +1", edit { $0.exposure = 1 }),
        ("exp -1", edit { $0.exposure = -1 }),
        ("hl -100", edit { $0.highlights = -100 }),
        ("sh +100", edit { $0.shadows = 100 }),
        ("hl-100 sh+100", edit { $0.highlights = -100; $0.shadows = 100 }),
        ("contrast +60", edit { $0.contrast = 60 }),
        ("contrast -60", edit { $0.contrast = -60 }),
        ("whites +70", edit { $0.whites = 70 }),
        ("blacks -70", edit { $0.blacks = -70 }),
        ("blacks +70", edit { $0.blacks = 70 }),
        ("temp +50", edit { $0.temperature = 50 }),
    ]))
    groups.append(("color-detail", [
        ("temp -50", edit { $0.temperature = -50 }),
        ("tint +50", edit { $0.tint = 50 }),
        ("tint -50", edit { $0.tint = -50 }),
        ("vibrance +70", edit { $0.vibrance = 70 }),
        ("sat +50", edit { $0.saturation = 50 }),
        ("sat -100", edit { $0.saturation = -100 }),
        ("clarity +70", edit { $0.clarity = 70 }),
        ("texture +70", edit { $0.texture = 70 }),
        ("dehaze +60", edit { $0.dehaze = 60 }),
        ("dehaze -60", edit { $0.dehaze = -60 }),
        ("sharp 80", edit { $0.sharpness = 80 }),
        ("NR 80", edit { $0.noiseReduction = 80; $0.colorNoise = 60 }),
    ]))
    groups.append(("look", [
        ("vignette -60", edit { $0.vignette = -60 }),
        ("vignette +50", edit { $0.vignette = 50 }),
        ("grain 50", edit { $0.grain = 50 }),
        ("hsl blue hue+sat", edit { $0.hsl.bands[5].hue = 60; $0.hsl.bands[5].sat = 60 }),
        ("hsl green lum-", edit { $0.hsl.bands[3].lum = -70; $0.hsl.bands[3].sat = -40 }),
        ("grading teal/orange", edit {
            $0.grading.shadows = GradeZone(hue: 215, sat: 50, lum: 0)
            $0.grading.highlights = GradeZone(hue: 65, sat: 50, lum: 0)
        }),
        ("curve S", edit {
            $0.curves.master = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.18), CurvePoint(x: 0.75, y: 0.82), CurvePoint(x: 1, y: 1)]
        }),
        ("B&W", edit { $0.blackAndWhite = true; $0.contrast = 25 }),
        ("B&W blue dark", edit { $0.blackAndWhite = true; $0.hsl.bands[5].lum = -80; $0.hsl.bands[0].lum = 40 }),
        ("crop frame + 6deg", edit { $0.cropL = 0.1; $0.cropT = 0.15; $0.cropR = 0.85; $0.cropB = 0.7; $0.straighten = 6 }),
        ("rotate 90", edit { $0.quarterTurns = 1 }),
        ("everything", edit {
            $0.exposure = 0.3; $0.contrast = 25; $0.highlights = -40; $0.shadows = 30
            $0.vibrance = 30; $0.clarity = 20; $0.sharpness = 40; $0.vignette = -25
        }),
    ]))

    // Masks
    var linear = Mask.make(.linear); linear.adjust.exposure = -1.5
    var radial = Mask.make(.radial); radial.adjust.exposure = 1.2
    var lum = Mask.make(.luminance); lum.components[0].lumLow = 0; lum.components[0].lumHigh = 0.35; lum.adjust.exposure = 1.0
    var lumHi = Mask.make(.luminance); lumHi.components[0].lumLow = 0.7; lumHi.components[0].lumHigh = 1; lumHi.adjust.exposure = -1.0
    var subj = Mask.make(.subject); subj.adjust.exposure = 1.0; subj.adjust.saturation = 40
    var back = Mask.make(.background); back.adjust.exposure = -1.0; back.adjust.saturation = -60
    var sky = Mask.make(.sky); sky.adjust.exposure = -0.8; sky.adjust.saturation = 50; sky.adjust.dehaze = 40
    var colour = Mask.make(.color)
    let sampleRGB = source.stats.average(atNormalized: 0.5, 0.15)
    colour.components[0].samples = [ColorSample(r: Double(sampleRGB.x), g: Double(sampleRGB.y), b: Double(sampleRGB.z))]
    colour.adjust.saturation = 80; colour.adjust.exposure = -0.5
    var brush = Mask.make(.brush)
    brush.components[0].strokes = [BrushStroke(points: (0...20).map { Pt(x: 0.2 + 0.03 * Double($0), y: 0.5 + 0.1 * sin(Double($0) / 3)) },
                                               size: 0.09, erase: false)]
    brush.adjust.exposure = 1.5
    var combo = Mask.make(.linear)
    combo.components[0].y0 = 0.1; combo.components[0].y1 = 0.7
    combo.components.append(MaskComponent.make(.luminance, op: .intersect))
    combo.components[1].lumLow = 0.5; combo.components[1].lumHigh = 1
    combo.adjust.exposure = -1.2
    let maskCases: [(String, Mask)] = [
        ("linear -1.5", linear), ("radial +1.2", radial), ("lum dark +1", lum), ("lum bright -1", lumHi),
        ("subject", subj), ("background", back), ("sky", sky), ("colour", colour), ("brush", brush), ("linear x lum", combo),
    ]
    groups.append(("masks", maskCases.map { c in (c.0, edit { s in s.masks = [c.1] }) }))

    for (gname, cases) in groups {
        var items: [(String, CGImage)] = []
        for (label, s) in cases {
            let cg = render(s)
            check(cg != nil, "\(stem) \(gname) '\(label)': render returned nil")
            if let cg = cg { items.append((label, cg)) }
        }
        if let sh = sheet(items) { saveJPEG(sh, "\(stem)-\(gname).jpg") }
    }
    var ov: [(String, CGImage)] = []
    for (label, m) in maskCases {
        let s = edit { $0.masks = [m] }
        let cg = render(s, geometry: false, overlay: m)
        check(cg != nil, "\(stem) '\(label)' overlay: render returned nil")
        if let cg = cg { ov.append((label + " overlay", cg)) }
    }
    if let sh = sheet(ov) { saveJPEG(sh, "\(stem)-overlays.jpg") }

    // Identity: default settings must look like the unedited decode. The develop kernel clamps to 0...1 and rolls
    // off luminance above 0.85 (highlight shoulder), so the reference is clamped too and only mid-tones are held tight.
    do {
        let dev = session.develop(EditSettings(), source: source, geometry: true)
        check(abs(dev.extent.width - source.base.extent.width) <= 1 && abs(dev.extent.height - source.base.extent.height) <= 1,
              "\(stem) identity: default develop size \(dev.extent.size) differs from the source \(source.base.extent.size)")
        let ref = source.base.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        // Pixel comparison uses the un-cropped develop output: the geometry stage's integral crop rect can shift an
        // odd-sized picture by half a pixel, and 96 px point-sampled renders of a detailed photo then disagree wildly.
        let devPlain = session.develop(EditSettings(), source: source, geometry: false)
        if let a = smallRender(devPlain), let b = smallRender(ref), let d = compareImages(a, b) {
            print("  identity: mean |diff| all \(String(format: "%.2f", d.all)) mid-tones \(String(format: "%.2f", d.mid)) (\(d.midCount) px)")
            check(d.all < 6, "\(stem) identity: default settings differ from the source by \(d.all) levels on average (limit 6)")
            check(d.midCount == 0 || d.mid < 2, "\(stem) identity: default settings change mid-tones by \(d.mid) levels on average (limit 2)")
        } else {
            check(false, "\(stem) identity: could not render or read the default/unedited images")
        }
    }

    // Crop / rotate: output size follows the crop fractions; odd or inverted frames are clamped, never empty or crashing.
    do {
        let sw = Double(source.base.extent.width), sh = Double(source.base.extent.height)
        var c = EditSettings()
        c.cropL = 0.1; c.cropT = 0.2; c.cropR = 0.6; c.cropB = 0.7
        let e = session.develop(c, source: source, geometry: true).extent
        check(abs(Double(e.width) - 0.5 * sw) <= 2.5 && abs(Double(e.height) - 0.5 * sh) <= 2.5,
              "\(stem) crop: 0.1/0.2/0.6/0.7 frame of \(Int(sw))x\(Int(sh)) gave \(e.size), expected about \(0.5 * sw)x\(0.5 * sh)")
        let full = session.develop(c, source: source, geometry: true, applyCrop: false).extent
        check(abs(Double(full.width) - sw) <= 2.5 && abs(Double(full.height) - sh) <= 2.5,
              "\(stem) crop: applyCrop false should keep the whole picture, got \(full.size) for \(Int(sw))x\(Int(sh))")

        var q = EditSettings()
        q.quarterTurns = 1
        let eq = session.develop(q, source: source, geometry: true).extent
        check(abs(Double(eq.width) - sh) <= 2.5 && abs(Double(eq.height) - sw) <= 2.5,
              "\(stem) crop: one quarter turn of \(Int(sw))x\(Int(sh)) gave \(eq.size), expected the swapped size")
        q.quarterTurns = -3
        let eq2 = session.develop(q, source: source, geometry: true).extent
        check(abs(eq2.width - eq.width) <= 1 && abs(eq2.height - eq.height) <= 1,
              "\(stem) crop: quarterTurns -3 (\(eq2.size)) should equal +1 (\(eq.size))")

        var st = EditSettings()
        st.straighten = 10
        let es = session.develop(st, source: source, geometry: true).extent
        check(es.width > 0 && es.height > 0 && Double(es.width) <= sw + 1 && Double(es.height) <= sh + 1,
              "\(stem) crop: straighten 10 gave \(es.size), expected a non-empty picture inside \(Int(sw))x\(Int(sh))")
        if es.height > 0 {
            check(abs(Double(es.width / es.height) - sw / sh) < 0.05 * sw / sh,
                  "\(stem) crop: straighten changed the aspect ratio to \(es.width / es.height) from \(sw / sh)")
        }

        // Inverted, zero-size and out-of-range frames are clamped to a small positive frame.
        var odd: [(String, EditSettings)] = []
        var a = EditSettings(); a.cropL = 0.8; a.cropR = 0.2; a.cropT = 0.9; a.cropB = 0.1; odd.append(("inverted", a))
        var z = EditSettings(); z.cropL = 0.5; z.cropR = 0.5; z.cropT = 0.5; z.cropB = 0.5; odd.append(("zero-size", z))
        var o = EditSettings(); o.cropL = -1; o.cropT = -1; o.cropR = 2; o.cropB = 2; odd.append(("out-of-range", o))
        for (name, s) in odd {
            let ext = session.develop(s, source: source, geometry: true).extent
            check(ext.width > 0 && ext.height > 0 && ext.width.isFinite && ext.height.isFinite && Double(ext.width) <= sw + 1 && Double(ext.height) <= sh + 1,
                  "\(stem) crop: \(name) frame gave extent \(ext)")
            check(smallRender(session.develop(s, source: source, geometry: true)) != nil, "\(stem) crop: \(name) frame failed to render")
        }
    }

    // Exposure and contrast direction: +1 EV brightens and -1 EV darkens (mean luma); contrast +60 widens and
    // -60 narrows the luma spread (standard deviation) compared with default settings.
    do {
        func stats(_ s: EditSettings) -> (mean: Double, std: Double)? {
            guard let cg = smallRender(session.develop(s, source: source, geometry: true)) else { return nil }
            return lumaStats(cg)
        }
        if let d = stats(EditSettings()), let up = stats(edit { $0.exposure = 1 }), let down = stats(edit { $0.exposure = -1 }),
           let cHi = stats(edit { $0.contrast = 60 }), let cLo = stats(edit { $0.contrast = -60 }) {
            print("  tone: mean luma default \(String(format: "%.1f", d.mean)) exp+1 \(String(format: "%.1f", up.mean)) exp-1 \(String(format: "%.1f", down.mean));"
                  + " luma std default \(String(format: "%.1f", d.std)) contrast+60 \(String(format: "%.1f", cHi.std)) contrast-60 \(String(format: "%.1f", cLo.std))")
            check(up.mean > d.mean + 3, "\(stem) exposure +1: mean luma \(up.mean) is not clearly above default \(d.mean)")
            check(down.mean < d.mean - 3, "\(stem) exposure -1: mean luma \(down.mean) is not clearly below default \(d.mean)")
            check(cHi.std > d.std + 1, "\(stem) contrast +60: luma spread \(cHi.std) is not clearly above default \(d.std)")
            check(cLo.std < d.std - 1, "\(stem) contrast -60: luma spread \(cLo.std) is not clearly below default \(d.std)")
        } else {
            check(false, "\(stem) tone direction: could not render the exposure/contrast cases")
        }
    }

    // Black & white and saturation -100 give neutral pixels (R = G = B within a few levels); the colour source must
    // have clearly more colour than the B&W render, otherwise the check proves nothing.
    do {
        func spread(_ s: EditSettings) -> Double? {
            guard let cg = smallRender(session.develop(s, source: source, geometry: true)) else { return nil }
            return meanChannelSpread(cg)
        }
        if let d = spread(EditSettings()), let bw = spread(edit { $0.blackAndWhite = true }),
           let desat = spread(edit { $0.saturation = -100 }) {
            print("  mono: mean channel spread default \(String(format: "%.2f", d)) B&W \(String(format: "%.2f", bw)) saturation-100 \(String(format: "%.2f", desat))")
            check(bw < 3, "\(stem) B&W: mean R/G/B spread \(bw) levels is not neutral (limit 3)")
            check(desat < 4, "\(stem) saturation -100: mean R/G/B spread \(desat) levels is not neutral (limit 4)")
            if d > 6 {
                check(bw < d * 0.5, "\(stem) B&W: spread \(bw) is not clearly below the colour render's \(d)")
                check(desat < d * 0.5, "\(stem) saturation -100: spread \(desat) is not clearly below the colour render's \(d)")
            }
        } else {
            check(false, "\(stem) mono: could not render the B&W / saturation cases")
        }
    }

    // nativeSize is the picture as decoded (orientation applied): Heal measures spots with it
    if let full = session.decode(maxEdge: nil) {
        check(abs(full.extent.width - session.nativeSize.width) < 2 && abs(full.extent.height - session.nativeSize.height) < 2,
              "\(stem): nativeSize \(session.nativeSize) must match the decoded picture \(full.extent.size)")
    }

    // Preview source size: long edge at most 1800 px (never upscaled) and the aspect ratio of the native picture.
    do {
        let native = session.nativeSize
        let nl = Double(max(native.width, native.height)), sl = Double(max(source.size.width, source.size.height))
        check(sl <= 1800.5, "\(stem) preview source: long edge \(sl) exceeds 1800 px")
        check(sl <= nl + 1, "\(stem) preview source: long edge \(sl) is larger than the native \(nl)")
        check(sl >= min(nl, 1800) - 3, "\(stem) preview source: long edge \(sl) is much smaller than expected \(min(nl, 1800))")
        let na = Double(native.width / native.height), sa = Double(source.size.width / source.size.height)
        check(abs(na - sa) / na < 0.01, "\(stem) preview source: aspect \(sa) differs from native aspect \(na)")
    }

    // Grain: amount 50 changes the picture, and the grain pattern is deterministic (same settings twice = same bytes).
    do {
        func grainRender(_ s: EditSettings) -> CGImage? { smallRender(session.develop(s, source: source, geometry: true), width: 400) }
        if let g0 = grainRender(EditSettings()), let g1 = grainRender(edit { $0.grain = 50 }), let g2 = grainRender(edit { $0.grain = 50 }),
           let b1 = rgbaBytes(g1), let b2 = rgbaBytes(g2), let diff = compareImages(g1, g0) {
            print("  grain: mean |grain50 - grain0| \(String(format: "%.2f", diff.all)) levels; repeat identical \(b1 == b2)")
            check(diff.all > 0.2, "\(stem) grain 50: render is not different from grain 0 (mean diff \(diff.all))")
            check(b1 == b2, "\(stem) grain 50: two renders of the same settings differ (grain is not deterministic)")
        } else {
            check(false, "\(stem) grain: could not render the grain cases")
        }
    }

    // Tonal range sliders act on their own part of the histogram: whites up lifts the brightest 10%, blacks down
    // lowers the darkest 10%, highlights down lowers the brightest 10%. Skipped where the default is already clipped.
    do {
        func tails(_ s: EditSettings) -> (low: Double, high: Double)? {
            guard let cg = smallRender(session.develop(s, source: source, geometry: true)) else { return nil }
            return lumaTails(cg)
        }
        if let d = tails(EditSettings()), let w = tails(edit { $0.whites = 70 }), let b = tails(edit { $0.blacks = -70 }),
           let h = tails(edit { $0.highlights = -100 }) {
            print("  tails: low/high default \(String(format: "%.1f", d.low))/\(String(format: "%.1f", d.high)) whites+70 high \(String(format: "%.1f", w.high))"
                  + " blacks-70 low \(String(format: "%.1f", b.low)) highlights-100 high \(String(format: "%.1f", h.high))")
            if d.high < 240 { check(w.high > d.high + 1, "\(stem) whites +70: brightest 10% luma \(w.high) is not above default \(d.high)") }
            // Blacks only bites in deep shadows: with a bright darkest 10% (luma > 40) it must still not raise them.
            if d.low > 15 { check(b.low < d.low - (d.low < 40 ? 1 : 0.1), "\(stem) blacks -70: darkest 10% luma \(b.low) is not below default \(d.low)") }
            if d.high > 60 { check(h.high < d.high - 1, "\(stem) highlights -100: brightest 10% luma \(h.high) is not below default \(d.high)") }
        } else {
            check(false, "\(stem) tails: could not render the whites/blacks/highlights cases")
        }
    }

    // Mask maths: a mask plus its inverted copy sums to 1 everywhere, opacity scales the mask, a linear gradient is
    // monotonic along its axis, and subtract / intersect results stay inside 0...1 and below their first component.
    do {
        let gain = 1.0
        func mv(_ m: Mask) -> (v: [Float], w: Int, h: Int)? {
            guard let img = session.maskImage(m, source: source, gain: gain) else { return nil }
            return maskValues(img)
        }
        var vertical = Mask.make(.linear)
        vertical.components[0].x0 = 0.5; vertical.components[0].y0 = 0.2
        vertical.components[0].x1 = 0.5; vertical.components[0].y1 = 0.8
        var lumRange = Mask.make(.luminance); lumRange.components[0].lumLow = 0.2; lumRange.components[0].lumHigh = 0.7
        var brushM = Mask.make(.brush)
        brushM.components[0].strokes = [BrushStroke(points: (0...10).map { Pt(x: 0.3 + 0.04 * Double($0), y: 0.5) }, size: 0.1, erase: false)]
        let sumCases: [(String, Mask)] = [("linear", vertical), ("radial", Mask.make(.radial)), ("luminance", lumRange), ("brush", brushM)]
        for (label, m) in sumCases {
            var inv = m; inv.invert = true
            guard let a = mv(m), let b = mv(inv), a.v.count == b.v.count, !a.v.isEmpty else {
                check(false, "\(stem) mask '\(label)': could not render the mask or its inverted copy"); continue
            }
            var worst: Float = 0
            for i in 0..<a.v.count { worst = max(worst, abs(a.v[i] + b.v[i] - 1)) }
            check(worst < 0.02, "\(stem) mask '\(label)' + inverted copy deviates from 1 by up to \(worst)")
            check(a.v.allSatisfy { $0 >= -0.001 && $0 <= 1.001 }, "\(stem) mask '\(label)' has values outside 0...1")
            var half = m; half.amount = 50
            if let h = mv(half), h.v.count == a.v.count {
                let mx = h.v.max() ?? 0, fullMax = a.v.max() ?? 0
                check(mx <= 0.51, "\(stem) mask '\(label)' at 50% opacity reaches \(mx) (limit 0.5)")
                if fullMax > 0.9 { check(mx > 0.45, "\(stem) mask '\(label)' at 50% opacity only reaches \(mx)") }
            } else {
                check(false, "\(stem) mask '\(label)': could not render the 50% opacity mask")
            }
        }
        // Linear gradient: constant along the axis' perpendicular, monotonic along it, spanning nearly 0 to 1.
        if let g = mv(vertical) {
            var rowMean = [Float](repeating: 0, count: g.h)
            var spreadAcross: Float = 0
            for y in 0..<g.h {
                let row = g.v[(y * g.w)..<((y + 1) * g.w)]
                rowMean[y] = row.reduce(0, +) / Float(g.w)
                spreadAcross = max(spreadAcross, (row.max() ?? 0) - (row.min() ?? 0))
            }
            let nonInc = zip(rowMean, rowMean.dropFirst()).allSatisfy { $1 <= $0 + 0.01 }
            let nonDec = zip(rowMean, rowMean.dropFirst()).allSatisfy { $1 >= $0 - 0.01 }
            check(nonInc || nonDec, "\(stem) linear mask is not monotonic along its axis: \(rowMean.map { String(format: "%.2f", $0) })")
            check(abs(rowMean[0] - rowMean[g.h - 1]) > 0.8, "\(stem) linear mask does not span 0...1 (ends \(rowMean[0]) and \(rowMean[g.h - 1]))")
            check(spreadAcross < 0.02, "\(stem) vertical linear mask varies by \(spreadAcross) along a row")
        } else {
            check(false, "\(stem) linear mask: could not render")
        }
        // Subtract / intersect.
        var radialC = MaskComponent.make(.radial)
        radialC.x1 = 0.4; radialC.y1 = 0.4
        var subC = radialC; subC.op = .subtract
        var interC = radialC; interC.op = .intersect
        var first = Mask.make(.linear)
        first.components[0] = vertical.components[0]
        var sub = first; sub.components.append(subC)
        var inter = first; inter.components.append(interC)
        var radialOnly = first; radialOnly.components = [radialC]
        if let f = mv(first), let sb = mv(sub), let it = mv(inter), let r = mv(radialOnly),
           f.v.count == sb.v.count, f.v.count == it.v.count, f.v.count == r.v.count {
            check(sb.v.allSatisfy { $0 >= -0.001 && $0 <= 1.001 } && it.v.allSatisfy { $0 >= -0.001 && $0 <= 1.001 },
                  "\(stem) subtract/intersect mask has values outside 0...1")
            var subOver: Float = 0, interOver: Float = 0
            for i in 0..<f.v.count {
                subOver = max(subOver, sb.v[i] - f.v[i])
                interOver = max(interOver, it.v[i] - min(f.v[i], r.v[i]))
            }
            check(subOver < 0.02, "\(stem) subtract mask exceeds its first component by \(subOver)")
            check(interOver < 0.02, "\(stem) intersect mask exceeds min(first, second) by \(interOver)")
            check(sb.v.reduce(0, +) < f.v.reduce(0, +), "\(stem) subtracting a radial mask did not reduce the mask area")
        } else {
            check(false, "\(stem) subtract/intersect: could not render the masks")
        }
    }

    // Extremes: every main slider at its minimum and maximum renders finite values (no NaN / Inf); apart from
    // exposure (which may legitimately go black or white) the frame must be neither all black nor all white.
    do {
        let sliders: [(String, WritableKeyPath<EditSettings, Double>, Double, Double)] = [
            ("exposure", \.exposure, -5, 5), ("contrast", \.contrast, -100, 100), ("highlights", \.highlights, -100, 100),
            ("shadows", \.shadows, -100, 100), ("whites", \.whites, -100, 100), ("blacks", \.blacks, -100, 100),
            ("temperature", \.temperature, -100, 100), ("tint", \.tint, -100, 100), ("vibrance", \.vibrance, -100, 100),
            ("saturation", \.saturation, -100, 100), ("texture", \.texture, -100, 100), ("clarity", \.clarity, -100, 100),
            ("dehaze", \.dehaze, -100, 100), ("vignette", \.vignette, -100, 100), ("grain", \.grain, 0, 100),
            ("sharpness", \.sharpness, 0, 100), ("noiseReduction", \.noiseReduction, 0, 100), ("colorNoise", \.colorNoise, 0, 100),
        ]
        for (name, kp, lo, hi) in sliders {
            for v in [lo, hi] {
                var s = EditSettings()
                s[keyPath: kp] = v
                let label = "\(stem) extreme \(name)=\(v)"
                guard let px = floatPixels(session.develop(s, source: source, geometry: true)) else {
                    check(false, "\(label): could not render"); continue
                }
                check(px.allSatisfy { $0.isFinite }, "\(label): output contains NaN or Inf")
                if name != "exposure" {
                    if let cg = smallRender(session.develop(s, source: source, geometry: true)), let st = lumaStats(cg) {
                        check(st.mean > 0.5 && st.mean < 254.5, "\(label): frame is all black or all white (mean luma \(st.mean))")
                    } else {
                        check(false, "\(label): could not render 8-bit frame")
                    }
                }
            }
        }
    }

    // Full-resolution export path (lazy graph, no materialised planes).
    do {
        let exportEdits = edit {
            $0.exposure = 0.3; $0.contrast = 25; $0.highlights = -40; $0.shadows = 30; $0.clarity = 25; $0.sharpness = 40
            $0.vignette = -20; $0.masks = [linear, radial]
        }
        let t = now()
        if let data = session.renderData(exportEdits, format: .jpeg, quality: 0.9) {
            print(" export full-res:", data.count / 1024, "KB in", Int((now() - t) * 1000), "ms")
            try? data.write(to: outDir.appendingPathComponent("\(stem)-export.jpg"))
        } else { check(false, "\(stem): full-resolution export (renderData .jpeg) returned nil") }
        // export options: long edge and JPEG quality
        func longEdge(_ d: Data) -> Int {
            guard let src = CGImageSourceCreateWithData(d as CFData, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return -1 }
            return max(p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
        if let small = session.renderData(exportEdits, format: .jpeg, quality: 0.9, maxEdge: 1080),
           let low = session.renderData(exportEdits, format: .jpeg, quality: 0.5, maxEdge: 1080),
           let high = session.renderData(exportEdits, format: .jpeg, quality: 0.98, maxEdge: 1080) {
            check(longEdge(small) == 1080, "\(stem): export at 1080 px long edge gave \(longEdge(small)) px")
            check(low.count < high.count, "\(stem): JPEG quality 50 (\(low.count / 1024) KB) should be smaller than 98 (\(high.count / 1024) KB)")
            print(" export 1080 px: q50 \(low.count / 1024) KB, q90 \(small.count / 1024) KB, q98 \(high.count / 1024) KB")
        } else { check(false, "\(stem): export with a size limit returned nil") }
    }
    print(" timing default:"); timeIt(EditSettings())
    print(" timing heavy:")
    timeIt(edit {
        $0.exposure = 0.3; $0.contrast = 25; $0.highlights = -40; $0.shadows = 30; $0.vibrance = 30
        $0.clarity = 20; $0.sharpness = 40; $0.vignette = -25
        $0.curves.master = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.45), CurvePoint(x: 1, y: 1)]
        $0.masks = [linear, radial]
    })
}

// ---- EditSettings JSON sidecar: round trip, and the library's old-sidecar migration (defaults + saved keys).
do {
    var rich = EditSettings()
    rich.exposure = 0.75; rich.contrast = -12.5; rich.temperature = 18; rich.blackAndWhite = true
    rich.vignette = -30; rich.grain = 20; rich.cropL = 0.1; rich.cropB = 0.9; rich.quarterTurns = 3; rich.straighten = -2.5
    rich.curves.master = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.4, y: 0.3), CurvePoint(x: 1, y: 1)]
    rich.hsl.bands[2].hue = 15; rich.hsl.bands[5].sat = -40
    rich.grading.shadows = GradeZone(hue: 220, sat: 30, lum: -5); rich.grading.blending = 70
    var mask = Mask.make(.linear)
    mask.adjust.exposure = 0.5; mask.amount = 80; mask.invert = true
    var brush = MaskComponent.make(.brush, op: .subtract)
    brush.strokes = [BrushStroke(points: [Pt(x: 0.1, y: 0.2), Pt(x: 0.3, y: 0.4)], size: 0.05, erase: false)]
    mask.components.append(brush)
    rich.masks = [mask]

    for (name, s) in [("default", EditSettings()), ("rich", rich)] {
        do {
            let data = try JSONEncoder().encode(s)
            let back = try JSONDecoder().decode(EditSettings.self, from: data)
            check(back == s, "settings JSON: \(name) settings changed after encode + decode")
        } catch { check(false, "settings JSON: \(name) round trip threw \(error)") }
    }

    // Same recipe as LibraryStore.settings(for:): lay an old sidecar's known keys over today's defaults.
    do {
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EditSettings())) as? [String: Any] ?? [:]
        check(!defaults.isEmpty, "settings JSON: default settings encoded to an empty object")
        var old: [String: Any] = ["exposure": 1.5, "contrast": 20, "someRemovedSlider": 7]
        old = old.filter { defaults[$0.key] != nil }
        check(old.count == 2, "settings JSON: unknown key was not filtered out")
        var merged = defaults
        for (k, v) in old { merged[k] = v }
        let d = try JSONSerialization.data(withJSONObject: merged)
        let s = try JSONDecoder().decode(EditSettings.self, from: d)
        check(s.exposure == 1.5 && s.contrast == 20, "settings JSON: partial sidecar lost its saved values (exposure \(s.exposure), contrast \(s.contrast))")
        check(s.saturation == 0 && s.cropR == 1 && s.cropB == 1 && s.masks.isEmpty && s.curves.isNeutral,
              "settings JSON: keys missing from a partial sidecar did not fall back to defaults")
    } catch { check(false, "settings JSON: partial sidecar migration threw \(error)") }

    // Garbage must fail to decode (the app then falls back to defaults) rather than crash.
    check((try? JSONDecoder().decode(EditSettings.self, from: Data("not json".utf8))) == nil, "settings JSON: garbage decoded as settings")
}

// ---- Tone curves: LUT maths and odd control-point lists must never crash or leave 0...1.
do {
    func lutOK(_ name: String, _ pts: [CurvePoint]) -> [Float] {
        let l = ToneCurves.lut(for: pts)
        check(l.count == 256, "curves: \(name) LUT has \(l.count) entries, expected 256")
        check(l.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "curves: \(name) LUT has a value that is NaN/Inf or outside 0...1")
        return l
    }
    let ident = lutOK("identity", ToneCurves.identity)
    let identErr = ident.enumerated().map { abs(Double($0.element) - Double($0.offset) / 255) }.max() ?? 1
    check(identErr < 0.002, "curves: identity LUT deviates from y = x by \(identErr)")

    let sortedPts = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.3, y: 0.2), CurvePoint(x: 0.7, y: 0.85), CurvePoint(x: 1, y: 1)]
    let shuffled = [sortedPts[2], sortedPts[0], sortedPts[3], sortedPts[1]]
    check(lutOK("sorted", sortedPts) == lutOK("unsorted", shuffled), "curves: unsorted control points give a different LUT than sorted ones")

    let up = lutOK("increasing", sortedPts)
    var monotone = true
    for i in 1..<up.count where up[i] < up[i - 1] - 1e-5 { monotone = false }
    check(monotone, "curves: LUT through increasing control points is not monotone")
    check(abs(up[0]) < 0.01 && abs(up[255] - 1) < 0.01, "curves: LUT ends are \(up[0]) and \(up[255]), expected ~0 and ~1")

    let lift = lutOK("lifted mid", [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.8), CurvePoint(x: 1, y: 1)])
    check(lift[128] > 0.7 && lift[128] > ident[128] + 0.1, "curves: lifting the midpoint to 0.8 gave LUT[128] = \(lift[128])")

    let inv = lutOK("inverted", [CurvePoint(x: 0, y: 1), CurvePoint(x: 1, y: 0)])
    check(inv[0] > 0.98 && inv[255] < 0.02, "curves: inverted curve ends are \(inv[0]) and \(inv[255])")

    let single = lutOK("single point", [CurvePoint(x: 0.5, y: 0.5)])
    let empty = lutOK("empty", [])
    check(single == ident && empty == ident, "curves: fewer than two points should fall back to the identity LUT")

    _ = lutOK("duplicate x", [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.2), CurvePoint(x: 0.5, y: 0.8), CurvePoint(x: 1, y: 1)])
    _ = lutOK("all same x", [CurvePoint(x: 0.4, y: 0.1), CurvePoint(x: 0.4, y: 0.9)])
    _ = lutOK("out of range", [CurvePoint(x: -0.5, y: -1), CurvePoint(x: 0.5, y: 2), CurvePoint(x: 1.5, y: 0.5)])

    // The baked colour cube must come out the same size whatever the curves are, and a neutral cube must differ from a curved one.
    let dimN = ColorCube.dim
    let neutralCube = ColorCube.make(curves: ToneCurves(), hsl: HSLSettings(), grading: ColorGrading(), blackAndWhite: false)
    var odd = ToneCurves()
    odd.master = [CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 0.5, y: 0.9), CurvePoint(x: 0, y: 0)]
    odd.red = []
    odd.blue = [CurvePoint(x: 0, y: 1), CurvePoint(x: 1, y: 0)]
    let oddCube = ColorCube.make(curves: odd, hsl: HSLSettings(), grading: ColorGrading(), blackAndWhite: false)
    check(neutralCube.count == dimN * dimN * dimN * 16, "curves: neutral cube is \(neutralCube.count) bytes, expected \(dimN * dimN * dimN * 16)")
    check(oddCube.count == neutralCube.count, "curves: odd-curve cube size \(oddCube.count) differs from neutral \(neutralCube.count)")
    check(oddCube != neutralCube, "curves: an inverted blue curve left the baked cube unchanged")
}


// ======================================================================================
// HDR CHECKS (night/hdr). Kept in its own function at the end of the file.
// ======================================================================================
func runHDRChecks() {
    print("== HDR checks ==")
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        if ok { print("HDR OK: \(what)") } else { print("FAIL: HDR \(what)"); failures += 1 }
    }
    let hdrFiles = ((try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)) ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard let first = hdrFiles.first else { print("FAIL: HDR no input photos"); return }
    let arw = hdrFiles.first { $0.pathExtension.lowercased() == "arw" } ?? first
    let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    struct Pixels { var w = 0, h = 0, f: [Float] = [] }
    func pixels(_ img: CIImage) -> Pixels {
        // No downscaling: averaging boosted highlights into neighbouring mid-tones would break check 3b by construction.
        let scale = min(1, 1800 / max(img.extent.width, 1))
        let sm = scale < 1 ? img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : img
        let r = sm.extent.integral
        let w = Int(r.width), h = Int(r.height)
        var buf = [Float](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            LumenGPU.context.render(sm, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: linearSpace)
        }
        return Pixels(w: w, h: h, f: buf)
    }
    func lum(_ p: Pixels, _ i: Int) -> Float { 0.2126 * p.f[i * 4] + 0.7152 * p.f[i * 4 + 1] + 0.0722 * p.f[i * 4 + 2] }
    func maxDiff(_ a: Pixels, _ b: Pixels) -> Float {
        guard a.f.count == b.f.count else { return .infinity }
        var m: Float = 0
        for i in 0..<a.f.count { m = max(m, abs(a.f[i] - b.f[i])) }
        return m
    }

    func checks(_ file: URL, tag: String, exposure: Double, rangeChecks: Bool) -> (CGImage, CGImage)? {
        guard let session = EditSession(url: file), let source = session.makeSource(maxEdge: 1800, materialize: true) else {
            print("FAIL: HDR cannot open \(file.lastPathComponent)"); failures += 1; return nil
        }
        var off = EditSettings(); off.exposure = exposure
        var on = off; on.hdr = true
        session.prepareAutoMasks(off, source: source)
        let stops = on.hdrStops

        let base = pixels(session.develop(off, source: source, geometry: true))
        // 1. hdr = false is unchanged, whatever weight is passed.
        let offW1 = pixels(session.develop(off, source: source, geometry: true, hdrWeight: 1))
        check(maxDiff(base, offW1) == 0, "\(tag) 1: hdr off identical (diff \(maxDiff(base, offW1)))")
        // 2. hdr = true with weight 0 equals hdr = false.
        let onW0 = pixels(session.develop(on, source: source, geometry: true, hdrWeight: 0))
        check(maxDiff(base, onW0) == 0, "\(tag) 2: hdr on, weight 0 identical (diff \(maxDiff(base, onW0)))")
        // 3. weight 1: never darker; unchanged where SDR luminance is below 0.8.
        let w1 = pixels(session.develop(on, source: source, geometry: true, hdrWeight: 1))
        var darker: Float = 0, midDiff: Float = 0, maxL: Float = 0, brighter = 0
        if w1.f.count == base.f.count {
            for i in 0..<(base.w * base.h) {
                let ls = lum(base, i), lh = lum(w1, i)
                darker = max(darker, ls - lh)
                if ls < 0.8 { for c in 0..<3 { midDiff = max(midDiff, abs(w1.f[i * 4 + c] - base.f[i * 4 + c])) } }
                if lh > ls + 0.01 { brighter += 1 }
                maxL = max(maxL, lh)
            }
        } else { darker = .infinity; midDiff = .infinity }
        check(darker <= 1e-4, "\(tag) 3a: HDR >= SDR (worst shortfall \(darker))")
        check(midDiff <= 1e-3, "\(tag) 3b: SDR luminance < 0.8 unchanged (worst diff \(midDiff))")
        print("HDR info: \(tag) max HDR luminance \(maxL), pixels brighter than SDR: \(brighter)")
        // 4. Range of the brightest pixel (RAW with exposure +1).
        if rangeChecks {
            check(maxL > 1.2, "\(tag) 4a: max HDR luminance > 1.2 (is \(maxL))")
            check(maxL <= Float(exp2(stops)) + 0.05, "\(tag) 4b: max HDR luminance <= 2^stops (is \(maxL))")
        }
        // 5. weight 0.5 lies between weight 0 and weight 1.
        let half = pixels(session.develop(on, source: source, geometry: true, hdrWeight: 0.5))
        var bad = 0
        if half.f.count == base.f.count {
            for i in 0..<(base.w * base.h) {
                let a = lum(base, i), b = lum(w1, i), h = lum(half, i)
                if h < a - 1e-3 || h > b + 1e-3 { bad += 1 }
            }
        } else { bad = -1 }
        check(bad == 0, "\(tag) 5: weight 0.5 between 0 and 1 (violations \(bad))")

        // Contact sheet images: SDR, HDR, and HDR/H (HDR scaled down so highlights are visible).
        func cg(_ img: CIImage, scale: Double = 1) -> CGImage? {
            var im = img
            if scale != 1 { im = im.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0)]) }
            let f = 420 / im.extent.width
            let o = im.transformed(by: CGAffineTransform(scaleX: f, y: f))
            return LumenGPU.context.createCGImage(o, from: o.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace)
        }
        let sdrImg = session.develop(on, source: source, geometry: true, hdrWeight: 0)
        let hdrImg = session.develop(on, source: source, geometry: true, hdrWeight: 1)
        if let a = cg(sdrImg), let b = cg(hdrImg), let c = cg(hdrImg, scale: 1 / exp2(stops)) {
            if let sh = sheet([("SDR", a), ("HDR (clipped on SDR screen)", b), ("HDR / H (for viewing)", c)]) {
                saveJPEG(sh, "hdr-\(tag).jpg")
            }
            return (a, b)
        }
        return nil
    }

    _ = checks(arw, tag: "arw-exp+1", exposure: 1, rangeChecks: true)
    if first != arw { _ = checks(first, tag: "\(first.deletingPathExtension().lastPathComponent)-exp+1", exposure: 1, rangeChecks: false) }
    // 6. Gain-map HEIC export is larger than the SDR-only HEIC (needs macOS 15 Core Image).
    if #available(macOS 15.0, *), let session = EditSession(url: arw) {
        var off = EditSettings(); off.exposure = 1
        var on = off; on.hdr = true
        if let a = session.renderData(off, format: .heic, quality: 0.9), let b = session.renderData(on, format: .heic, quality: 0.9) {
            check(b.count > a.count, "6: gain-map HEIC (\(b.count / 1024) KB) larger than SDR HEIC (\(a.count / 1024) KB)")
        } else { check(false, "6: HEIC export returned nil") }
    } else { print("HDR skip: 6 (needs macOS 15)") }
    // 7. HDR mode decodes the RAW with more highlight range (extended dynamic range 2 instead of 1).
    if let sdrSession = EditSession(url: arw), let hdrSession = EditSession(url: arw, expandHDR: true),
       let a = sdrSession.makeSource(maxEdge: 1200, materialize: true),
       let b = hdrSession.makeSource(maxEdge: 1200, materialize: true) {
        func top(_ img: CIImage) -> Float { var m: Float = 0; let p = pixels(img); for i in 0..<(p.w * p.h) { m = max(m, lum(p, i)) }; return m }
        let ma = top(a.base), mb = top(b.base)
        check(mb > ma * 1.04, String(format: "7: HDR decode reaches higher above white (%.3f vs %.3f)", mb, ma))
    } else { check(false, "7: cannot open \(arw.lastPathComponent) twice") }
    // 8. HDR histogram: an overexposed RAW fills the HDR zone; the SDR rendition puts nothing there.
    if let session = EditSession(url: arw, expandHDR: true), let source = session.makeSource(maxEdge: 1200, materialize: true) {
        var s = EditSettings(); s.exposure = 1.5; s.hdr = true
        let hdrImg = session.develop(s, source: source, geometry: true, hdrWeight: 1)
        let sdrImg = session.develop(s, source: source, geometry: true)
        let ctxImg = { (img: CIImage) -> CGImage? in
            let k = 160 / max(img.extent.width, img.extent.height)
            let sm = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
            return LumenGPU.context.createCGImage(sm, from: sm.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        if let cg = ctxImg(sdrImg), var h = Histogram.compute(cg) {
            Histogram.addHDR(&h, hdrImg, stops: s.hdrStops, screenStops: 1)
            let zoneStart = Int(Float(Histogram.bins) * Histogram.sdrFraction) + 1
            let zone = h.r[zoneStart...].reduce(0, +) + h.g[zoneStart...].reduce(0, +) + h.b[zoneStart...].reduce(0, +)
            check(h.sdrFraction != nil && zone > 0.05 && h.hdrPeakStops > 0.3,
                  String(format: "8a: HDR histogram zone filled (zone %.2f, peak +%.2f stops, %.1f%% above white)",
                         zone, h.hdrPeakStops, h.hdrShare * 100))
            var plain = h
            Histogram.addHDR(&plain, sdrImg, stops: s.hdrStops, screenStops: 1)
            let zone2 = plain.r[zoneStart...].reduce(0, +) + plain.g[zoneStart...].reduce(0, +) + plain.b[zoneStart...].reduce(0, +)
            check(zone2 < 0.001 && plain.hdrPeakStops < 0.05,
                  String(format: "8b: SDR rendition leaves the HDR zone empty (zone %.3f, peak +%.2f)", zone2, plain.hdrPeakStops))
        } else { check(false, "8: histogram could not be computed") }
    } else { check(false, "8: cannot open \(arw.lastPathComponent)") }
    print(failures == 0 ? "HDR checks: all passed" : "HDR checks: \(failures) FAILED")
    if failures > 0 { exit(1) }
}
/// Highlight statistics for the RAW (printed only): how far above SDR white the decoded data goes, how much of the SDR
/// rendition ends up stuck at white, and how bright the HDR rendition gets. Used to tune the highlight shoulder.
func printHighlightStats() {
    print("== Highlight stats ==")
    let files = ((try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)) ?? [])
    guard let arw = files.first(where: { $0.pathExtension.lowercased() == "arw" }) else { print("stats: no ARW"); return }
    let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    func lums(_ img: CIImage) -> [Float] {
        let k = min(1, 900 / max(img.extent.width, img.extent.height))
        let sm = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let r = sm.extent.integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 0, h > 0 else { return [] }
        var buf = [Float](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            LumenGPU.context.render(sm, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: space)
        }
        var out = [Float](); out.reserveCapacity(w * h)
        for i in stride(from: 0, to: buf.count, by: 4) { out.append(0.2126 * buf[i] + 0.7152 * buf[i + 1] + 0.0722 * buf[i + 2]) }
        return out.sorted()
    }
    func describe(_ tag: String, _ l: [Float]) {
        guard !l.isEmpty else { print("stats \(tag): empty"); return }
        func q(_ p: Double) -> Float { l[min(l.count - 1, Int(Double(l.count) * p))] }
        let over1 = Float(l.filter { $0 > 1.0 }.count) / Float(l.count)
        let nearWhite = Float(l.filter { $0 > 0.95 }.count) / Float(l.count)
        print(String(format: "stats %@: p50 %.3f p90 %.3f p99 %.3f p99.9 %.3f max %.3f  >1: %.2f%%  >0.95: %.2f%%",
                     tag, q(0.5), q(0.9), q(0.99), q(0.999), l.last!, over1 * 100, nearWhite * 100))
    }
    for amount: Float in [0, 1, 2] {
        if let f = CIRAWFilter(imageURL: arw) {
            f.extendedDynamicRangeAmount = amount
            f.scaleFactor = 0.3
            if let o = f.outputImage { describe("raw EDR \(amount)", lums(o)) }
        }
    }
    guard let session = EditSession(url: arw), let source = session.makeSource(maxEdge: 1800, materialize: true) else {
        print("stats: cannot open"); return
    }
    describe("source base", lums(source.base))
    for ev in [0.0, 1.5] {
        var s = EditSettings(); s.exposure = ev
        describe(String(format: "SDR ev %+.1f", ev), lums(session.develop(s, source: source, geometry: true)))
        var h = s; h.hdr = true
        describe(String(format: "HDR ev %+.1f", ev), lums(session.develop(h, source: source, geometry: true, hdrWeight: 1)))
        var r = s; r.highlights = -100; r.whites = -50
        describe(String(format: "SDR ev %+.1f hl-100 wh-50", ev), lums(session.develop(r, source: source, geometry: true)))
    }
}
printHighlightStats()
runHDRChecks()

// Background mask when no subject was found: the whole photo (it used to select nothing at all)
do {
    if let f = files.first(where: { $0.pathExtension.lowercased() != "arw" }) ?? files.first,
       let session = EditSession(url: f), let source = session.makeSource(maxEdge: 600, materialize: true) {
        source.storeMask(EditSession.aiSubject, nil)   // looked, found nothing
        let comp = Mask.make(.background).components[0]
        let m = session.componentImage(comp, source: source, gain: 1)
        let avg = m.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: m.extent)])
        var px = [Float](repeating: 0, count: 4)
        LumenGPU.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                format: .RGBAf, colorSpace: nil)
        check(px[0] > 0.98, "background mask with no subject should cover the whole photo (mean \(px[0]))")
    } else { check(false, "background mask check: no photo could be opened") }
}

// Mask handles are drawn through SourceGeometry: it must put a source point exactly where EditSession.geometry renders it
do {
    if let f = files.first(where: { $0.pathExtension.lowercased() != "arw" }) ?? files.first, let session = EditSession(url: f) {
        let W: CGFloat = 600, H: CGFloat = 400
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        // (turns, straighten, flipH, flipV, vertical, horizontal, aspect, scale, offX, offY)
        let cases: [(Int, Double, Bool, Bool, Double, Double, Double, Double, Double, Double)] = [
            (0, 0, false, false, 0, 0, 0, 100, 0, 0), (1, 7, false, false, 0, 0, 0, 100, 0, 0),
            (3, -12, false, false, 0, 0, 0, 100, 0, 0), (2, 4, false, false, 0, 0, 0, 100, 0, 0),
            (0, 0, true, false, 0, 0, 0, 100, 0, 0), (1, 5, false, true, 0, 0, 0, 100, 0, 0),
            (0, 0, false, false, 40, 0, 0, 100, 0, 0), (0, 3, false, false, 0, -35, 0, 100, 0, 0),
            (0, 0, false, false, 0, 0, 50, 100, 0, 0), (0, 0, false, false, 0, 0, -40, 120, 10, -15),
            (1, -6, true, false, 25, 20, 30, 90, -10, 5),
        ]
        for (turns, angle, fh, fv, tv, th, ta, ts, tx, ty) in cases {
            var s = EditSettings()
            s.quarterTurns = turns; s.straighten = angle
            s.flipH = fh; s.flipV = fv; s.tVertical = tv; s.tHorizontal = th; s.tAspect = ta; s.tScale = ts
            s.tOffX = tx; s.tOffY = ty
            s.cropL = 0.1; s.cropT = 0.15; s.cropR = 0.8; s.cropB = 0.9
            let geo = SourceGeometry(source: CGSize(width: W, height: H), settings: s)
            let real = session.geometry(black, s).extent.size
            check(abs(geo.output.width - real.width) < 2 && abs(geo.output.height - real.height) < 2,
                  "SourceGeometry output size \(geo.output) vs rendered \(real) (turns \(turns), straighten \(angle))")
            var worst = 0.0
            for p in [Pt(x: 0.5, y: 0.5), Pt(x: 0.38, y: 0.42), Pt(x: 0.6, y: 0.62)] {
                // a small white square at p (source, y down)
                let cx = CGFloat(p.x) * W, cy = (1 - CGFloat(p.y)) * H
                let dot = CIImage(color: .white).cropped(to: CGRect(x: cx - 5, y: cy - 5, width: 10, height: 10)).composited(over: black)
                let out = session.geometry(dot, s)
                let o = geo.toOutput(p)
                let ox = out.extent.minX + CGFloat(o.x) * out.extent.width, oy = out.extent.minY + (1 - CGFloat(o.y)) * out.extent.height
                let box = CGRect(x: ox - 2, y: oy - 2, width: 4, height: 4)
                let avg = out.cropped(to: box).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: box)])
                var px = [Float](repeating: 0, count: 4)
                LumenGPU.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: avg.extent, format: .RGBAf, colorSpace: nil)
                check(px[0] > 0.6, "SourceGeometry puts source point (\(p.x), \(p.y)) where the rendered photo has it (turns \(turns), straighten \(angle), flip \(fh)/\(fv), transform \(tv) \(th) \(ta) \(ts) \(tx) \(ty): brightness \(px[0]))")
                let back = geo.toSource(o)
                worst = max(worst, abs(back.x - p.x), abs(back.y - p.y))
            }
            check(worst < 1e-6, "SourceGeometry round trip (turns \(turns), worst \(worst))")
        }
    } else { check(false, "SourceGeometry check: no photo could be opened") }
}

// UI refresh (2026-10-10): a switched-off tool renders as untouched; brush strokes keep their own softness
do {
    if let f = files.first(where: { $0.pathExtension.lowercased() != "arw" }) ?? files.first, let session = EditSession(url: f),
       let source = session.makeSource(maxEdge: 900, materialize: true) {
        var on = EditSettings(); on.exposure = 1.2; on.contrast = 40
        var off = on; off.setOn(.light, false)
        check(off.exposure == 1.2 && off.effective.exposure == 0, "switching Light off keeps its values but does not apply them")
        check(on.hasEdits(.light) && !on.hasEdits(.grade), "hasEdits should see Light edits and no Grade edits")
        var back = off; back.setOn(.light, true)
        check(back.effective.exposure == 1.2, "switching Light back on applies it again")
        if let a = smallRender(session.develop(off, source: source, geometry: true)),
           let b = smallRender(session.develop(EditSettings(), source: source, geometry: true)),
           let c = smallRender(session.develop(on, source: source, geometry: true)),
           let ab = compareImages(a, b), let ac = compareImages(a, c) {
            check(ab.all < 0.5, "Light switched off should render like no Light edits (mean difference \(ab.all))")
            check(ac.all > 2, "Light switched off should look different from Light on (mean difference \(ac.all))")
        } else { check(false, "edit sections: a render failed") }

        // two strokes, one hard (feather 0) on the left and one soft (feather 100) on the right
        func row(_ comp: MaskComponent) -> [Float]? {
            let m = Mask(name: "b", components: [comp])
            guard let img = session.maskImage(m, source: source, gain: 1), let mv = maskValues(img, width: 300) else { return nil }
            let y = mv.h / 2
            return Array(mv.v[(y * mv.w)..<((y + 1) * mv.w)])
        }
        var comp = MaskComponent.make(.brush)
        comp.feather = 50
        comp.strokes = [BrushStroke(points: [Pt(x: 0.15, y: 0.5), Pt(x: 0.3, y: 0.5)], size: 0.06, erase: false, feather: 0),
                        BrushStroke(points: [Pt(x: 0.65, y: 0.5), Pt(x: 0.8, y: 0.5)], size: 0.06, erase: false, feather: 100)]
        if let r = row(comp) {
            let half = r.count / 2
            let soft = { (vals: ArraySlice<Float>) in vals.filter { $0 > 0.08 && $0 < 0.92 }.count }
            let hardEdge = soft(r[0..<half]), softEdge = soft(r[half...])
            check(softEdge > hardEdge + 3, "a stroke painted with Feather 100 should have a softer edge than one painted with 0 (\(softEdge) vs \(hardEdge) partly-covered pixels)")
            check((r[0..<half].max() ?? 0) > 0.9, "the hard stroke should be fully painted (max \(r[0..<half].max() ?? 0))")
        } else { check(false, "brush feather: mask render failed") }

        // paint (soft), then erase the middle with a different softness: the erased part must be gone
        var comp2 = MaskComponent.make(.brush)
        comp2.strokes = [BrushStroke(points: [Pt(x: 0.1, y: 0.5), Pt(x: 0.9, y: 0.5)], size: 0.1, erase: false, feather: 30),
                         BrushStroke(points: [Pt(x: 0.45, y: 0.5), Pt(x: 0.55, y: 0.5)], size: 0.12, erase: true, feather: 0)]
        if let r = row(comp2) {
            let n = r.count
            check(r[n / 2] < 0.1, "erasing with a different Feather should still remove the paint (centre \(r[n / 2]))")
            check(r[n / 4] > 0.85, "paint away from the eraser should stay (quarter \(r[n / 4]))")
        } else { check(false, "brush erase: mask render failed") }
    } else { check(false, "UI refresh checks: no photo could be opened") }
}

// Auto (15 Oct 2026): every value from the photo, subject metering, scene key, HDR, edge cases
do {
    func grid(_ w: Int = 32, _ h: Int = 24, _ f: (Int, Int) -> SIMD3<Float>) -> PixelGrid {
        var d = [Float](); d.reserveCapacity(w * h * 4)
        for y in 0..<h { for x in 0..<w { let c = f(x, y); d += [c.x, c.y, c.z, 1] } }
        return PixelGrid(width: w, height: h, data: d)
    }
    func grey(_ v: Float) -> SIMD3<Float> { SIMD3(v, v, v) }
    let base = EditSettings()
    func auto(_ g: PixelGrid, subject: [Float]? = nil, hdr: Bool = false) -> EditSettings {
        var s = base; s.hdr = hdr; return EditSession.autoSettings(grid: g, subject: subject, current: s)
    }
    func finite(_ s: EditSettings) -> Bool { EditSession.autoKeys.allSatisfy { s[keyPath: $0].isFinite } }
    // flat (foggy) vs contrasty: contrast must differ, not a fixed +12
    let flat = auto(grid { x, _ in grey(0.14 + Float(x % 4) * 0.01) })
    let punchy = auto(grid { x, _ in grey(x % 2 == 0 ? 0.004 : 0.8) })
    check(flat.contrast > punchy.contrast + 10, "Auto contrast must follow the photo (flat \(flat.contrast), punchy \(punchy.contrast))")
    // colour: muted gets vibrance, already colourful and black-and-white get none
    let muted = auto(grid { _, _ in SIMD3(0.2, 0.18, 0.16) })
    let vivid = auto(grid { _, _ in SIMD3(0.4, 0.06, 0.04) })
    let mono = auto(grid { x, _ in grey(0.05 + Float(x) * 0.01) })
    check(muted.vibrance > 10 && vivid.vibrance == 0 && mono.vibrance == 0,
          "Auto vibrance must follow the colour (muted \(muted.vibrance), vivid \(vivid.vibrance), grey \(mono.vibrance))")
    check(base.clarity == mono.clarity, "Auto must not add Clarity to every photo")
    // scene key: bright unclipped snow stays bright; dark scene with lights stays dark
    let snow = auto(grid { x, y in grey(0.6 + Float((x + y) % 6) * 0.05) })
    check(snow.exposure > -0.8, "Auto darkened a high-key scene too much: \(snow.exposure)")
    let night = auto(grid { x, y in grey(x < 2 && y < 2 ? 0.95 : 0.01) })
    check(night.exposure <= 1.0, "Auto brightened a night scene with lights too much: \(night.exposure)")
    // subject metering: a dark subject in a bright frame is exposed brighter than the frame alone suggests
    // (subject off-centre, so centre weighting alone would meter the bright surroundings)
    let backlit = grid { x, _ in grey(x < 12 ? 0.03 : 0.45) }
    let subject = (0..<(32 * 24)).map { i -> Float in i % 32 < 12 ? 1 : 0 }
    check(auto(backlit, subject: subject).exposure > auto(backlit).exposure + 0.3, "Auto ignored the subject")
    let speck = (0..<(32 * 24)).map { $0 == 5 ? Float(1) : 0 }
    check(auto(backlit, subject: speck).exposure == auto(backlit).exposure, "A tiny subject must fall back to centre metering")
    // HDR: highlights the HDR range can show are left alone
    let bright = grid { x, _ in grey(x < 8 ? 2.2 : 0.16) }
    check(auto(bright, hdr: true).highlights > auto(bright).highlights + 30,
          "Auto pulled HDR highlights down like SDR (\(auto(bright, hdr: true).highlights) vs \(auto(bright).highlights))")
    // edge cases: black, white, tiny, broken
    let black = auto(grid { _, _ in grey(0.00002) })
    check(finite(black) && black.exposure <= 1.5, "Auto on a black frame: \(black.exposure)")
    let white = auto(grid { _, _ in grey(1) })
    check(finite(white) && white.exposure <= 0 && white.exposure >= -2, "Auto on a white frame: \(white.exposure)")
    check(auto(grid(2, 2) { _, _ in grey(0.3) }) == base, "Auto must leave a photo with too few stats unchanged")
    check(auto(grid { _, _ in grey(.nan) }) == base, "Auto must leave a photo with broken stats unchanged")
    // white balance: a blue cast is warmed, a warm cast cooled, neutral left alone; a frame full of one colour,
    // a sunset and black-and-white keep their white balance
    func varied(_ c: SIMD3<Float>) -> PixelGrid { grid { x, y in c * (0.6 + Float((x * 7 + y * 3) % 9) * 0.1) } }
    let blueCast = auto(varied(SIMD3(0.11, 0.12, 0.15)))
    let warmCast = auto(varied(SIMD3(0.15, 0.12, 0.11)))
    let neutral = auto(varied(SIMD3(0.12, 0.12, 0.12)))
    check(blueCast.temperature > 5 && warmCast.temperature < -5 && abs(neutral.temperature) < 3 && abs(neutral.tint) < 3,
          "Auto white balance (blue \(blueCast.temperature), warm \(warmCast.temperature), neutral \(neutral.temperature)/\(neutral.tint))")
    check(auto(varied(SIMD3(0.30, 0.03, 0.03))).temperature == 0, "One colour filling the frame must keep its white balance")
    check(auto(varied(SIMD3(0.8, 0.4, 0.1))).temperature == 0, "A sunset must keep its warmth")
    var bwBase = base; bwBase.blackAndWhite = true
    check(EditSession.autoSettings(grid: varied(SIMD3(0.11, 0.12, 0.15)), subject: nil, current: bwBase).temperature == 0,
          "Black-and-white photos keep their white balance")
    check(abs(blueCast.temperature) <= 30 && abs(blueCast.tint) <= 20, "Auto white balance must stay within its limits")
    let mixed = auto(grid { x, _ in x == 0 ? grey(.infinity) : grey(0.1) })
    check(finite(mixed), "Auto must skip non-finite cells")
}

// Pro pack (2026-10-11): auto-level, global grading wheel, preset strength, paste some edits, clipping kernel
do {
    if let f = files.first(where: { $0.pathExtension.lowercased() != "arw" }) ?? files.first, let session = EditSession(url: f),
       let source = session.makeSource(maxEdge: 900, materialize: true) {
        // a synthetic horizon tilted 8° anticlockwise: auto-level must find it, and straightening by it must level it
        let W: CGFloat = 900, H: CGFloat = 600
        let sky = CIImage(color: CIColor(red: 0.55, green: 0.7, blue: 0.95)).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        let ground = CIImage(color: CIColor(red: 0.15, green: 0.12, blue: 0.08))
            .cropped(to: CGRect(x: -W, y: -H * 2, width: W * 3, height: H * 2.5))
            .transformed(by: CGAffineTransform(translationX: -W / 2, y: -H / 2)
                .concatenating(CGAffineTransform(rotationAngle: 8 * .pi / 180))
                .concatenating(CGAffineTransform(translationX: W / 2, y: H / 2)))
        let scene = ground.composited(over: sky).cropped(to: sky.extent)
        func levelCheck(_ name: String, _ img: CIImage, tilt: Double) {
            guard let a = session.levelAngle(of: img) else { check(false, "auto-level found nothing in the \(name) scene"); return }
            check(abs(abs(a) - tilt) < 1.5, "auto-level should find the \(tilt)° tilt of the \(name) scene (got \(a)°)")
            var s = EditSettings(); s.straighten = a
            let levelled = session.geometry(img, s)
            let b = session.levelAngle(of: levelled) ?? 0
            check(abs(b) < 1.2, "straightening the \(name) scene by the auto-level angle should level it (still \(b)°, applied \(a)°)")
        }
        levelCheck("horizon", scene, tilt: 8)
        // no horizon: a 'building' of vertical and horizontal bars, turned 6° clockwise
        var bars = CIImage(color: CIColor(red: 0.85, green: 0.85, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        for i in 0..<9 {
            let x = CGFloat(i) * 110 + 30
            bars = CIImage(color: CIColor(red: 0.2, green: 0.22, blue: 0.25)).cropped(to: CGRect(x: x, y: -200, width: 26, height: H + 400)).composited(over: bars)
        }
        for j in 0..<4 {
            let y = CGFloat(j) * 160 + 40
            bars = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.32)).cropped(to: CGRect(x: -200, y: y, width: W + 400, height: 14)).composited(over: bars)
        }
        let building = bars.transformed(by: CGAffineTransform(translationX: -W / 2, y: -H / 2)
            .concatenating(CGAffineTransform(rotationAngle: -6 * .pi / 180))
            .concatenating(CGAffineTransform(translationX: W / 2, y: H / 2)))
            .composited(over: CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        levelCheck("building", building, tilt: 6)
        // the edge method on its own (photos with no horizon use it): same scene, must also level it
        if let e = session.edgeLevel(of: building) {
            check(abs(e + 6) < 1.5, "edge levelling should turn the 6° clockwise 'building' back by about -6 (got \(e))")
        } else { check(false, "edge levelling found nothing in the building scene") }
        // a level photo stays (nearly) level
        let flat = bars.composited(over: CIImage(color: .gray)).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        if let z = session.levelAngle(of: flat) { check(abs(z) < 0.6, "a level photo should need no turn (got \(z)°)") }

        // Fill frame: after a strong transform no empty (black) corner may show; with it off, corners are empty
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        func cornerAlpha(_ s: EditSettings) -> Float {
            let out = session.geometry(white, s)
            let e = out.extent
            var worst: Float = 1
            for (x, y) in [(e.minX + 2, e.minY + 2), (e.maxX - 3, e.minY + 2), (e.minX + 2, e.maxY - 3), (e.maxX - 3, e.maxY - 3)] {
                var v = [Float](repeating: 0, count: 4)
                LumenGPU.context.render(out, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                worst = min(worst, v[3])
            }
            return worst
        }
        for (tv, th, ta, ts) in [(60.0, 0.0, 0.0, 100.0), (0, -50, 0, 100), (30, 30, -40, 90), (0, 0, 0, 70)] {
            var f = EditSettings(); f.tVertical = tv; f.tHorizontal = th; f.tAspect = ta; f.tScale = ts
            check(cornerAlpha(f) > 0.95, "Fill frame should leave no empty corners (vertical \(tv), horizontal \(th), aspect \(ta), scale \(ts): corner \(cornerAlpha(f)))")
            f.tFill = false
            check(cornerAlpha(f) < 0.5, "with Fill frame off the empty corners show (vertical \(tv), horizontal \(th), aspect \(ta), scale \(ts))")
        }

        // global grading wheel tints the picture; old files without it still load
        var g = EditSettings(); g.grading.global = GradeZone(hue: 30, sat: 60, lum: 0)
        if let a = smallRender(session.develop(g, source: source, geometry: true)),
           let b = smallRender(session.develop(EditSettings(), source: source, geometry: true)), let d = compareImages(a, b) {
            check(d.all > 1.5, "the Global grading wheel should change the picture (difference \(d.all))")
        }
        check(!g.grading.isNeutral, "a Global tint counts as grading")
        let oldJSON = #"{"shadows":{"hue":0,"sat":0,"lum":0},"midtones":{"hue":0,"sat":0,"lum":0},"highlights":{"hue":0,"sat":0,"lum":0},"blending":50,"balance":0}"#
        check((try? JSONDecoder().decode(ColorGrading.self, from: Data(oldJSON.utf8))) != nil, "grading saved before the Global wheel must still load")
        if let full = try? JSONEncoder().encode(EditSettings()), var dict = try? JSONSerialization.jsonObject(with: full) as? [String: Any] {
            for k in ["flipH", "flipV", "tVertical", "tHorizontal", "tAspect", "tScale", "tOffX", "tOffY", "tFill", "disabled"] { dict.removeValue(forKey: k) }
            let older = try? JSONSerialization.data(withJSONObject: dict)
            let back = older.flatMap { try? JSONDecoder().decode(EditSettings.self, from: $0) }
            check(back != nil && back?.tScale == 100 && back?.tFill == true, "edits saved before flip/transform must still load (tScale \(String(describing: back?.tScale)))")
        }

        // preset strength: 0 = before, 1 = after, 0.5 halfway; masks and crop stay
        var before = EditSettings(); before.cropL = 0.1
        var after = EditSettings(); after.exposure = 1; after.contrast = 40; after.blackAndWhite = true
        let half = EditSettings.blend(before, after, 0.5)
        check(abs(half.exposure - 0.5) < 1e-9 && abs(half.contrast - 20) < 1e-9, "preset strength 50% should halve the preset's moves")
        check(half.cropL == 0.1, "preset strength keeps the crop")
        check(EditSettings.blend(before, after, 1).exposure == 1 && EditSettings.blend(before, after, 0).exposure == 0, "0% and 100% ends")

        // paste some: only the chosen tools come across
        var target = EditSettings(); target.exposure = -1; target.grading.shadows = GradeZone(hue: 200, sat: 40, lum: 0)
        var clip = EditSettings(); clip.exposure = 0.7; clip.vibrance = 30; clip.grading.shadows = GradeZone(hue: 20, sat: 10, lum: 0)
        target.take(.light, from: clip)
        check(target.exposure == 0.7 && target.vibrance == 0 && target.grading.shadows.hue == 200, "paste some: only Light is taken")

        // clipping kernel: white shows red, black shows blue, the rest unchanged
        if let k = LumenKernels.shared?.clip {
            let px = CIImage(color: CIColor(red: 1.2, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
            let out = k.apply(extent: px.extent, arguments: [px, CIVector(x: 0.999, y: 0.0007, z: 0, w: 0)])
            var v = [Float](repeating: 0, count: 4)
            if let out { LumenGPU.context.render(out, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
            check(v[0] > 0.7 && v[0] > v[1] * 2.5 && v[0] > v[2] * 2.5, "clipping warning should paint blown highlights red (got \(v))")
        } else { check(false, "clipping kernel did not load") }
    } else { check(false, "pro pack checks: no photo could be opened") }
}

// Masks (2026-10-11): each part has its own opacity; the Depth mask estimates distance with the on-device model
do {
    if let f = files.first(where: { $0.pathExtension.lowercased() != "arw" }) ?? files.first, let session = EditSession(url: f),
       let source = session.makeSource(maxEdge: 900, materialize: true) {
        // a whole-photo part minus a whole-photo part at 50 % leaves half
        var all = MaskComponent.make(.luminance); all.lumLow = 0; all.lumHigh = 1; all.lumLowFeather = 0; all.lumHighFeather = 0
        var cut = all; cut.id = UUID(); cut.op = .subtract; cut.amount = 50
        let m = Mask(name: "p", components: [all, cut])
        if let img = session.maskImage(m, source: source, gain: 1), let mv = maskValues(img) {
            let mean = mv.v.reduce(0, +) / Float(max(mv.v.count, 1))
            check(abs(mean - 0.5) < 0.05, "a 50 % Subtract part should take away half, not dim the whole mask (mean \(mean))")
        } else { check(false, "part opacity: mask render failed") }
        var full = cut; full.amount = 100
        if let img = session.maskImage(Mask(name: "p", components: [all, full]), source: source, gain: 1), let mv = maskValues(img) {
            check((mv.v.max() ?? 1) < 0.02, "a 100 % Subtract of everything leaves nothing (max \(mv.v.max() ?? 1))")
        }
    }

    if ProcessInfo.processInfo.environment["LUMEN_DEPTH_MODEL"] != nil {
        check(EditSession.hasDepthModel, "the depth model should load from LUMEN_DEPTH_MODEL")
        for f in files where f.pathExtension.lowercased() != "arw" {
            guard let session = EditSession(url: f), let source = session.makeSource(maxEdge: 1200, materialize: true) else { continue }
            var s = EditSettings(); s.masks = [Mask.make(.depth)]
            let t0 = now()
            session.prepareAutoMasks(s, source: source)
            let ms = Int((now() - t0) * 1000)
            guard let d = source.depthField else { check(false, "\(f.lastPathComponent): no depth estimated"); continue }
            let photoTall = source.size.height > source.size.width, fieldTall = d.height > d.width
            check(photoTall == fieldTall, "\(f.lastPathComponent): depth field (\(d.width)x\(d.height)) should have the photo's orientation (\(source.size))")
            let rows = d.height / 4
            func band(_ r0: Int, _ r1: Int) -> Float {
                var t: Float = 0; var n: Float = 0
                for y in r0..<r1 { for x in 0..<d.width { t += d.values[y * d.width + x]; n += 1 } }
                return t / max(n, 1)
            }
            let top = band(0, rows), bottom = band(d.height - rows, d.height)
            print("depth \(f.lastPathComponent): \(d.width)x\(d.height) in \(ms) ms, top \(top) bottom \(bottom)")
            // the sky the scene model found is always the farthest thing (2026-10-12)
            if source.sceneField?.found.contains(.sky) == true, let sky = source.cachedMask(EditSession.aiSky) {
                // the field prepareAutoMasks stored must already be the sky-aware one
                if let sv = maskValues(EditSession.depthImage(d, extent: source.extent), width: 64),
                   let skv = maskValues(sky, width: 64), sv.v.count == skv.v.count {
                    var sum: Float = 0, n: Float = 0
                    for i in sv.v.indices where skv.v[i] > 0.9 { sum += sv.v[i]; n += 1 }
                    print("::notice::\(f.lastPathComponent): depth inside the sky \(n > 0 ? sum / n : -1) over \(Int(n)) cells")
                    check(n == 0 || sum / n > 0.93, "\(f.lastPathComponent): the sky should read as far (\(sum / max(n, 1)))")
                }
            }
            if f.lastPathComponent.hasPrefix("matterhorn") {
                check(top > bottom + 0.15, "matterhorn: the sky and peak (top) should read farther than the ground (bottom): top \(top) bottom \(bottom)")
                // a band reaching from nearest to just past the ground covers the bottom far more than the sky at the top
                var near = Mask.make(.depth)
                near.components[0].lumLow = 0; near.components[0].lumHigh = Double(bottom) + 0.1
                near.components[0].lumHighFeather = 0.05
                if let img = session.maskImage(near, source: source, gain: 1), let mv = maskValues(img) {
                    let q = mv.h / 4
                    // maskValues rows: top of the image first, as render(toBitmap:) writes them
                    let topCover = mv.v[0..<(q * mv.w)].reduce(0, +) / Float(q * mv.w)
                    let bottomCover = mv.v[((mv.h - q) * mv.w)...].reduce(0, +) / Float(q * mv.w)
                    print("depth near mask: top \(topCover), bottom \(bottomCover)")
                    check(bottomCover > topCover + 0.3, "matterhorn: a near depth band should cover the ground (bottom \(bottomCover)) far more than the sky (top \(topCover))")
                } else { check(false, "depth mask render failed") }
            }
        }
    } else {
        print("::warning::no LUMEN_DEPTH_MODEL: depth mask not checked")
    }
}

// Edge refinement (2026-10-11): a blurry AI mask is snapped onto the photo's real edge
do {
    let w = 1200, h = 800
    if let gctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
        gctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)); gctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        gctx.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1)); gctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("edge-test.png")
        if let cg = gctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
        }
        if let session = EditSession(url: url), let source = session.makeSource(maxEdge: 1200, materialize: true) {
            let ext = source.extent
            // the "AI" mask: the dark left half, but with a very soft edge (like a mask found on a small copy)
            let hard = EditSession.constant(1, CGRect(x: ext.minX, y: ext.minY, width: ext.width / 2, height: ext.height))
                .composited(over: EditSession.constant(0, ext))
            // about as soft as a Vision mask scaled up from its small copy (~4 px on a 2560 px preview)
            let soft = EditSession.blur(hard, 2, ext)
            func transition(_ img: CIImage) -> (Int, Float, Float)? {
                guard let mv = maskValues(img, width: 1200) else { return nil }
                let y = mv.h / 2
                let row = Array(mv.v[(y * mv.w)..<((y + 1) * mv.w)])
                return (row.filter { $0 > 0.1 && $0 < 0.9 }.count, row[mv.w / 8], row[mv.w * 7 / 8])
            }
            let kk = LumenKernels.shared
            check(kk?.gfPack != nil && kk?.gfCoef != nil && kk?.gfApply != nil, "edge refinement kernels should load")
            if let before = transition(soft), let ref = session.refined(soft, source: source), let after = transition(ref) {
                print("edge refinement: soft pixels \(before.0) -> \(after.0), inside \(after.1), outside \(after.2)")
                check(after.0 * 2 <= before.0, "edge refinement should make a soft mask edge much sharper (\(before.0) -> \(after.0) partly-covered pixels)")
                check(after.1 > 0.9 && after.2 < 0.1, "edge refinement must keep the inside selected and the outside clear (\(after.1), \(after.2))")
            } else { check(false, "edge refinement: render failed") }
        } else { check(false, "edge refinement: synthetic photo did not open") }
    }
}

// Scene model (2026-10-11): Lightroom-style Landscape parts and an AI sky
check(MaskComponent.make(.subject).feather == 0 && MaskComponent.make(.landscape).feather == 0, "AI masks should start with no extra softening")
if let p = ProcessInfo.processInfo.environment["LUMEN_SEG_MODEL"] {
    check(EditSession.hasSceneModel, "the scene model should load from LUMEN_SEG_MODEL")
    // the class numbers in ScenePart must name what we think they do
    if let ml = try? MLModel(contentsOf: URL(fileURLWithPath: p)),
       let js = (ml.modelDescription.metadata[.creatorDefinedKey] as? [String: String])?["com.apple.coreml.model.preview.params"]?.data(using: .utf8),
       let o = try? JSONSerialization.jsonObject(with: js) as? [String: Any], let labels = o["labels"] as? [String] {
        let expect: [ScenePart: [String]] = [.sky: ["sky"], .water: ["river", "sea", "water"], .vegetation: ["tree", "grass", "flower"],
                                             .mountains: ["mountain", "rock"], .naturalGround: ["sand", "snow", "dirt", "gravel", "playingfield"],
                                             .artificialGround: ["road", "pavement", "railroad", "platform"],
                                             .architecture: ["building", "house", "roof", "wall", "bridge", "window", "door"]]
        for part in ScenePart.allCases {
            for c in part.classes {
                let name = Int(c) < labels.count ? labels[Int(c)] : "?"
                check(expect[part]!.contains { name.hasPrefix($0) }, "scene class \(c) for \(part.rawValue) is '\(name)'")
            }
        }
    } else { check(false, "scene model labels could not be read") }
    for f in files where f.lastPathComponent.hasPrefix("matterhorn") {
        guard let session = EditSession(url: f), let source = session.makeSource(maxEdge: 1200, materialize: true) else { continue }
        var c = MaskComponent.make(.landscape); c.scene = [ScenePart.mountains.rawValue]
        var s = EditSettings(); s.masks = [Mask(name: "l", components: [c]), Mask.make(.sky)]
        let t0 = now()
        session.prepareAutoMasks(s, source: source)
        let ms = Int((now() - t0) * 1000)
        let found = source.sceneField?.found ?? []
        print("::notice::scene matterhorn in \(ms) ms: found \(found.map(\.rawValue).sorted())")
        check(found.contains(.sky), "matterhorn: the scene model should find the sky (found \(found.map(\.rawValue)))")
        if let img = session.maskImage(Mask.make(.sky), source: source, gain: 1), let mv = maskValues(img) {
            let q = mv.h / 5
            let top = mv.v[0..<(q * mv.w)].reduce(0, +) / Float(q * mv.w)
            let bottom = mv.v[((mv.h - q) * mv.w)...].reduce(0, +) / Float(q * mv.w)
            check(top > 0.5 && bottom < 0.2, "matterhorn: the AI sky should cover the top (\(top)) and not the bottom (\(bottom))")
        } else { check(false, "matterhorn: sky mask render failed") }
        if found.contains(.mountains), let img = session.maskImage(Mask(name: "l", components: [c]), source: source, gain: 1),
           let mv = maskValues(img) {
            check(mv.v.reduce(0, +) / Float(mv.v.count) > 0.05, "matterhorn: the Mountains part should select something")
        }
    }
    // Sky seen through trees (2026-10-11): before / after sheets, and the gaps never spill onto a white building
    var skyTiles: [(String, CGImage)] = []
    var vegTiles: [(String, CGImage)] = []
    var skyPhotos = files.filter { ["jpg", "arw"].contains($0.pathExtension.lowercased()) }
    if let t = ProcessInfo.processInfo.environment["LUMEN_TREES_SAMPLE"] { skyPhotos.insert(URL(fileURLWithPath: t), at: 0) }
    for url in skyPhotos {
        guard let session = EditSession(url: url), let source = session.makeSource(maxEdge: 1200, materialize: true),
              let scene = session.computeScene(source), scene.found.contains(.sky),
              let before = session.sceneMask([.sky], scene, source: source), let k = LumenKernels.shared else { continue }
        let stem = url.deletingPathExtension().lastPathComponent
        let t0 = now()
        let gaps = session.skyThroughTrees(before, scene: scene, source: source)
        let ms = Int((now() - t0) * 1000)
        // the four quarters: finer at the sky's edge
        let t1 = now()
        let fineScene = session.skyScene(scene, source: source)
        check(fineScene != nil, "\(stem): the quarter runs of the scene model gave nothing")
        let fineSky = fineScene.flatMap { session.sceneMask([.sky], $0, source: source) }
        let after = fineSky.map { session.skyThroughTrees($0, scene: fineScene!, source: source) } ?? gaps
        print("::notice::sky quarters \(stem): \(Int((now() - t1) * 1000)) ms")
        guard let mb = maskValues(before, width: 96), let ma = maskValues(after, width: 96) else { continue }
        let meanB = mb.v.reduce(0, +) / Float(mb.v.count), meanA = ma.v.reduce(0, +) / Float(ma.v.count)
        let trees = scene.labels.filter { $0 == ScenePart.treeClass }.count
        print("::notice::sky through trees \(stem): \(ms) ms, sky \(meanB) -> \(meanA), tree labels \(trees)")
        check(meanA > meanB - 0.03, "\(stem): the finer sky should not lose sky (\(meanB) -> \(meanA))")
        check(meanA < meanB + 0.12, "\(stem): the finer sky should not grow wildly (\(meanB) -> \(meanA))")
        if stem == "building" {
            // the white facade (right half, upper middle) is architecture: it must stay out of the sky
            var sum: Float = 0, n: Float = 0
            for y in 0..<ma.h where Float(y) / Float(ma.h) > 0.15 && Float(y) / Float(ma.h) < 0.6 {
                for x in 0..<ma.w where Float(x) / Float(ma.w) > 0.6 && Float(x) / Float(ma.w) < 0.9 { sum += ma.v[y * ma.w + x]; n += 1 }
            }
            check(n > 0 && sum / n < 0.15, "building: the white facade must not become sky (\(sum / max(n, 1)))")
        }
        let photo = session.develop(EditSettings(), source: source, geometry: true)
        func tinted(_ m: CIImage) -> CGImage? {
            smallRender(k.overlay.apply(extent: photo.extent, arguments: [photo, m, CIVector(x: 1, y: 0.1, z: 0.12, w: 0.55)]) ?? photo, width: 300)
        }
        if let p = smallRender(photo, width: 300), let b = tinted(gaps), let a = tinted(after) {
            skyTiles += [("\(stem)", p), ("sky (live)", b), ("four quarters", a)]
        }
        // Landscape parts keep off the sky (2026-10-12): Vegetation must not cover the sky seen through the leaves
        source.storeMask(EditSession.aiSky, after)
        if scene.found.contains(.vegetation), let oldVeg = session.sceneMask([.vegetation], scene, source: source),
           let newVeg = session.landscapeMask([.vegetation], scene, source: source),
           let mul = k.maskMul.apply(extent: source.extent, arguments: [newVeg, after]),
           let mulOld = k.maskMul.apply(extent: source.extent, arguments: [oldVeg, after]),
           let both = maskValues(mul, width: 96), let bothOld = maskValues(mulOld, width: 96) {
            let overlap = both.v.reduce(0, +) / Float(both.v.count), overlapOld = bothOld.v.reduce(0, +) / Float(bothOld.v.count)
            print("::notice::\(stem): vegetation over sky \(overlapOld) -> \(overlap)")
            check(overlap < 0.01, "\(stem): Vegetation should keep off the sky (overlap \(overlap), was \(overlapOld))")
            let photo = session.develop(EditSettings(), source: source, geometry: true)
            func tint(_ m: CIImage) -> CGImage? {
                smallRender(k.overlay.apply(extent: photo.extent, arguments: [photo, m, CIVector(x: 0.2, y: 1, z: 0.3, w: 0.55)]) ?? photo, width: 300)
            }
            if let p = smallRender(photo, width: 300), let a = tint(oldVeg), let b = tint(newVeg) {
                vegTiles += [("\(stem)", p), ("vegetation before", a), ("vegetation now", b)]
            }
        }
        if stem == "matterhorn", let mv = maskValues(after) {
            let q = mv.h / 5
            let top = mv.v[0..<(q * mv.w)].reduce(0, +) / Float(q * mv.w)
            let bottom = mv.v[((mv.h - q) * mv.w)...].reduce(0, +) / Float(q * mv.w)
            check(top > 0.5 && bottom < 0.2, "matterhorn (quarters): the sky should cover the top (\(top)) and not the bottom (\(bottom))")
        }
    }
    if !vegTiles.isEmpty, let cg = sheet(vegTiles, cell: 300, cols: 3) {
        let dir = outDir.appendingPathComponent("previews")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = CGImageDestinationCreateWithURL(dir.appendingPathComponent("vegetation-sky.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(d)
            print("::notice::preview vegetation-sky.jpg saved")
        }
    }
    if !skyTiles.isEmpty, let cg = sheet(skyTiles, cell: 300, cols: 3) {
        let dir = outDir.appendingPathComponent("previews")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = CGImageDestinationCreateWithURL(dir.appendingPathComponent("sky-trees.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(d)
            print("::notice::preview sky-trees.jpg saved")
        }
    }
} else {
    print("::warning::no LUMEN_SEG_MODEL: scene masks not checked")
}

// Heal (2026-10-11): a stored patch is painted into every decode; with the model, a red disc is removed
do {
    HealStore.directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heal-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: HealStore.directory, withIntermediateDirectories: true)
    let w = 1200, h = 800
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    if let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
        // a soft green-to-blue background with stripes (something to copy from) and a red disc in the middle
        for x in stride(from: 0, to: w, by: 4) {
            let t = CGFloat(x) / CGFloat(w)
            g.setFillColor(CGColor(red: 0.2, green: 0.5 - 0.2 * t, blue: 0.3 + 0.4 * t, alpha: 1))
            g.fill(CGRect(x: x, y: 0, width: 4, height: h))
        }
        g.setFillColor(CGColor(red: 0.15, green: 0.35, blue: 0.4, alpha: 1))
        for y in stride(from: 0, to: h, by: 40) { g.fill(CGRect(x: 0, y: y, width: w, height: 6)) }
        g.setFillColor(CGColor(red: 0.95, green: 0.05, blue: 0.05, alpha: 1))
        g.fillEllipse(in: CGRect(x: 540, y: 340, width: 120, height: 120))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heal-test.png")
        if let cg = g.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
        }
        if let session = EditSession(url: url) {
            func centre(_ heals: [HealSpot]) -> [Float] {
                session.heals = heals
                guard let img = session.decode(maxEdge: nil) else { return [] }
                var v = [Float](repeating: 0, count: 4)
                LumenGPU.context.render(img, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: 600, y: 400, width: 1, height: 1),
                                        format: .RGBAf, colorSpace: nil)
                return v
            }
            let before = centre([])
            check(before.count == 4 && before[0] > before[1] * 3, "heal test: the disc should be red before healing (\(before))")
            // 1. the store: a hand-made grey patch over the disc replaces it
            let id = UUID()
            if let grey = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
               let maskCtx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                grey.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)); grey.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                maskCtx.setFillColor(gray: 1, alpha: 1); maskCtx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                try? LumenGPU.context.writePNGRepresentation(of: CIImage(cgImage: grey.makeImage()!), to: HealStore.patchURL(id),
                                                              format: .RGBA8, colorSpace: cs)
                try? EditSession.writeGrayPNG(maskCtx.makeImage()!, to: HealStore.maskURL(id))
                let spot = HealSpot(id: id, strokes: [], x: 0.4, y: 0.4, w: 0.2, h: 0.2)
                let after = centre([spot])
                check(after.count == 4 && abs(after[0] - after[1]) < 0.05, "a stored heal patch should replace the disc (\(after))")
            }
            // 2. the model: paint over the disc and it is rebuilt from the stripes around it
            if ProcessInfo.processInfo.environment["LUMEN_HEAL_MODEL"] != nil {
                check(EditSession.hasHealModel, "the heal model should load from LUMEN_HEAL_MODEL")
                print("::notice::heal model input \(EditSession.healSide) px")
                if let want = ProcessInfo.processInfo.environment["LUMEN_HEAL_EXPECT_SIDE"].flatMap(Int.init) {
                    check(EditSession.healSide == want, "the heal model should be \(want) px (is \(EditSession.healSide))")
                }
                let stroke = BrushStroke(points: [Pt(x: 0.49, y: 0.5), Pt(x: 0.51, y: 0.5)], size: 0.12, erase: false, feather: nil)
                session.heals = []
                let t0 = now()
                if let spot = session.makeHeal(strokes: [stroke], earlier: []) {
                    print("::notice::heal made in \(Int((now() - t0) * 1000)) ms, rect \(spot.x),\(spot.y) \(spot.w)x\(spot.h), scale \(spot.scale)")
                    let after = centre([spot])
                    check(after.count == 4 && after[0] < after[2] && after[0] < 0.5 * before[0],
                          "healing should remove the red disc (centre before \(before), after \(after))")
                } else { check(false, "makeHeal returned nothing") }
            } else { print("::warning::no LUMEN_HEAL_MODEL: heal model not checked") }
            session.heals = []
        } else { check(false, "heal test: synthetic photo did not open") }
    }
    // a white badge on plain red paint (the owner's Ferrari): the heal must come back red, not dark
    if ProcessInfo.processInfo.environment["LUMEN_HEAL_MODEL"] != nil {
        let w = 1200, h = 800
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        if let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            g.setFillColor(CGColor(red: 0.78, green: 0.08, blue: 0.07, alpha: 1)); g.fill(CGRect(x: 0, y: 0, width: w, height: h))
            g.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)); g.fillEllipse(in: CGRect(x: 570, y: 360, width: 60, height: 80))
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heal-red.png")
            if let cg = g.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
            }
            if let session = EditSession(url: url) {
                let stroke = BrushStroke(points: [Pt(x: 0.5, y: 0.48), Pt(x: 0.5, y: 0.52)], size: 0.09, erase: false, feather: nil)
                if let spot = session.makeHeal(strokes: [stroke], earlier: []) {
                    session.heals = [spot]
                    var v = [Float](repeating: 0, count: 4)
                    if let img = session.decode(maxEdge: nil) {
                        LumenGPU.context.render(img, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: 600, y: 400, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                    }
                    print("::warning::heal red paint: centre after \(v.prefix(3)); steps: \(EditSession.healDiagnostics)")
                    check(v[0] > 0.35 && v[1] < 0.1, "a badge on red paint should heal to red (centre \(v.prefix(3)))")
                    // the stored patch must be fully opaque (a see-through patch turned red paint black on the iPhone)
                    if let src = CGImageSourceCreateWithURL(HealStore.patchURL(spot.id) as CFURL, nil),
                       let cg = CGImageSourceCreateImageAtIndex(src, 0, nil), let px = rgbaBytes(cg) {
                        var minA: UInt8 = 255
                        for i in stride(from: 3, to: px.count, by: 4) { minA = min(minA, px[i]) }
                        check(minA == 255, "the stored heal patch should be fully opaque (lowest alpha \(minA))")
                    } else { check(false, "the stored heal patch could not be read") }
                } else { check(false, "red paint: makeHeal failed") }
            }
        }
    }
    // the Sony ARW in SDR and HDR: a heal on a plain area must come back about as bright as what surrounds it
    if ProcessInfo.processInfo.environment["LUMEN_HEAL_MODEL"] != nil,
       let arw = files.first(where: { $0.pathExtension.lowercased() == "arw" }) {
        for hdr in [false, true] {
            guard let session = EditSession(url: arw, expandHDR: hdr), let full = session.decode(maxEdge: nil) else { continue }
            let e = full.extent
            func mean(_ img: CIImage, _ r: CGRect) -> [Float] {
                var v = [Float](repeating: 0, count: 4)
                let a = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
                LumenGPU.context.render(a, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return v
            }
            // brightest-ish spot near the centre third: a small disc in the middle of the photo
            let stroke = BrushStroke(points: [Pt(x: 0.5, y: 0.45), Pt(x: 0.52, y: 0.45)], size: 0.02, erase: false, feather: nil)
            let L = max(e.width, e.height)
            let r = 0.01 * L
            let cx = 0.51 * e.width, cy = (1 - 0.45) * e.height
            let inner = CGRect(x: cx - r * 0.6, y: cy - r * 0.5, width: r * 1.2, height: r)
            let ring = CGRect(x: cx - r * 4, y: cy - r * 4, width: r * 8, height: r * 8)
            let before = mean(full, ring)
            if let spot = session.makeHeal(strokes: [stroke], earlier: []) {
                session.heals = [spot]
                if let healed = session.decode(maxEdge: nil) {
                    let after = mean(healed, inner)
                    print("::warning::heal ARW hdr=\(hdr) steps: \(EditSession.healDiagnostics)")
                    print("::warning::heal ARW hdr=\(hdr): scale \(spot.scale), surroundings \(before.prefix(3)), healed spot \(after.prefix(3))")
                    let lb = (before[0] + before[1] + before[2]) / 3, la = (after[0] + after[1] + after[2]) / 3
                    // the sample's spot holds a dark object, so this is a report, not a check (the red-paint test checks colour)
                    print("::warning::ARW hdr=\(hdr): healed spot brightness \(la) vs surroundings \(lb)")
                }
            } else { check(false, "ARW hdr=\(hdr): makeHeal failed") }
        }
    }
}

// Remove people and big heals (2026-10-11)
do {
    func savePreview(_ name: String, _ items: [(String, CGImage)]) {
        guard let cg = sheet(items, cell: 380, cols: items.count) else { return }
        let dir = outDir.appendingPathComponent("previews")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".jpg")
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(d)
        print("::notice::preview \(name).jpg saved")
    }
    func pixel(_ img: CIImage, _ x: CGFloat, _ yDown: CGFloat) -> [Float] {
        var v = [Float](repeating: 0, count: 4)
        let e = img.extent
        LumenGPU.context.render(img, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: e.minX + x, y: e.maxY - yDown - 1, width: 1, height: 1),
                                format: .RGBAf, colorSpace: nil)
        return v
    }

    // 1. a person mask split into people: two people and a crumb, boxes measured from the top left
    do {
        let w = 200, h = 100
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 10..<60 { for x in 20..<50 { px[y * w + x] = 255 } }      // tall, upper left
        for y in 70..<95 { for x in 150..<160 { px[y * w + x] = 200 } }    // small, lower right
        px[5 * w + 190] = 255                                               // a crumb
        let people = EditSession.splitPeople(px, width: w, height: h)
        check(people.count == 2, "splitPeople: two people expected, got \(people.count)")
        if people.count == 2 {
            let a = people[0], b = people[1]
            check(abs(a.box.minX - 0.1) < 0.01 && abs(a.box.minY - 0.1) < 0.02 && abs(a.box.height - 0.5) < 0.02,
                  "splitPeople: the big one's box should be at the top left (\(a.box))")
            check(b.box.minY > 0.65, "splitPeople: the small one is near the bottom (\(b.box))")
            check(a.main && !b.main, "splitPeople: the big one is who the photo is of, the small one is not")
            // the mask image is upright: white at the big one's place (top), black below it
            check(pixel(a.mask, 35, 30)[0] > 0.9 && pixel(a.mask, 35, 85)[0] < 0.1,
                  "splitPeople: the mask should be upright (\(pixel(a.mask, 35, 30)[0]), \(pixel(a.mask, 35, 85)[0]))")
        }
    }

    // 2. the square around a tall area on a portrait photo holds all of it (up to 0.1.158 it was cut at the photo's width)
    let tall = CGRect(x: 1500, y: 500, width: 1000, height: 5000)
    if let r = EditSession.healRegion(around: tall, width: 4000, height: 6000) {
        check(r.contains(tall), "a tall area on a portrait photo should fit inside its square (\(r))")
    } else { check(false, "healRegion gave nothing for a tall area") }
    if let r = EditSession.healRegion(around: CGRect(x: 100, y: 100, width: 50, height: 50), width: 4000, height: 6000) {
        check(r.minX >= 0 && r.minY >= 0 && r.width == 192, "a small spot's square should stay inside the photo (\(r))")
    }

    if ProcessInfo.processInfo.environment["LUMEN_HEAL_MODEL"] != nil {
        HealStore.directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heal-big-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: HealStore.directory, withIntermediateDirectories: true)

        // 3. a red post taller than the photo is wide: one stroke removes all of it, top to bottom
        let w = 600, h = 1000
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        if let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            for y in stride(from: 0, to: h, by: 4) {
                let t = CGFloat(y) / CGFloat(h)
                g.setFillColor(CGColor(red: 0.25, green: 0.45 + 0.2 * t, blue: 0.5 - 0.2 * t, alpha: 1))
                g.fill(CGRect(x: 0, y: y, width: w, height: 4))
            }
            g.setFillColor(CGColor(red: 0.95, green: 0.05, blue: 0.05, alpha: 1))
            g.fill(CGRect(x: 275, y: 60, width: 50, height: 880))
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heal-tall.png")
            if let cg = g.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
            }
            if let session = EditSession(url: url), let before = session.decode(maxEdge: nil) {
                let pts = stride(from: 0.06, through: 0.94, by: 0.02).map { Pt(x: 0.5, y: $0) }
                let stroke = BrushStroke(points: pts, size: 0.08, erase: false, feather: nil)
                let t0 = now()
                if let spot = session.makeHeal(strokes: [stroke], earlier: []) {
                    print("::notice::tall heal in \(Int((now() - t0) * 1000)) ms, square \(spot.x),\(spot.y) \(spot.w)x\(spot.h)")
                    session.heals = [spot]
                    if let after = session.decode(maxEdge: nil) {
                        for y in [90.0, 500.0, 910.0] {
                            let v = pixel(after, 300, CGFloat(y))
                            check(v[0] < 0.5 && v[0] < v[1], "the whole red post should be gone, also at y \(Int(y)) (\(v.prefix(3)))")
                        }
                        if let a = smallRender(before, width: 380), let b = smallRender(after, width: 380) {
                            savePreview("tall-heal", [("painted over the post", a), ("healed", b)])
                        }
                    }
                    session.heals = []
                } else { check(false, "tall heal: makeHeal failed (\(EditSession.healFailure.map { "\($0)" } ?? "?"))") }
            }
        }

        // 3b. a big removal on gravel (2026-10-18, owner: big removals looked blurry): the patch keeps the photo's grain
        do {
            let w = 4000, h = 3000
            var px = [UInt8](repeating: 0, count: w * h * 4)
            var rng = SystemRandomNumberGenerator()
            for i in 0..<(w * h) {
                let v = UInt8(clamping: 110 + Int.random(in: -45...45, using: &rng))
                px[i * 4] = v; px[i * 4 + 1] = UInt8(clamping: Int(v) - 8); px[i * 4 + 2] = UInt8(clamping: Int(v) - 20); px[i * 4 + 3] = 255
            }
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            if let g = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                g.setFillColor(CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1))
                g.fillEllipse(in: CGRect(x: 2000 - 300, y: 1500 - 300, width: 600, height: 600))
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heal-gravel.png")
                if let cg = g.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
                }
                if let session = EditSession(url: url), let before = session.decode(maxEdge: nil) {
                    let stroke = BrushStroke(points: [Pt(x: 0.49, y: 0.5), Pt(x: 0.51, y: 0.5)], size: 0.17, erase: false, feather: nil)
                    let t0 = now()
                    if let spot = session.makeHeal(strokes: [stroke], earlier: []) {
                        print("::notice::gravel heal in \(Int((now() - t0) * 1000)) ms, square \(Int(spot.w * Double(w))) px")
                        session.heals = [spot]
                        if let after = session.decode(maxEdge: nil) {
                            // grain = mean step between neighbouring pixels along a row, in a 120 px window
                            func grain(_ img: CIImage, _ cx: Int, _ cy: Int) -> Float {
                                var row = [Float](repeating: 0, count: 120 * 4 * 8)
                                let e = img.extent
                                LumenGPU.context.render(img, toBitmap: &row, rowBytes: 120 * 16,
                                                        bounds: CGRect(x: e.minX + CGFloat(cx - 60), y: e.maxY - CGFloat(cy) - 4, width: 120, height: 8),
                                                        format: .RGBAf, colorSpace: nil)
                                var s: Float = 0, k = 0
                                for r in 0..<8 { for x in 1..<120 { s += abs(row[(r * 120 + x) * 4] - row[(r * 120 + x - 1) * 4]); k += 1 } }
                                return s / Float(k)
                            }
                            let inside = grain(after, 2000, 1500), outside = grain(after, 600, 600)
                            let c = pixel(after, 2000, 1500)
                            print("::notice::gravel heal grain inside \(inside) vs outside \(outside), centre \(c.prefix(3))")
                            check(c[0] < c[1] + 0.25, "the red disc on gravel should be gone (\(c.prefix(3)))")
                            check(!EditSession.healDetailEnabled || inside > 0.5 * outside, "a big heal on gravel should keep the grain (inside \(inside), outside \(outside))")
                            let crop = CGRect(x: 2000 - 700, y: 1500 - 700, width: 1400, height: 1400)
                            if let a = smallRender(before.cropped(to: crop), width: 380), let b = smallRender(after.cropped(to: crop), width: 380) {
                                savePreview("gravel-heal", [("big red disc on gravel", a), ("healed", b)])
                            }
                        }
                        session.heals = []
                    } else { check(false, "gravel heal: makeHeal failed (\(EditSession.healFailure.map { "\($0)" } ?? "?"))") }
                }
            }
        }

        // 3c. a big removal on a soft, lens-blurred background with sharp lines nearby (owner, 18 Oct, 0.1.256: the copied
        //     texture pasted diagonal streaks and grain into the bokeh): the patch must stay as smooth as its surroundings
        do {
            let w = 4000, h = 3000
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            if let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                for x in stride(from: 0, to: w, by: 8) {
                    let t = CGFloat(x) / CGFloat(w)
                    g.setFillColor(CGColor(red: 0.25 + 0.2 * t, green: 0.35 + 0.1 * t, blue: 0.2, alpha: 1))
                    g.fill(CGRect(x: x, y: 0, width: 8, height: h))
                }
                g.setStrokeColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)); g.setLineWidth(6)
                for i in 0..<6 {   // sharp diagonal lines all round the disc (where texture could be copied from)
                    let o = CGFloat(i) * 90
                    g.move(to: CGPoint(x: 600 + o, y: 200)); g.addLine(to: CGPoint(x: 3400 + o, y: 2800)); g.strokePath()
                }
                g.setFillColor(CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1))
                g.fillEllipse(in: CGRect(x: 1700, y: 1200, width: 600, height: 600))
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heal-bokeh.png")
                if let cg = g.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
                }
                if let session = EditSession(url: url), let before = session.decode(maxEdge: nil) {
                    let stroke = BrushStroke(points: [Pt(x: 0.49, y: 0.5), Pt(x: 0.51, y: 0.5)], size: 0.17, erase: false, feather: nil)
                    if let spot = session.makeHeal(strokes: [stroke], earlier: []) {
                        print("::notice::bokeh heal: \(EditSession.healDiagnostics)")
                        session.heals = [spot]
                        if let after = session.decode(maxEdge: nil) {
                            var row = [Float](repeating: 0, count: 120 * 4 * 8)
                            let e = after.extent
                            LumenGPU.context.render(after, toBitmap: &row, rowBytes: 120 * 16,
                                                    bounds: CGRect(x: e.minX + 1940, y: e.maxY - 1504, width: 120, height: 8),
                                                    format: .RGBAf, colorSpace: nil)
                            var s: Float = 0, k = 0
                            for r in 0..<8 { for x in 1..<120 { s += abs(row[(r * 120 + x) * 4 + 1] - row[(r * 120 + x - 1) * 4 + 1]); k += 1 } }
                            let step = s / Float(k)
                            print("::notice::bokeh heal grain inside \(step)")
                            check(step < 0.012, "a heal on a smooth background should stay smooth, no copied lines or grain (\(step))")
                            let crop = CGRect(x: 2000 - 700, y: 1500 - 700, width: 1400, height: 1400)
                            if let a = smallRender(before.cropped(to: crop), width: 380), let b = smallRender(after.cropped(to: crop), width: 380) {
                                savePreview("bokeh-heal", [("big disc on a soft background", a), ("healed", b)])
                            }
                        }
                        session.heals = []
                    } else { check(false, "bokeh heal: makeHeal failed") }
                }
            }
        }

        // 4. Remove people on a street photo: everyone found, upright, and one of them removed
        if let path = ProcessInfo.processInfo.environment["LUMEN_PEOPLE_SAMPLE"],
           let session = EditSession(url: URL(fileURLWithPath: path)),
           let src = session.makeSource(maxEdge: 1200, materialize: true, heals: []) {
            let t0 = now()
            let people = session.findPeople(earlier: [])
            print("::notice::found \(people.count) people in \(Int((now() - t0) * 1000)) ms: " + people.map {
                String(format: "box %.2f,%.2f %.2fx%.2f area %.3f main %@", $0.box.minX, $0.box.minY, $0.box.width, $0.box.height,
                       $0.area, $0.main ? "yes" : "no") }.joined(separator: " | "))
            check(people.count >= 3, "the street photo has at least three people, found \(people.count)")
            // they stand on the pavement: heads in the upper half, feet low down (a flipped mask would put them high up)
            check(people.prefix(3).allSatisfy { $0.box.minY > 0.25 && $0.box.maxY > 0.6 },
                  "people's boxes should be the right way up (\(people.prefix(3).map { $0.box }))")
            if !people.isEmpty {
                let plain = EditSettings()
                let original = session.develop(plain, source: src, geometry: true)
                let target = people.min { abs($0.box.midX - 0.35) < abs($1.box.midX - 0.35) }!
                let tinted = session.tintPeople(original, [target], source: src, settings: plain, applyCrop: true,
                                                colour: CIVector(x: 1, y: 0.1, z: 0.12, w: 0.55))
                let t1 = now()
                var made: [HealSpot] = []
                if let spot = session.makeHeal(person: target, earlier: []) {
                    print("::notice::removed a person in \(Int((now() - t1) * 1000)) ms, square \(spot.w)x\(spot.h); \(EditSession.healDiagnostics)")
                    made.append(spot)
                } else { check(false, "Remove people: makeHeal(person:) failed (\(EditSession.healFailure.map { "\($0)" } ?? "?"))") }
                // and everyone else, each built on the fixes before
                var all = made
                for p in people where p.id != target.id {
                    if let spot = session.makeHeal(person: p, earlier: all) { all.append(spot) }
                    else { print("::warning::person \(p.id) could not be removed: \(EditSession.healFailure.map { "\($0)" } ?? "?")") }
                }
                func developed(_ heals: [HealSpot]) -> CGImage? {
                    guard let s = session.makeSource(maxEdge: 1200, materialize: true, heals: heals) else { return nil }
                    return smallRender(session.develop(plain, source: s, geometry: true), width: 380)
                }
                if let a = smallRender(original, width: 380), let b = smallRender(tinted, width: 380),
                   let c = developed(made), let d = developed(all) {
                    savePreview("remove-people", [("original", a), ("picked (red)", b), ("one removed", c), ("all removed", d)])
                    // what Apple's two people finders see (grey = how sure): the one used, and the per-person one
                    if let img = session.decode(maxEdge: 1200),
                       let cg = LumenGPU.context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: LumenGPU.displaySpace) {
                        var tiles: [(String, CGImage)] = [("photo", a)]
                        let seg = VNGeneratePersonSegmentationRequest()
                        seg.qualityLevel = .accurate
                        seg.outputPixelFormat = kCVPixelFormatType_OneComponent8
                        let inst = VNGeneratePersonInstanceMaskRequest()
                        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                        try? handler.perform([seg, inst])
                        if let buf = seg.results?.first?.pixelBuffer {
                            let m = EditSession.expandRed(CIImage(cvPixelBuffer: buf, options: [.colorSpace: NSNull()]))
                            let fitted = EditSession.fit(m, to: img.extent)
                            if let t = smallRender(fitted, width: 380) { tiles.append(("segmentation (used)", t)) }
                        }
                        if let obs = inst.results?.first,
                           let buf = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
                            print("::notice::person instance request: \(obs.allInstances.count) people")
                            let m = EditSession.expandRed(CIImage(cvPixelBuffer: buf, options: [.colorSpace: NSNull()]))
                            if let t = smallRender(EditSession.fit(m, to: img.extent), width: 380) { tiles.append(("instances (\(obs.allInstances.count))", t)) }
                        } else { print("::warning::person instance request gave nothing") }
                        savePreview("people-finders", tiles)
                    }
                    if let diff = compareImages(c, a) {
                        check(diff.all > 1, "removing a person should change the photo (mean diff \(diff.all))")
                    }
                }
            }
        } else { print("::warning::no LUMEN_PEOPLE_SAMPLE: Remove people not checked on a real photo") }
    }
}

check(opened > 0, "no sample photo could be opened from \(inDir.path) (\(files.count) files found)")
finishChecks()
