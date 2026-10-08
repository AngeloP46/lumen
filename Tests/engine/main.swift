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

let files = (try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)) ?? []
for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    let stem = file.deletingPathExtension().lastPathComponent
    let t0 = now()
    guard let session = EditSession(url: file) else { print("cannot open", file.lastPathComponent); continue }
    let t1 = now()
    guard let source = session.makeSource(maxEdge: 1800, materialize: true) else { print("source failed", stem); continue }
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
        ("crop 16:9 + 6deg", edit { $0.cropAspect = 16.0 / 9; $0.straighten = 6 }),
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
        for (label, s) in cases { if let cg = render(s) { items.append((label, cg)) } }
        if let sh = sheet(items) { saveJPEG(sh, "\(stem)-\(gname).jpg") }
    }
    var ov: [(String, CGImage)] = []
    for (label, m) in maskCases {
        let s = edit { $0.masks = [m] }
        if let cg = render(s, geometry: false, overlay: m) { ov.append((label + " overlay", cg)) }
    }
    if let sh = sheet(ov) { saveJPEG(sh, "\(stem)-overlays.jpg") }

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
        } else { print(" EXPORT FAILED") }
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
