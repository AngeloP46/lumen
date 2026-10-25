import SwiftUI
import UIKit

// MARK: - Stage (where the picture sits while cropping)

/// While cropping, the frame stays big on screen and the picture moves and zooms under it (Photos, Lightroom): the view
/// is worked out from the crop, so a pinch or a drag that changes the crop looks like moving the photo under a fixed
/// frame. docs/CROP-REWORK.md.
enum CropStage {
    /// The room the frame may use: a margin all round, so no corner sits under a button or the system's edge swipe.
    static func rect(in canvas: CGSize) -> CGRect {
        let side: CGFloat = 28, top: CGFloat = 58, bottom: CGFloat = 16
        return CGRect(x: side, y: top, width: max(canvas.width - 2 * side, 40), height: max(canvas.height - top - bottom, 40))
    }

    /// Zoom and pan (the `ViewXform` fields) that put the crop frame in the middle of the stage, as big as it will go.
    static func view(canvas: CGSize, image: CGSize, crop: CropRect) -> (zoom: CGFloat, pan: CGSize) {
        guard image.width > 0, image.height > 0, canvas.width > 0, canvas.height > 0 else { return (1, .zero) }
        let stage = rect(in: canvas)
        let fit = min(canvas.width / image.width, canvas.height / image.height)       // zoom 1: the whole picture
        let cw = CGFloat(max(crop.w, 0.02)) * image.width, ch = CGFloat(max(crop.h, 0.02)) * image.height
        let scale = min(min(stage.width / cw, stage.height / ch), fit * 8)             // never more than 8x
        let centre = CGPoint(x: CGFloat(crop.l + crop.r) / 2 - 0.5, y: CGFloat(crop.t + crop.b) / 2 - 0.5)
        let imageMid = CGPoint(x: stage.midX - centre.x * image.width * scale, y: stage.midY - centre.y * image.height * scale)
        return (scale / fit, CGSize(width: imageMid.x - canvas.width / 2, height: imageMid.y - canvas.height / 2))
    }
}

/// The picture and the crop frame, drawn from an animatable view state so the stage can glide to its new size after a
/// handle is let go (instead of jumping), while a pinch or a drag follows the fingers exactly.
struct CropStageCanvas: View, Animatable {
    let model: CanvasModel
    @ObservedObject var vm: EditorViewModel
    let canvas: CGSize
    let hdr: Bool
    var zoom: CGFloat
    var panX: CGFloat
    var panY: CGFloat
    var onResize: (Bool) -> Void

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(zoom, AnimatablePair(panX, panY)) }
        set { zoom = newValue.first; panX = newValue.second.first; panY = newValue.second.second }
    }

    var body: some View {
        let xform = ViewXform(canvas: canvas, image: vm.imageSize, zoom: zoom, pan: CGSize(width: panX, height: panY))
        ZStack {
            CanvasView(model: model, xform: xform, hdr: hdr).allowsHitTesting(false)
            CropOverlay(vm: vm, xform: xform, onResize: onResize)
        }
        .frame(width: canvas.width, height: canvas.height)
    }
}

// MARK: - Straighten dial

/// A ruler under the photo: drag it like a physical dial (the ticks follow the finger), a click each degree, double-tap
/// puts it back to 0. Reads and writes degrees.
struct RulerDial: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -45...45
    var axID = "Straighten"
    @State private var base: Double?

    private let perDegree: CGFloat = 9

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let span = Double(cx / perDegree) + 1
            let lo = max(Int(floor(value - span)), Int(range.lowerBound)), hi = min(Int(ceil(value + span)), Int(range.upperBound))
            guard lo <= hi else { return }
            for d in lo...hi {
                let x = cx + CGFloat(Double(d) - value) * perDegree
                let zero = d == 0, major = d % 5 == 0
                let h: CGFloat = zero ? 24 : major ? 17 : 10
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height - 8)); p.addLine(to: CGPoint(x: x, y: size.height - 8 - h))
                ctx.stroke(p, with: .color(zero ? Theme.accent : Color.white.opacity(major ? 0.75 : 0.35)), lineWidth: zero ? 2 : 1)
                if d % 10 == 0 && !zero {
                    ctx.draw(Text("\(abs(d))").font(.system(size: 9, weight: .medium)).foregroundStyle(Color.white.opacity(0.55)),
                             at: CGPoint(x: x, y: size.height - 8 - h - 8))
                }
            }
        }
        .overlay(alignment: .bottom) {
            // the fixed pointer the ticks pass under
            Capsule().fill(Color.white).frame(width: 2.5, height: 30).padding(.bottom, 4).allowsHitTesting(false)
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                     .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .frame(height: 52)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if base == nil { base = value }
                let old = value
                let raw = (base ?? 0) - Double(v.translation.width / perDegree)
                let next = (min(max(raw, range.lowerBound), range.upperBound) * 10).rounded() / 10
                if next != value { value = next }
                if Int(next.rounded()) != Int(old.rounded()) { UISelectionFeedbackGenerator().selectionChanged() }
            }
            .onEnded { _ in base = nil })
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("slider-" + axID)
        .accessibilityLabel("Straighten")
        .accessibilityValue(String(format: "%.1f", value))
        .accessibilityAdjustableAction { dir in
            value = min(max(value + (dir == .increment ? 0.5 : -0.5), range.lowerBound), range.upperBound)
        }
    }
}

// MARK: - Panel

struct CropPanel: View {
    @ObservedObject var vm: EditorViewModel
    @AppStorage("cropTab") private var tab = "Crop"
    @AppStorage("cropGrid") private var grid = "thirds"
    @State private var askCustom = false
    @State private var customW = ""
    @State private var customH = ""

    private let ratios: [(String, Double)] = [
        ("1:1", 1), ("5:4", 1.25), ("4:3", 4.0 / 3), ("7:5", 1.4), ("3:2", 1.5), ("16:9", 16.0 / 9), ("2:1", 2), ("3:1", 3),
    ]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(["Crop", "Transform"], id: \.self) { t in
                    Button { tab = t } label: {
                        HStack(spacing: 4) {
                            Text(t).font(.system(size: 13, weight: .semibold))
                            if t == "Transform" && (vm.settings.hasTransform) { EditedDot() }
                        }
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(tab == t ? Theme.accent.opacity(0.85) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(tab == t ? Color.white : Color(white: 0.65))
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("crop-tab-\(t)")
                }
            }
            .padding(2)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 12)
            if tab == "Transform" { transform } else { crop }
        }
        .padding(.top, 4)
        .alert("Custom ratio", isPresented: $askCustom) {
            TextField("Width", text: $customW).keyboardType(.decimalPad)
            TextField("Height", text: $customH).keyboardType(.decimalPad)
            Button("Set") {
                if let w = Double(customW.replacingOccurrences(of: ",", with: ".")),
                   let h = Double(customH.replacingOccurrences(of: ",", with: ".")), w > 0, h > 0 {
                    vm.setCropAspect(min(max(w / h, 0.1), 10))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("For example 4 and 5 for 4:5.") }
    }

    // MARK: Crop tab

    private var crop: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Chip(title: "Free", selected: vm.settings.cropAspect == 0) { vm.setCropAspect(0) }
                        Chip(title: "Original", selected: matches(vm.originalAspect)) { vm.setCropAspect(vm.originalAspect) }
                        ForEach(ratios, id: \.0) { name, r in
                            Chip(title: name, selected: matches(r)) { vm.selectCropRatio(r) }
                        }
                        Chip(title: "Custom", system: "plus") { customW = ""; customH = ""; askCustom = true }
                            .accessibilityIdentifier("crop-custom")
                    }
                    .padding(.horizontal, 12)
                }
                // straighten: the ruler, its angle and one-tap levelling from the horizon
                HStack(spacing: 8) {
                    Button { vm.autoLevel() } label: {
                        HStack(spacing: 4) {
                            if vm.levelling { ProgressView().controlSize(.mini) } else { Image(systemName: "level") }
                            Text("Auto")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(Theme.chip, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .accessibilityIdentifier("crop-auto-level")
                    RulerDial(value: Binding(get: { vm.settings.straighten }, set: { vm.settings.straighten = $0 }))
                    Text(String(format: "%.1f°", vm.settings.straighten))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(vm.settings.straighten == 0 ? Color(white: 0.6) : Theme.accent)
                        .frame(width: 50, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                HStack(spacing: 2) {
                    IconButton(system: "rotate.left") { rotate(-1) }.accessibilityIdentifier("crop-rotate-left")
                    IconButton(system: "rotate.right") { rotate(1) }.accessibilityIdentifier("crop-rotate-right")
                    IconButton(system: "arrow.left.and.right.righttriangle.left.righttriangle.right", active: isFlipped(horizontal: true)) {
                        flip(horizontal: true)
                    }
                    .accessibilityIdentifier("crop-flip-h")
                    IconButton(system: "arrow.up.and.down.righttriangle.up.righttriangle.down", active: isFlipped(horizontal: false)) {
                        flip(horizontal: false)
                    }
                    .accessibilityIdentifier("crop-flip-v")
                    IconButton(system: "rectangle.portrait.rotate", disabled: vm.settings.cropAspect == 0) { vm.flipCropOrientation() }
                        .accessibilityIdentifier("crop-orientation")
                    Menu {
                        ForEach([("thirds", "Thirds"), ("golden", "Golden ratio"), ("diagonal", "Diagonals"),
                                 ("grid", "Fine grid"), ("none", "No grid")], id: \.0) { key, name in
                            Button { grid = key } label: { Label(name, systemImage: grid == key ? "checkmark" : "grid") }
                        }
                    } label: {
                        Image(systemName: "squareshape.split.3x3").font(.system(size: 17))
                            .frame(width: 38, height: 38).foregroundStyle(.white)
                    }
                    .accessibilityIdentifier("crop-grid")
                    Spacer(minLength: 2)
                    PillButton(title: "Reset", system: "arrow.counterclockwise") { vm.settings.reset(.crop) }
                        .accessibilityIdentifier("crop-reset")
                }
                .padding(.horizontal, 10)
            }
        }
    }

    // MARK: Transform tab

    private var transform: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                HStack {
                    Text("Perspective, stretch and position.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    PillButton(title: "Reset", system: "arrow.counterclockwise") {
                        var s = vm.settings
                        s.tVertical = 0; s.tHorizontal = 0; s.tAspect = 0; s.tScale = 100; s.tOffX = 0; s.tOffY = 0
                        vm.settings = s
                    }
                    .opacity(vm.settings.hasTransform ? 1 : 0.45)
                    .disabled(!vm.settings.hasTransform)
                    .accessibilityIdentifier("transform-reset")
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                Toggle(isOn: Binding(get: { vm.settings.tFill }, set: { vm.settings.tFill = $0 })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keep the crop inside the photo").font(.system(size: 13))
                        Text("No empty corners after straightening or perspective").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 2)
                .accessibilityIdentifier("transform-fill")
                row("Vertical", \.tVertical)
                row("Horizontal", \.tHorizontal)
                row("Aspect", \.tAspect)
                row("Scale", \.tScale, range: 50...150, neutral: 100)
                row("X offset", \.tOffX)
                row("Y offset", \.tOffY)
            }
        }
    }

    private func row(_ title: String, _ kp: WritableKeyPath<EditSettings, Double>,
                     range: ClosedRange<Double> = -100...100, neutral: Double = 0) -> some View {
        LabeledSlider(title: title, value: Binding(get: { vm.settings[keyPath: kp] }, set: { vm.settings[keyPath: kp] = $0 }),
                      range: range, neutral: neutral)
            .padding(.horizontal, 14)
    }

    // MARK: Flip (as seen on screen)

    /// The flips are stored before the 90° turns, so with the photo on its side a left-right flip on screen is an
    /// up-down flip of the stored photo.
    private func isFlipped(horizontal: Bool) -> Bool {
        let sideways = ((vm.settings.quarterTurns % 2) + 2) % 2 == 1
        return (horizontal != sideways) ? vm.settings.flipH : vm.settings.flipV
    }

    /// Mirrors the photo on screen and the crop frame with it, so the same part stays framed.
    private func flip(horizontal: Bool) {
        var s = vm.settings
        let sideways = ((s.quarterTurns % 2) + 2) % 2 == 1
        if horizontal != sideways { s.flipH.toggle() } else { s.flipV.toggle() }
        if horizontal {
            (s.cropL, s.cropR) = (1 - s.cropR, 1 - s.cropL)
        } else {
            (s.cropT, s.cropB) = (1 - s.cropB, 1 - s.cropT)
        }
        s.straighten = -s.straighten
        vm.settings = s
    }

    private func matches(_ r: Double) -> Bool {
        let a = vm.settings.cropAspect
        guard a > 0 else { return false }
        return abs(max(a, 1 / a) - max(r, 1 / r)) < 0.002
    }

    /// The crop turns with the picture (like Lightroom), so nothing you framed is lost. In normalised coordinates
    /// (y down) a quarter turn clockwise maps (x, y) to (1 - y, x) and anticlockwise to (y, 1 - x); a locked ratio
    /// turns too (3:2 becomes 2:3).
    private func rotate(_ d: Int) {
        var s = vm.settings
        let (l, t, r, b) = (s.cropL, s.cropT, s.cropR, s.cropB)
        s.quarterTurns += d
        if d > 0 {
            (s.cropL, s.cropT, s.cropR, s.cropB) = (1 - b, l, 1 - t, r)
        } else {
            (s.cropL, s.cropT, s.cropR, s.cropB) = (t, 1 - r, b, 1 - l)
        }
        if s.cropAspect > 0 { s.cropAspect = 1 / s.cropAspect }
        vm.settings = s
    }
}

extension EditorViewModel {
    /// A ratio from the chip row, turned to match whether the picture is portrait or landscape.
    func selectCropRatio(_ r: Double) {
        let portrait = imageSize.height > imageSize.width
        let oriented = (r != 1 && (r < 1) != portrait) ? 1 / r : r
        setCropAspect(oriented)
    }

    /// The crop frame as the Crop tool shows it: the frame used (kept on photo), not necessarily the one asked for.
    var cropRect: CropRect {
        settings.cropVersion == nil ? CropRect(l: settings.cropL, t: settings.cropT, r: settings.cropR, b: settings.cropB)
                                    : settings.cropUsed(source: sourceSize)
    }

    /// A frame moved from `start` (all photo) towards `target`: it stops at the photo's edge while Keep inside is on.
    func cropKeptOnPhoto(from start: CropRect, to target: CropRect) -> CropRect {
        guard settings.tFill, settings.cropVersion != nil, sourceSize.width > 0 else { return target }
        return CropFit.limit(from: start, to: target, in: settings.cropRegion(source: sourceSize))
    }
}

// MARK: - On-photo frame

/// The crop frame: dimmed outside, a grid inside. Corner and edge handles have 48 pt grab areas that reach outside the
/// frame; dragging one moves it by how far the finger moved, and the picture does not rescale until the finger lifts.
/// One finger anywhere else moves the photo under the frame; two fingers (`EditorView.twoFingers`) zoom it.
struct CropOverlay: View {
    @ObservedObject var vm: EditorViewModel
    let xform: ViewXform
    var onResize: (Bool) -> Void = { _ in }

    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }

    @AppStorage("cropGrid") private var grid = "thirds"
    @State private var mode: Edges?
    @State private var moving = false
    @State private var start = CropRect.full
    @State private var startImage = CGSize.zero
    @State private var afterPinch = false

    private let minSize = 0.06

    private var frame: CGRect {
        let r = xform.rect
        let s = vm.settings
        return CGRect(x: r.minX + CGFloat(s.cropL) * r.width, y: r.minY + CGFloat(s.cropT) * r.height,
                      width: CGFloat(s.cropR - s.cropL) * r.width, height: CGFloat(s.cropB - s.cropT) * r.height)
    }

    var body: some View {
        let f = frame
        return ZStack {
            dim(f)
            gridLines(f)
            Rectangle().stroke(Color.white, lineWidth: 1.4)
                .frame(width: f.width, height: f.height)
                .position(x: f.midX, y: f.midY)
                .allowsHitTesting(false)
            handles(f)
            touchLayer
        }
        .frame(width: xform.canvas.width, height: xform.canvas.height)
        .coordinateSpace(name: "cropSpace")
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("crop-frame")
        .accessibilityValue(String(format: "l %.2f t %.2f r %.2f b %.2f",
                                   vm.settings.cropL, vm.settings.cropT, vm.settings.cropR, vm.settings.cropB))
        // the frame's place on screen, for the UI tests
        .overlay { frameMarker(f) }
    }

    /// Everything outside the frame, dimmed.
    private func dim(_ f: CGRect) -> some View {
        Path { p in
            p.addRect(xform.rect)
            p.addRect(f)
        }
        .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    /// The composition grid (chosen in the crop panel); denser while a handle is held.
    private func gridLines(_ f: CGRect) -> some View {
        let fractions: [CGFloat]
        switch grid {
        case "none": fractions = []
        case "golden": fractions = [0.382, 0.618]
        case "grid": fractions = (1..<9).map { CGFloat($0) / 9 }
        case "diagonal": fractions = []
        default: fractions = mode != nil ? [1.0 / 6, 2.0 / 6, 3.0 / 6, 4.0 / 6, 5.0 / 6] : [1.0 / 3, 2.0 / 3]
        }
        return Path { p in
            for k in fractions {
                let x = f.minX + f.width * k, y = f.minY + f.height * k
                p.move(to: CGPoint(x: x, y: f.minY)); p.addLine(to: CGPoint(x: x, y: f.maxY))
                p.move(to: CGPoint(x: f.minX, y: y)); p.addLine(to: CGPoint(x: f.maxX, y: y))
            }
            if grid == "diagonal" {
                p.move(to: CGPoint(x: f.minX, y: f.minY)); p.addLine(to: CGPoint(x: f.maxX, y: f.maxY))
                p.move(to: CGPoint(x: f.maxX, y: f.minY)); p.addLine(to: CGPoint(x: f.minX, y: f.maxY))
            }
        }
        .stroke(Color.white.opacity(0.4), lineWidth: 0.7)
        .allowsHitTesting(false)
    }

    /// Corner brackets and edge bars: where to take hold.
    private func handles(_ f: CGRect) -> some View {
        let len: CGFloat = min(28, min(f.width, f.height) / 3)
        let bar: CGFloat = min(18, min(f.width, f.height) / 5)
        let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(f.minX, f.minY, 1, 1), (f.maxX, f.minY, -1, 1),
                                                               (f.minX, f.maxY, 1, -1), (f.maxX, f.maxY, -1, -1)]
        return Path { p in
            for (cx, cy, sx, sy) in corners {
                p.move(to: CGPoint(x: cx + sx * len, y: cy)); p.addLine(to: CGPoint(x: cx, y: cy))
                p.addLine(to: CGPoint(x: cx, y: cy + sy * len))
            }
            p.move(to: CGPoint(x: f.midX - bar, y: f.minY)); p.addLine(to: CGPoint(x: f.midX + bar, y: f.minY))
            p.move(to: CGPoint(x: f.midX - bar, y: f.maxY)); p.addLine(to: CGPoint(x: f.midX + bar, y: f.maxY))
            p.move(to: CGPoint(x: f.minX, y: f.midY - bar)); p.addLine(to: CGPoint(x: f.minX, y: f.midY + bar))
            p.move(to: CGPoint(x: f.maxX, y: f.midY - bar)); p.addLine(to: CGPoint(x: f.maxX, y: f.midY + bar))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        .shadow(color: Color.black.opacity(0.5), radius: 2)
        .allowsHitTesting(false)
    }

    private func frameMarker(_ f: CGRect) -> some View {
        Color.clear.frame(width: f.width, height: f.height).position(x: f.midX, y: f.midY)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("crop-box")
    }

    /// One finger: a handle resizes the frame, anywhere else moves the photo under it.
    private var touchLayer: some View {
        Color.clear.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cropSpace"))
                .onChanged { v in
                    if afterPinch { return }
                    if mode == nil && !moving { begin(at: v.startLocation) }
                    update(v)
                }
                .onEnded { _ in
                    let wasResizing = mode != nil
                    mode = nil; moving = false; afterPinch = false
                    if wasResizing { onResize(false) }
                })
    }

    // MARK: Gesture

    /// Which handle a touch at `loc` takes hold of: a corner (48 pt square centred on it), an edge (48 pt band along
    /// it, between the corners), or none (the photo moves instead).
    static func handle(at loc: CGPoint, in f: CGRect) -> Edges {
        let c = min(30, min(f.width, f.height) / 3)      // corner zone half-size, smaller for a tiny frame
        let e: CGFloat = 24                               // edge zone half-thickness
        let nearL = abs(loc.x - f.minX) <= c, nearR = abs(loc.x - f.maxX) <= c
        let nearT = abs(loc.y - f.minY) <= c, nearB = abs(loc.y - f.maxY) <= c
        if (nearL || nearR) && (nearT || nearB) {
            var out: Edges = []
            out.insert(abs(loc.x - f.minX) <= abs(loc.x - f.maxX) ? .left : .right)
            out.insert(abs(loc.y - f.minY) <= abs(loc.y - f.maxY) ? .top : .bottom)
            return out
        }
        let inX = loc.x >= f.minX && loc.x <= f.maxX, inY = loc.y >= f.minY && loc.y <= f.maxY
        if inY && abs(loc.x - f.minX) <= e { return .left }
        if inY && abs(loc.x - f.maxX) <= e { return .right }
        if inX && abs(loc.y - f.minY) <= e { return .top }
        if inX && abs(loc.y - f.maxY) <= e { return .bottom }
        return []
    }

    private func begin(at loc: CGPoint) {
        start = vm.cropRect
        startImage = xform.rect.size
        let e = Self.handle(at: loc, in: frame)
        if e.isEmpty { moving = true } else { mode = e; onResize(true) }
    }

    private func update(_ v: DragGesture.Value) {
        // a second finger landed: this is a pinch now, put the frame back where it was
        if vm.pinching {
            if moving || mode != nil { vm.setCropFrame(start.l, start.t, start.r, start.b) }
            if mode != nil { onResize(false) }
            moving = false; mode = nil
            afterPinch = true   // the finger left on the glass after the pinch does nothing until it lifts
            return
        }
        guard startImage.width > 0, startImage.height > 0 else { return }
        let dx = Double(v.translation.width / startImage.width), dy = Double(v.translation.height / startImage.height)
        if moving {
            // the photo follows the finger, so the frame moves the other way over it
            let r = vm.cropKeptOnPhoto(from: start, to: CropMath.panned(start, dx: -dx, dy: -dy))
            vm.setCropFrame(r.l, r.t, r.r, r.b)
            return
        }
        guard let e = mode else { return }
        // the handle moves by what the finger moved (not to where the finger is: no jump, and the thumb can cover it)
        let hx = e.contains(.left) ? start.l : e.contains(.right) ? start.r : 0
        let hy = e.contains(.top) ? start.t : e.contains(.bottom) ? start.b : 0
        let p = Pt(x: hx + dx, y: hy + dy)
        let lock = vm.settings.cropAspect
        let a0 = max(Double(xform.image.width / max(xform.image.height, 1)), 0.01)
        var (l, t, r, b) = (start.l, start.t, start.r, start.b)

        if lock <= 0 {
            if e.contains(.left) { l = min(max(p.x, 0), r - minSize) }
            if e.contains(.right) { r = max(min(p.x, 1), l + minSize) }
            if e.contains(.top) { t = min(max(p.y, 0), b - minSize) }
            if e.contains(.bottom) { b = max(min(p.y, 1), t + minSize) }
            let k = vm.cropKeptOnPhoto(from: start, to: CropRect(l: l, t: t, r: r, b: b))
            vm.setCropFrame(k.l, k.t, k.r, k.b)
            return
        }

        // Locked ratio. In normalised units a frame of width w has height w * a0 / lock.
        let horizontal = e.contains(.left) || e.contains(.right)
        let vertical = e.contains(.top) || e.contains(.bottom)
        if horizontal && vertical {
            let ax = e.contains(.left) ? start.r : start.l
            let ay = e.contains(.top) ? start.b : start.t
            let sx: Double = p.x >= ax ? 1 : -1
            let sy: Double = p.y >= ay ? 1 : -1
            let wPtr = abs(p.x - ax), hPtr = abs(p.y - ay)
            var w = wPtr, h = wPtr * a0 / lock
            if h < hPtr { h = hPtr; w = hPtr * lock / a0 }
            let maxW = sx > 0 ? 1 - ax : ax, maxH = sy > 0 ? 1 - ay : ay
            let k = min(1, maxW / max(w, 1e-6), maxH / max(h, 1e-6))
            w = max(w * k, minSize); h = w * a0 / lock
            l = sx > 0 ? ax : ax - w; r = sx > 0 ? ax + w : ax
            t = sy > 0 ? ay : ay - h; b = sy > 0 ? ay + h : ay
        } else if horizontal {
            let anchor = e.contains(.left) ? start.r : start.l
            let cy = (start.t + start.b) / 2
            var w = abs(p.x - anchor)
            var h = w * a0 / lock
            let maxH = 2 * min(cy, 1 - cy)
            if h > maxH { h = maxH; w = h * lock / a0 }
            let maxW = e.contains(.left) ? anchor : 1 - anchor
            if w > maxW { w = maxW; h = w * a0 / lock }
            w = max(w, minSize); h = w * a0 / lock
            if e.contains(.left) { l = anchor - w; r = anchor } else { l = anchor; r = anchor + w }
            t = cy - h / 2; b = cy + h / 2
        } else {
            let anchor = e.contains(.top) ? start.b : start.t
            let cx = (start.l + start.r) / 2
            var h = abs(p.y - anchor)
            var w = h * lock / a0
            let maxW = 2 * min(cx, 1 - cx)
            if w > maxW { w = maxW; h = w * a0 / lock }
            let maxH = e.contains(.top) ? anchor : 1 - anchor
            if h > maxH { h = maxH; w = h * lock / a0 }
            h = max(h, minSize * 0.5); w = h * lock / a0
            if e.contains(.top) { t = anchor - h; b = anchor } else { t = anchor; b = anchor + h }
            l = cx - w / 2; r = cx + w / 2
        }
        let k = vm.cropKeptOnPhoto(from: start, to: CropRect(l: max(l, 0), t: max(t, 0), r: min(r, 1), b: min(b, 1)))
        vm.setCropFrame(k.l, k.t, k.r, k.b)
    }
}
