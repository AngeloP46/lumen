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

check(opened > 0, "no sample photo could be opened from \(inDir.path) (\(files.count) files found)")
finishChecks()
