import SwiftUI
import UIKit

// MARK: - Stage (where the picture sits while cropping)

/// While cropping, the frame stays big on screen and the picture moves and zooms under it (Photos, Lightroom): the view
/// is worked out from the crop, so a pinch or a drag that changes the crop looks like moving the photo under a fixed
/// frame. docs/CROP-REWORK.md.
enum CropStage {
    /// The room the frame may use: a margin all round, so no corner sits under a button or the system's edge swipe.
    /// The top buttons' strip: the picture is not drawn there.
    static let clearTop: CGFloat = 48

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
            // nothing of the photo behind the top buttons (a warped or zoomed picture reached up under them)
            CanvasView(model: model, xform: xform, hdr: hdr).allowsHitTesting(false)
                .mask { VStack(spacing: 0) { Color.clear.frame(height: CropStage.clearTop); Color.black } }
            CropOverlay(vm: vm, xform: xform, onResize: onResize)
        }
        .frame(width: canvas.width, height: canvas.height)
    }
}

// MARK: - Ruler dial (straighten and perspective)

/// A ruler under the photo, as in Photos and Photomator: drag it like a physical dial (the ticks follow the finger), a
/// click at each tick, double-tap puts it back to its neutral value. Numbers sit above the ticks, a pointer below the
/// middle. Straighten: a tick is a degree; perspective: two units of the -100...100 scale.
struct RulerDial: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -45...45
    var neutral: Double = 0
    /// What one tick is worth, and how many ticks from one number to the next
    var step: Double = 1
    var labelEvery = 5
    var decimals = 1
    var axID = "Straighten"
    var label = "Straighten"
    /// A finger is on the dial (the crop shows a fine grid meanwhile)
    var onActive: (Bool) -> Void = { _ in }
    @State private var base: Double?

    private let perTick: CGFloat = 9

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let pos = value / step                                  // the pointer's place, in ticks
            let span = Double(cx / perTick) + 1
            let lo = max(Int((pos - span).rounded(.down)), Int((range.lowerBound / step).rounded(.up)))
            let hi = min(Int((pos + span).rounded(.up)), Int((range.upperBound / step).rounded(.down)))
            let ground = size.height - 16                           // the ticks stand on this line, the pointer below it
            if lo <= hi {
                for i in lo...hi {
                    let x = cx + CGFloat(Double(i) - pos) * perTick
                    let major = i % labelEvery == 0
                    let h: CGFloat = major ? 14 : 8
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: ground)); p.addLine(to: CGPoint(x: x, y: ground - h))
                    ctx.stroke(p, with: .color(Color.white.opacity(major ? 0.8 : 0.35)), lineWidth: major ? 1.4 : 1)
                    if major {
                        let v = Double(i) * step
                        let home = abs(v - neutral) < step / 2
                        ctx.draw(Text("\(Int(v.rounded()))")
                                    .font(.system(size: 12, weight: home ? .semibold : .regular).monospacedDigit())
                                    .foregroundStyle(Color.white.opacity(home ? 0.95 : 0.55)),
                                 at: CGPoint(x: x, y: ground - h - 10))
                    }
                }
            }
            // where the value is: a line over the ticks (accent once moved) and a small pointer under them
            let moved = abs(value - neutral) > step / 20
            var line = Path()
            line.move(to: CGPoint(x: cx, y: ground + 1)); line.addLine(to: CGPoint(x: cx, y: ground - 18))
            ctx.stroke(line, with: .color(moved ? Theme.accent : .white), lineWidth: 2)
            var tip = Path()
            tip.move(to: CGPoint(x: cx, y: ground + 4))
            tip.addLine(to: CGPoint(x: cx - 6, y: ground + 13)); tip.addLine(to: CGPoint(x: cx + 6, y: ground + 13))
            tip.closeSubpath()
            ctx.fill(tip, with: .color(.white))
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14),
                                     .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .frame(height: 56)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if base == nil { base = value; onActive(true) }
                let old = value
                // past either end the ruler stays at the end, and turning back moves it at once (EndStop)
                var b = base ?? value
                let raw = EndStop.value(base: &b, delta: -Double(v.translation.width / perTick) * step, in: range)
                base = b
                let k = pow(10, Double(decimals))
                let next = (raw * k).rounded() / k
                if next != value { value = next }
                if Int((next / step).rounded()) != Int((old / step).rounded()) { UISelectionFeedbackGenerator().selectionChanged() }
            }
            .onEnded { _ in base = nil; onActive(false) })
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = neutral })
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("slider-" + axID)
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.\(decimals)f", value))
        .accessibilityAdjustableAction { dir in
            let d = decimals > 0 ? step / 2 : step
            value = min(max(value + (dir == .increment ? d : -d), range.lowerBound), range.upperBound)
        }
    }
}

/// A Photomator-style tile: icon and/or words on a rounded grey tile that takes the width it is given; accent when on.
struct CropTile: View {
    var title: String?
    var system: String?
    var active = false
    var busy = false

    var body: some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.small)
            } else if let system {
                Image(systemName: system).font(.system(size: 17, weight: .medium))
            }
            if let title { Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75) }
        }
        .frame(maxWidth: .infinity).frame(height: 44)
        .background(active ? Theme.accent.opacity(0.85) : Theme.chip, in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(Color.white)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Panel

/// Crop | Straighten | Perspective (owner, 25 Oct: perspective like Photomator's, a ruler and a choice of what it changes,
/// instead of six sliders). Every tab fits the same panel, so switching never moves the photo.
struct CropPanel: View {
    @ObservedObject var vm: EditorViewModel
    @AppStorage("cropTab") private var storedTab = "Crop"
    @AppStorage("cropGrid") private var grid = "thirds"
    @AppStorage("perspectiveAxis") private var axisKey = "vertical"
    @State private var askCustom = false
    @State private var customW = ""
    @State private var customH = ""

    private let ratios: [(String, Double)] = [
        ("1:1", 1), ("5:4", 1.25), ("4:3", 4.0 / 3), ("7:5", 1.4), ("3:2", 1.5), ("16:9", 16.0 / 9), ("2:1", 2), ("3:1", 3),
    ]
    private static let tabs = ["Crop", "Straighten", "Perspective"]

    /// What the perspective ruler changes. Scale and the moves matter mostly with Fill frame off (the photo on a bigger canvas).
    private struct Axis {
        let key: String, title: String, kp: WritableKeyPath<EditSettings, Double>
        var range: ClosedRange<Double> = -100...100
        var neutral: Double = 0
        var icon: String?
    }
    private static let axes: [Axis] = [
        Axis(key: "vertical", title: "Vertical", kp: \.tVertical),
        Axis(key: "horizontal", title: "Horizontal", kp: \.tHorizontal),
        Axis(key: "aspect", title: "Aspect", kp: \.tAspect),
        Axis(key: "scale", title: "Scale", kp: \.tScale, range: 50...150, neutral: 100),
        Axis(key: "moveX", title: "Move", kp: \.tOffX, icon: "arrow.left.and.right"),
        Axis(key: "moveY", title: "Move", kp: \.tOffY, icon: "arrow.up.and.down"),
    ]

    /// "Transform" was the second tab until 25 Oct.
    private var tab: String { storedTab == "Transform" ? "Perspective" : (Self.tabs.contains(storedTab) ? storedTab : "Crop") }
    /// Scale and the moves only matter with Fill frame off (the photo on a bigger canvas): with it on, pinching and moving
    /// the photo under the frame do the same, and two zooms disagreed (owner, 25 Oct). A photo that already uses them shows them.
    private var shownAxes: [Axis] {
        Self.axes.filter { x in
            ["vertical", "horizontal", "aspect"].contains(x.key) || !vm.settings.tFill || vm.settings[keyPath: x.kp] != x.neutral
        }
    }
    private var axis: Axis { shownAxes.first { $0.key == axisKey } ?? Self.axes[0] }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(Self.tabs, id: \.self) { t in
                    Button { storedTab = t } label: {
                        HStack(spacing: 4) {
                            Text(t).font(.system(size: 13, weight: .semibold))
                            if edited(t) { EditedDot() }
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
            ScrollView(showsIndicators: false) {
                switch tab {
                case "Straighten": straighten
                case "Perspective": perspective
                default: crop
                }
            }
        }
        .padding(.top, 4)
        .onDisappear { vm.cropGuides = false }
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

    private func edited(_ t: String) -> Bool {
        switch t {
        case "Straighten": return vm.settings.straighten != 0
        case "Perspective": return vm.settings.hasTransform
        default: return false
        }
    }

    // MARK: Crop tab

    private var crop: some View {
        VStack(spacing: 8) {
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
            // four equal tiles a row; Reset takes the width of two
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button { rotate(-1) } label: { CropTile(system: "rotate.left") }
                        .accessibilityIdentifier("crop-rotate-left").accessibilityLabel("Rotate left")
                    Button { rotate(1) } label: { CropTile(system: "rotate.right") }
                        .accessibilityIdentifier("crop-rotate-right").accessibilityLabel("Rotate right")
                    Button { flip(horizontal: true) } label: {
                        CropTile(system: "arrow.left.and.right.righttriangle.left.righttriangle.right", active: isFlipped(horizontal: true))
                    }
                    .accessibilityIdentifier("crop-flip-h").accessibilityLabel("Flip left to right")
                    Button { flip(horizontal: false) } label: {
                        CropTile(system: "arrow.up.and.down.righttriangle.up.righttriangle.down", active: isFlipped(horizontal: false))
                    }
                    .accessibilityIdentifier("crop-flip-v").accessibilityLabel("Flip upside down")
                }
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button { vm.flipCropOrientation() } label: { CropTile(system: "rectangle.portrait.rotate") }
                            .disabled(vm.settings.cropAspect == 0).opacity(vm.settings.cropAspect == 0 ? 0.4 : 1)
                            .accessibilityIdentifier("crop-orientation").accessibilityLabel("Portrait or landscape")
                        Menu {
                            ForEach([("thirds", "Thirds"), ("golden", "Golden ratio"), ("diagonal", "Diagonals"),
                                     ("grid", "Fine grid"), ("none", "No grid")], id: \.0) { key, name in
                                Button { grid = key } label: { Label(name, systemImage: grid == key ? "checkmark" : "grid") }
                            }
                        } label: { CropTile(system: "squareshape.split.3x3") }
                        .accessibilityIdentifier("crop-grid")
                    }
                    HStack(spacing: 8) {
                        // the zoom (pinch) and the way back to 1x
                        let z = vm.cropZoom
                        Button { withAnimation(.easeOut(duration: 0.28)) { vm.cropZoomToFit() } } label: {
                            CropTile(title: z > 1.02 ? String(format: "%.1f×", z) : "1×", system: "arrow.down.right.and.arrow.up.left")
                        }
                        .disabled(z <= 1.02).opacity(z > 1.02 ? 1 : 0.4)
                        .accessibilityIdentifier("crop-zoom").accessibilityLabel("Zoom back to 1x")
                        .accessibilityValue(String(format: "%.1f", z))
                        Button { vm.settings.reset(.crop) } label: { CropTile(title: "Reset", system: "arrow.counterclockwise") }
                            .disabled(!vm.settings.hasEdits(.crop)).opacity(vm.settings.hasEdits(.crop) ? 1 : 0.4)
                            .accessibilityIdentifier("crop-reset")
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: Straighten tab

    private var straighten: some View {
        VStack(spacing: 6) {
            Text(String(format: "%.1f°", vm.settings.straighten))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(vm.settings.straighten == 0 ? Color(white: 0.6) : Theme.accent)
                .accessibilityHidden(true)
            RulerDial(value: Binding(get: { vm.settings.straighten }, set: { vm.settings.straighten = $0 }),
                      onActive: { vm.cropGuides = $0 })
                .padding(.horizontal, 8)
            HStack(spacing: 8) {
                Button { vm.autoLevel() } label: { CropTile(title: "Auto", system: "level", busy: vm.levelling) }
                    .accessibilityIdentifier("crop-auto-level")
                fillFrame
                Button { vm.settings.straighten = 0 } label: { CropTile(title: "Reset", system: "arrow.counterclockwise") }
                    .disabled(vm.settings.straighten == 0).opacity(vm.settings.straighten == 0 ? 0.4 : 1)
                    .accessibilityIdentifier("straighten-reset")
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: Perspective tab

    private var perspective: some View {
        let a = axis
        return VStack(spacing: 6) {
            // what the ruler changes; a changed one shows its value
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(shownAxes, id: \.key) { x in
                        let v = vm.settings[keyPath: x.kp]
                        Chip(title: v == x.neutral ? x.title : "\(x.title) \(Int(v.rounded()))", system: x.icon, selected: x.key == a.key) { axisKey = x.key }
                            .accessibilityIdentifier("persp-\(x.key)")
                    }
                }
                .padding(.horizontal, 12)
            }
            RulerDial(value: Binding(get: { vm.settings[keyPath: a.kp] }, set: { vm.settings[keyPath: a.kp] = $0 }),
                      range: a.range, neutral: a.neutral, step: 2, decimals: 0, axID: a.key.prefix(1).uppercased() + a.key.dropFirst(), label: a.title,
                      onActive: { vm.cropGuides = $0 })
                .id(a.key)
                .padding(.horizontal, 8)
            HStack(spacing: 8) {
                fillFrame
                Button {
                    var s = vm.settings
                    s.tVertical = 0; s.tHorizontal = 0; s.tAspect = 0; s.tScale = 100; s.tOffX = 0; s.tOffY = 0
                    vm.settings = s
                } label: { CropTile(title: "Reset", system: "arrow.counterclockwise") }
                    .disabled(!vm.settings.hasTransform).opacity(vm.settings.hasTransform ? 1 : 0.4)
                    .accessibilityIdentifier("transform-reset")
            }
            .padding(.horizontal, 12)
        }
    }

    /// Fill frame: keep the crop on photo (no empty corners) after straightening or perspective.
    private var fillFrame: some View {
        Button { vm.settings.tFill.toggle() } label: {
            CropTile(title: "Fill frame", system: vm.settings.tFill ? "checkmark.circle.fill" : "circle", active: vm.settings.tFill)
        }
        .accessibilityIdentifier("transform-fill")
        .accessibilityLabel("Fill frame: no empty corners after straightening or perspective")
        .accessibilityValue(vm.settings.tFill ? "on" : "off")
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

    /// How far in the crop is zoomed: 1 = the biggest frame of its shape (kept on the photo). Pinching is the one zoom
    /// (owner, 25 Oct: a Scale ruler capped at 150 beside the pinch left two zooms that disagreed about where 1x was).
    var cropZoom: Double {
        let c = cropRect
        guard c.w > 0 else { return 1 }
        let f = CropMath.fullShape(c)
        var s = settings
        (s.cropL, s.cropT, s.cropR, s.cropB) = (f.l, f.t, f.r, f.b)
        let u = s.cropVersion == nil ? f : s.cropUsed(source: sourceSize)
        return max(u.w / c.w, 1)
    }

    /// Back to 1x: the biggest frame of the crop's shape, centred; straighten, perspective and the ratio stay.
    func cropZoomToFit() {
        let f = CropMath.fullShape(cropRect)
        setCropFrame(f.l, f.t, f.r, f.b)
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
    @State private var start = CropRect.full       // the frame as of the last step of the drag
    @State private var begun = CropRect.full       // the frame when the finger came down
    @State private var origin = CGSize.zero        // the finger's travel at the last step
    @State private var startImage = CGSize.zero
    @State private var afterPinch = false

    private let minSize = 0.06

    /// The frame used (kept on photo: it shrinks while straightening and grows back), not necessarily the one asked for.
    private var frame: CGRect {
        let r = xform.rect
        let c = vm.cropRect
        return CGRect(x: r.minX + CGFloat(c.l) * r.width, y: r.minY + CGFloat(c.t) * r.height,
                      width: CGFloat(c.w) * r.width, height: CGFloat(c.h) * r.height)
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
        .accessibilityValue(String(format: "l %.2f t %.2f r %.2f b %.2f", vm.cropRect.l, vm.cropRect.t, vm.cropRect.r, vm.cropRect.b))
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

    /// The composition grid (chosen in the crop panel); denser while a handle is held, a fine grid while the straighten or
    /// perspective ruler turns (lines to judge verticals and the horizon against, as in Photos and Photomator).
    private func gridLines(_ f: CGRect) -> some View {
        let fractions: [CGFloat]
        switch vm.cropGuides ? "guides" : grid {
        case "guides": fractions = (1..<8).map { CGFloat($0) / 8 }
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
            if grid == "diagonal" && !vm.cropGuides {
                p.move(to: CGPoint(x: f.minX, y: f.minY)); p.addLine(to: CGPoint(x: f.maxX, y: f.maxY))
                p.move(to: CGPoint(x: f.maxX, y: f.minY)); p.addLine(to: CGPoint(x: f.minX, y: f.maxY))
            }
        }
        .stroke(Color.white.opacity(vm.cropGuides ? 0.5 : 0.4), lineWidth: 0.7)
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
        begun = start
        origin = .zero
        startImage = xform.rect.size
        let e = Self.handle(at: loc, in: frame)
        if e.isEmpty { moving = true } else { mode = e; onResize(true) }
    }

    private func update(_ v: DragGesture.Value) {
        // a second finger landed: this is a pinch now, put the frame back where it was
        if vm.pinching {
            if moving || mode != nil { vm.setCropFrame(begun.l, begun.t, begun.r, begun.b) }
            if mode != nil { onResize(false) }
            moving = false; mode = nil
            afterPinch = true   // the finger left on the glass after the pinch does nothing until it lifts
            return
        }
        guard startImage.width > 0, startImage.height > 0 else { return }
        // step by step from where the frame is now: at a limit (the picture's or the photo's edge, the smallest frame)
        // it stays put, and moving back responds at once instead of after the finger has undone its overshoot
        let dx = Double((v.translation.width - origin.width) / startImage.width)
        let dy = Double((v.translation.height - origin.height) / startImage.height)
        defer { start = vm.cropRect; origin = v.translation }
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
