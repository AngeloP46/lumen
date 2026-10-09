import SwiftUI

// MARK: - Panel

struct CropPanel: View {
    @ObservedObject var vm: EditorViewModel

    private let ratios: [(String, Double)] = [
        ("1:1", 1), ("5:4", 1.25), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("2:1", 2),
    ]

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Chip(title: "Free", selected: vm.settings.cropAspect == 0) { vm.setCropAspect(0) }
                    Chip(title: "Original", selected: matches(vm.originalAspect)) { vm.setCropAspect(vm.originalAspect) }
                    ForEach(ratios, id: \.0) { name, r in
                        Chip(title: name, selected: matches(r)) { vm.selectCropRatio(r) }
                    }
                }
                .padding(.horizontal, 12)
            }
            HStack(spacing: 4) {
                IconButton(system: "rotate.left") { rotate(-1) }
                IconButton(system: "rotate.right") { rotate(1) }
                IconButton(system: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                           disabled: vm.settings.cropAspect == 0) { vm.flipCropOrientation() }
                Spacer()
                Button {
                    vm.resetCropFrame()
                    vm.settings.straighten = 0
                    vm.settings.quarterTurns = 0
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(Theme.chip, in: Capsule())
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("crop-reset")
            }
            .padding(.horizontal, 10)
            LabeledSlider(title: "Straighten",
                          value: Binding(get: { vm.settings.straighten }, set: { vm.settings.straighten = $0 }),
                          range: -45...45, decimals: 1, neutral: 0, axID: "Straighten")
                .padding(.horizontal, 14)
        }
        .padding(.top, 4)
    }

    private func matches(_ r: Double) -> Bool {
        let a = vm.settings.cropAspect
        guard a > 0 else { return false }
        return abs(max(a, 1 / a) - max(r, 1 / r)) < 0.002
    }

    private func rotate(_ d: Int) {
        // the frame keeps its shape relative to the picture, so just turn the picture
        vm.settings.quarterTurns += d
        vm.resetCropFrame()
    }
}

extension EditorViewModel {
    /// A ratio from the chip row, turned to match whether the picture is portrait or landscape.
    func selectCropRatio(_ r: Double) {
        let portrait = imageSize.height > imageSize.width
        let oriented = (r != 1 && (r < 1) != portrait) ? 1 / r : r
        setCropAspect(oriented)
    }
}

// MARK: - On-photo frame

/// The crop frame: dimmed outside, thirds grid inside, drag the corners/edges to resize, drag inside to move.
struct CropOverlay: View {
    @ObservedObject var vm: EditorViewModel
    let xform: ViewXform

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }

    @State private var mode: Edges?
    @State private var moving = false
    @State private var start = (l: 0.0, t: 0.0, r: 1.0, b: 1.0)
    @State private var startPoint = Pt(x: 0, y: 0)

    private let minSize = 0.06

    private var frame: CGRect {
        let r = xform.rect
        let s = vm.settings
        return CGRect(x: r.minX + CGFloat(s.cropL) * r.width, y: r.minY + CGFloat(s.cropT) * r.height,
                      width: CGFloat(s.cropR - s.cropL) * r.width, height: CGFloat(s.cropB - s.cropT) * r.height)
    }

    var body: some View {
        let f = frame
        ZStack {
            // dim everything outside the frame
            Path { p in
                p.addRect(xform.rect)
                p.addRect(f)
            }
            .fill(Color.black.opacity(0.58), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // thirds
            Path { p in
                for i in 1..<3 {
                    let x = f.minX + f.width * CGFloat(i) / 3, y = f.minY + f.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: f.minY)); p.addLine(to: CGPoint(x: x, y: f.maxY))
                    p.move(to: CGPoint(x: f.minX, y: y)); p.addLine(to: CGPoint(x: f.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.7)
            .allowsHitTesting(false)

            Rectangle().stroke(Color.white, lineWidth: 1.4)
                .frame(width: f.width, height: f.height)
                .position(x: f.midX, y: f.midY)
                .allowsHitTesting(false)

            // corner brackets and edge bars
            Path { p in
                let len: CGFloat = 22
                for (cx, cy, sx, sy) in [(f.minX, f.minY, 1.0, 1.0), (f.maxX, f.minY, -1.0, 1.0),
                                         (f.minX, f.maxY, 1.0, -1.0), (f.maxX, f.maxY, -1.0, -1.0)] {
                    p.move(to: CGPoint(x: cx + CGFloat(sx) * len, y: cy)); p.addLine(to: CGPoint(x: cx, y: cy))
                    p.addLine(to: CGPoint(x: cx, y: cy + CGFloat(sy) * len))
                }
                let bar: CGFloat = 14
                p.move(to: CGPoint(x: f.midX - bar, y: f.minY)); p.addLine(to: CGPoint(x: f.midX + bar, y: f.minY))
                p.move(to: CGPoint(x: f.midX - bar, y: f.maxY)); p.addLine(to: CGPoint(x: f.midX + bar, y: f.maxY))
                p.move(to: CGPoint(x: f.minX, y: f.midY - bar)); p.addLine(to: CGPoint(x: f.minX, y: f.midY + bar))
                p.move(to: CGPoint(x: f.maxX, y: f.midY - bar)); p.addLine(to: CGPoint(x: f.maxX, y: f.midY + bar))
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            .allowsHitTesting(false)

            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cropSpace"))
                    .onChanged { v in
                        if mode == nil && !moving {
                            begin(at: v.startLocation)
                        }
                        update(to: v.location)
                    }
                    .onEnded { _ in mode = nil; moving = false })
        }
        .frame(width: xform.canvas.width, height: xform.canvas.height)
        .coordinateSpace(name: "cropSpace")
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("crop-frame")
        .accessibilityValue(String(format: "l %.2f t %.2f r %.2f b %.2f",
                                   vm.settings.cropL, vm.settings.cropT, vm.settings.cropR, vm.settings.cropB))
    }

    // MARK: Gesture

    private func begin(at loc: CGPoint) {
        let f = frame
        let s = vm.settings
        start = (s.cropL, s.cropT, s.cropR, s.cropB)
        startPoint = xform.normalised(loc)
        let grab: CGFloat = 34
        let nearL = abs(loc.x - f.minX) < grab, nearR = abs(loc.x - f.maxX) < grab
        let nearT = abs(loc.y - f.minY) < grab, nearB = abs(loc.y - f.maxY) < grab
        let inX = loc.x > f.minX - grab && loc.x < f.maxX + grab
        let inY = loc.y > f.minY - grab && loc.y < f.maxY + grab
        var e: Edges = []
        if nearL && inY { e.insert(.left) } else if nearR && inY { e.insert(.right) }
        if nearT && inX { e.insert(.top) } else if nearB && inX { e.insert(.bottom) }
        if !e.isEmpty { mode = e; return }
        if f.contains(loc) { moving = true }
    }

    private func update(to loc: CGPoint) {
        let p = xform.normalised(loc)
        if moving {
            let w = start.r - start.l, h = start.b - start.t
            let nl = min(max(start.l + (p.x - startPoint.x), 0), 1 - w)
            let nt = min(max(start.t + (p.y - startPoint.y), 0), 1 - h)
            vm.setCropFrame(nl, nt, nl + w, nt + h)
            return
        }
        guard let e = mode else { return }
        let lock = vm.settings.cropAspect
        let a0 = max(Double(xform.image.width / max(xform.image.height, 1)), 0.01)
        var (l, t, r, b) = start

        if lock <= 0 {
            if e.contains(.left) { l = min(max(p.x, 0), r - minSize) }
            if e.contains(.right) { r = max(min(p.x, 1), l + minSize) }
            if e.contains(.top) { t = min(max(p.y, 0), b - minSize) }
            if e.contains(.bottom) { b = max(min(p.y, 1), t + minSize) }
            vm.setCropFrame(l, t, r, b)
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
        vm.setCropFrame(max(l, 0), max(t, 0), min(r, 1), min(b, 1))
    }
}
