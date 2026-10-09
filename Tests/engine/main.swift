import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Metal

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

check(opened > 0, "no sample photo could be opened from \(inDir.path) (\(files.count) files found)")
finishChecks()
