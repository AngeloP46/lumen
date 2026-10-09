import SwiftUI

// MARK: - Small shared bits

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var decimals = 0
    var neutral: Double?
    var labelWidth: CGFloat = 70
    var axID = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(Color(white: 0.8)).frame(width: labelWidth, alignment: .leading)
            ScrubSlider(value: $value, range: range, neutral: neutral, decimals: decimals, axID: axID)
            Text(decimals == 0 ? "\(Int(value.rounded()))" : String(format: "%.\(decimals)f", value))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
        }
        .frame(height: 34)
    }
}

// MARK: - Luminance range selector

/// Pick a band of brightness. The bar shows the photo's brightness spectrum with the selected band on it; drag the two
/// white handles for the band. The soft edges on the dark and the light side are two plain sliders, so either end can
/// be feathered no matter where the band sits. Quick presets for shadows / midtones / highlights.
struct LumRangeEditor: View {
    @Binding var low: Double
    @Binding var high: Double
    @Binding var lowFeather: Double
    @Binding var highFeather: Double
    let histogram: [Float]?

    @State private var active: Int?   // 0 = start handle, 1 = end handle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar
            HStack(spacing: 6) {
                preset("Shadows", 0, 0.30, 0, 0.15)
                preset("Midtones", 0.30, 0.70, 0.15, 0.15)
                preset("Highlights", 0.70, 1, 0.15, 0)
                preset("Whites", 0.88, 1, 0.10, 0)
            }
            LabeledSlider(title: "Dark edge", value: soft($lowFeather, limit: { low }), range: 0...50, neutral: 0, labelWidth: 66)
                .opacity(low <= 0.001 ? 0.35 : 1).allowsHitTesting(low > 0.001)
            LabeledSlider(title: "Light edge", value: soft($highFeather, limit: { 1 - high }), range: 0...50, neutral: 0, labelWidth: 66)
                .opacity(high >= 0.999 ? 0.35 : 1).allowsHitTesting(high < 0.999)
        }
    }

    /// Feather stored as 0...0.5, shown as 0...50 %, never reaching past the end of the scale.
    private func soft(_ b: Binding<Double>, limit: @escaping () -> Double) -> Binding<Double> {
        Binding(get: { b.wrappedValue * 100 }, set: { b.wrappedValue = min($0 / 100, max(limit(), 0)) })
    }

    private func preset(_ title: String, _ lo: Double, _ hi: Double, _ lf: Double, _ hf: Double) -> some View {
        let on = abs(low - lo) < 0.02 && abs(high - hi) < 0.02
        return Chip(title: title, selected: on) { low = lo; high = hi; lowFeather = lf; highFeather = hf }
    }

    private var bar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let barH: CGFloat = 30
            let x: (Double) -> CGFloat = { CGFloat(min(max($0, 0), 1)) * w }
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                    .frame(height: barH).clipShape(RoundedRectangle(cornerRadius: 6))
                if let h = histogram {
                    Canvas { ctx, size in
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: barH))
                        for (i, v) in h.enumerated() {
                            p.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(h.count - 1), y: barH * (1 - CGFloat(v))))
                        }
                        p.addLine(to: CGPoint(x: size.width, y: barH))
                        ctx.fill(p, with: .color(Theme.accent.opacity(0.5)))
                    }
                    .frame(height: barH).allowsHitTesting(false)
                }
                // the selected band, with its two sloping soft edges
                Path { p in
                    p.move(to: CGPoint(x: x(low - lowFeather), y: barH))
                    p.addLine(to: CGPoint(x: x(low), y: 0))
                    p.addLine(to: CGPoint(x: x(high), y: 0))
                    p.addLine(to: CGPoint(x: x(high + highFeather), y: barH))
                    p.closeSubpath()
                }
                .fill(Theme.accent.opacity(0.4))
                .overlay(Path { p in
                    p.move(to: CGPoint(x: x(low - lowFeather), y: barH))
                    p.addLine(to: CGPoint(x: x(low), y: 0))
                    p.addLine(to: CGPoint(x: x(high), y: 0))
                    p.addLine(to: CGPoint(x: x(high + highFeather), y: barH))
                }.stroke(Theme.accent, lineWidth: 1.6))
                .allowsHitTesting(false)

                // the two range handles
                ForEach(0..<2, id: \.self) { i in
                    let v = i == 0 ? low : high
                    Rectangle().fill(Color.white).frame(width: 2, height: barH + 8)
                        .position(x: x(v), y: barH / 2 + 4)
                    Circle().fill(Color.white).frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                        .shadow(radius: 2)
                        .position(x: min(max(x(v), 12), w - 12), y: barH + 16)
                }
            }
            .frame(height: barH + 30)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if active == nil {
                        let dl = abs(g.startLocation.x - x(low)), dh = abs(g.startLocation.x - x(high))
                        if abs(dl - dh) < 1 { active = g.startLocation.x < x(low) ? 0 : 1 } else { active = dl < dh ? 0 : 1 }
                    }
                    let v = Double(min(max(g.location.x / w, 0), 1))
                    if active == 0 {
                        low = min(v, high - 0.02)
                        lowFeather = min(lowFeather, low)
                    } else {
                        high = max(v, low + 0.02)
                        highFeather = min(highFeather, 1 - high)
                    }
                }
                .onEnded { _ in active = nil })
        }
        .frame(height: 60)
    }
}

// MARK: - Mask panel

struct MaskPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var adding = false
    @State private var sel = "Exposure"

    var body: some View {
        VStack(spacing: 4) {
            if vm.settings.masks.isEmpty || adding {
                typeGrid
            } else if let m = vm.selectedMask {
                header(m)
                HStack(spacing: 0) {
                    ForEach(MaskTab.allCases) { t in
                        Button { vm.maskTab = t } label: {
                            Text(t.rawValue).font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity).frame(height: 30)
                                .background(vm.maskTab == t ? Theme.accent.opacity(0.85) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(vm.maskTab == t ? Color.white : Color(white: 0.6))
                        }
                    }
                }
                .padding(2)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 12)
                if vm.maskTab == .shape {
                    ScrollView { shapeControls(m).padding(.horizontal, 14).padding(.bottom, 8) }
                } else {
                    ParamPanel(items: localItems(m), selected: $sel, header: AnyView(
                        HStack {
                            PillButton(title: "Reset adjustments", system: "arrow.counterclockwise") {
                                vm.updateMask(m.id) { $0.adjust = LocalAdjust() }
                            }
                            Spacer()
                        }))
                }
            } else {
                header(nil)
                Text("Select a mask above.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: vm.settings.masks.count) { _, _ in adding = false }
    }

    // MARK: header / add

    private var typeGrid: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Add a mask").font(.system(size: 13, weight: .semibold))
                Spacer()
                if adding { Button("Cancel") { adding = false }.font(.system(size: 13)) }
            }
            .padding(.horizontal, 14)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(MaskKind.allCases) { k in
                    Button { vm.addMask(k); adding = false } label: {
                        VStack(spacing: 4) {
                            Image(systemName: k.icon).font(.system(size: 20))
                            Text(k.title).font(.system(size: 11))
                        }
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func header(_ m: Mask?) -> some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Chip(title: "New", system: "plus", selected: false) { adding = true }
                    ForEach(vm.settings.masks) { mk in
                        Chip(title: mk.name, system: mk.components.first?.kind.icon, selected: mk.id == vm.selectedMaskID) {
                            vm.selectMask(mk.id)
                        }
                    }
                }
                .padding(.leading, 12)
            }
            if let m {
                IconButton(system: "hand.draw", active: vm.panMode) { vm.panMode.toggle() }
                IconButton(system: eyeOn ? "eye" : "eye.slash", active: eyeOn) {
                    if vm.maskTab == .shape { vm.overlayEnabled.toggle() } else { vm.peekOverlay.toggle() }
                }
                IconButton(system: "trash") { vm.deleteMask(m.id) }.padding(.trailing, 6)
            }
        }
    }

    private var eyeOn: Bool { vm.maskTab == .shape ? vm.overlayEnabled : vm.peekOverlay }

    // MARK: bindings

    private func mb<T>(_ m: Mask, _ kp: WritableKeyPath<Mask, T>) -> Binding<T> {
        Binding(get: { vm.settings.masks.first { $0.id == m.id }?[keyPath: kp] ?? m[keyPath: kp] },
                set: { v in vm.updateMask(m.id) { $0[keyPath: kp] = v } })
    }

    private func cb<T>(_ c: MaskComponent, _ kp: WritableKeyPath<MaskComponent, T>) -> Binding<T> {
        Binding(get: { vm.selectedMask?.components.first { $0.id == c.id }?[keyPath: kp] ?? c[keyPath: kp] },
                set: { v in vm.updateComponent(c.id) { $0[keyPath: kp] = v } })
    }

    private func local(_ m: Mask, _ title: String, _ kp: WritableKeyPath<LocalAdjust, Double>,
                       range: ClosedRange<Double> = -100...100, decimals: Int = 0,
                       track: [Color]? = nil) -> ParamItem {
        ParamItem(id: title, title: title,
                  value: Binding(get: { vm.settings.masks.first { $0.id == m.id }?.adjust[keyPath: kp] ?? 0 },
                                 set: { v in vm.updateMask(m.id) { $0.adjust[keyPath: kp] = v } }),
                  range: range, decimals: decimals, track: track)
    }

    private func localItems(_ m: Mask) -> [ParamItem] {
        [
            local(m, "Exposure", \.exposure, range: -5...5, decimals: 2),
            local(m, "Contrast", \.contrast),
            local(m, "Highlights", \.highlights),
            local(m, "Shadows", \.shadows),
            local(m, "Whites", \.whites),
            local(m, "Blacks", \.blacks),
            local(m, "Temp", \.temperature, track: Tracks.temperature),
            local(m, "Tint", \.tint, track: Tracks.tint),
            local(m, "Saturation", \.saturation),
            local(m, "Clarity", \.clarity),
            local(m, "Texture", \.texture),
            local(m, "Dehaze", \.dehaze),
            local(m, "Sharpen", \.sharpness, range: 0...100),
            local(m, "Noise", \.noise, range: 0...100),
        ]
    }

    // MARK: shape tab

    @ViewBuilder
    private func shapeControls(_ m: Mask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(m.components) { c in
                        Chip(title: c.kind.title, system: c.op == .add ? c.kind.icon : c.op.symbol,
                             selected: c.id == vm.selectedComponent?.id) {
                            vm.selectedComponentID = c.id
                        }
                    }
                    Menu {
                        ForEach(MaskOp.allCases) { op in
                            Menu(op.title) {
                                ForEach(MaskKind.allCases) { k in
                                    Button { vm.addComponent(k, op: op) } label: { Label(k.title, systemImage: k.icon) }
                                }
                            }
                        }
                    } label: {
                        Label("Add / subtract", systemImage: "plus.circle")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Theme.chip, in: Capsule())
                            .foregroundStyle(Color(white: 0.82))
                    }
                }
            }
            if let c = vm.selectedComponent {
                if m.components.count > 1 {
                    HStack {
                        Picker("", selection: cb(c, \.op)) {
                            ForEach(MaskOp.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .disabled(m.components.first?.id == c.id)
                        IconButton(system: "minus.circle") { vm.deleteComponent(c.id) }
                    }
                }
                componentControls(c)
            }
            LabeledSlider(title: "Opacity", value: mb(m, \.amount), range: 0...100, neutral: 100)
            HStack(spacing: 6) {
                if let c = vm.selectedComponent {
                    Chip(title: "Invert shape", system: "circle.lefthalf.filled", selected: c.invert) { vm.updateComponent(c.id) { $0.invert.toggle() } }
                }
                Chip(title: "Invert mask", system: "arrow.left.arrow.right", selected: m.invert) { vm.updateMask(m.id) { $0.invert.toggle() } }
            }
        }
    }

    @ViewBuilder
    private func componentControls(_ c: MaskComponent) -> some View {
        switch c.kind {
        case .linear:
            hint("Drag the two handles on the photo. Full effect at the first, fading to none at the second. Drag the middle to move it.")
        case .radial:
            hint("Drag the centre, or the side handles to resize.")
            LabeledSlider(title: "Feather", value: cb(c, \.feather), range: 0...100, neutral: 50)
            LabeledSlider(title: "Angle", value: cb(c, \.angle), range: -90...90, neutral: 0)
        case .brush:
            hint("Paint on the photo with your finger.")
            LabeledSlider(title: "Size", value: $vm.brushSize, range: 0.01...0.25, decimals: 2, neutral: 0.06)
            LabeledSlider(title: "Feather", value: cb(c, \.feather), range: 0...100, neutral: 50)
            HStack {
                Toggle("Erase", isOn: $vm.brushErase).font(.system(size: 13))
                Toggle("Auto mask", isOn: cb(c, \.autoMask)).font(.system(size: 13))
            }
            Button(role: .destructive) { vm.updateComponent(c.id) { $0.strokes = [] } } label: {
                Label("Clear strokes", systemImage: "xmark.circle").font(.caption)
            }
            .buttonStyle(.bordered)
        case .subject, .background, .sky:
            if vm.autoMaskBusy {
                HStack { ProgressView(); Text("Finding it…").font(.caption).foregroundStyle(.secondary) }
            } else if (c.kind == .sky && vm.autoMaskMissing.contains(EditSession.aiSky))
                        || (c.kind != .sky && vm.autoMaskMissing.contains(EditSession.aiSubject)) {
                hint("Couldn't find a \(c.kind == .sky ? "sky" : "subject") in this photo. Try a Brush, Linear or Luminance mask instead.")
            } else {
                hint(c.kind == .sky ? "The sky was selected automatically. Add or subtract shapes to fix it."
                                    : "Selected automatically. Add or subtract shapes to fix it.")
            }
            LabeledSlider(title: "Soften", value: cb(c, \.feather), range: 0...100, neutral: 0)
        case .luminance:
            hint("Choose a band of brightness: drag the two white handles, or tap the photo to pick one. Soften either edge below.")
            LumRangeEditor(low: cb(c, \.lumLow), high: cb(c, \.lumHigh),
                           lowFeather: cb(c, \.lumLowFeather), highFeather: cb(c, \.lumHighFeather),
                           histogram: vm.histogram?.luma)
        case .color:
            hint("Tap the photo to pick a colour. Hold the + to add more colours (up to 4).")
            HStack(spacing: 8) {
                ForEach(Array(c.samples.enumerated()), id: \.offset) { i, s in
                    Button { vm.updateComponent(c.id) { $0.samples.remove(at: i) } } label: {
                        Circle().fill(EditorViewModel.swatch(s)).frame(width: 30, height: 30)
                            .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1.5))
                    }
                }
                Button { vm.colorAddMode.toggle() } label: {
                    Image(systemName: vm.colorAddMode ? "plus.circle.fill" : "plus.circle").font(.system(size: 26))
                        .foregroundStyle(vm.colorAddMode ? Theme.accent : Color.white)
                }
                if c.samples.isEmpty { Text("No colour yet").font(.caption).foregroundStyle(.secondary) }
            }
            LabeledSlider(title: "Range", value: cb(c, \.tolerance), range: 0.03...0.5, decimals: 2, neutral: 0.18)
            LabeledSlider(title: "Smoothness", value: cb(c, \.feather), range: 0...100, neutral: 50)
        }
    }

    private func hint(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - On-photo overlay (handles, brush, picker)

private struct HandleDot: View {
    var body: some View {
        Circle()
            .fill(Color.black.opacity(0.35))
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .frame(width: 30, height: 30)
    }
}

/// Covers the whole canvas; every position is mapped through `xform` so it follows pinch/zoom/pan.
struct MaskOverlay: View {
    @ObservedObject var vm: EditorViewModel
    let xform: ViewXform
    @State private var drawing = false
    @State private var cursor: CGPoint?

    var body: some View {
        ZStack {
            if vm.maskTab == .shape, vm.overlayEnabled, let c = vm.selectedComponent {
                controls(c)
            }
        }
        .frame(width: xform.canvas.width, height: xform.canvas.height)
        .coordinateSpace(name: "maskSpace")
    }

    private func norm(_ p: CGPoint) -> Pt { xform.normalised(p) }
    /// Handles may go past the photo's edges (zoom the photo out in Masks to reach further), so a gradient or radial
    /// can be much bigger than the picture.
    private func free(_ p: CGPoint) -> Pt { xform.unclamped(p) }

    @ViewBuilder
    private func controls(_ c: MaskComponent) -> some View {
        switch c.kind {
        case .brush: brushLayer(c)
        case .color:
            Color.clear.contentShape(Rectangle())
                .gesture(SpatialTapGesture(coordinateSpace: .named("maskSpace")).onEnded { v in
                    guard xform.rect.contains(v.location) else { return }
                    vm.pick(at: norm(v.location), addToSelection: vm.colorAddMode)
                })
        case .luminance:
            Color.clear.contentShape(Rectangle())
                .gesture(SpatialTapGesture(coordinateSpace: .named("maskSpace")).onEnded { v in
                    guard xform.rect.contains(v.location) else { return }
                    vm.pick(at: norm(v.location))
                })
        case .linear: linearHandles(c)
        case .radial: radialHandles(c)
        default: EmptyView()
        }
    }

    private func brushLayer(_ c: MaskComponent) -> some View {
        let diameter = CGFloat(vm.brushSize) * max(xform.rect.width, xform.rect.height)
        return ZStack {
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("maskSpace"))
                    .onChanged { v in
                        cursor = v.location
                        guard xform.rect.contains(v.location) else { return }
                        let p = norm(v.location)
                        if drawing { vm.extendStroke(p) } else { drawing = true; vm.beginStroke(p) }
                    }
                    .onEnded { _ in drawing = false; cursor = nil })
            if let cursor {
                Circle().stroke(Color.white, lineWidth: 1.5).frame(width: diameter, height: diameter)
                    .position(cursor).allowsHitTesting(false)
            }
        }
    }

    private func handle(at p: CGPoint, onDrag: @escaping (Pt) -> Void) -> some View {
        HandleDot()
            .position(p)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("maskSpace"))
                .onChanged { v in onDrag(free(v.location)) })
    }

    @ViewBuilder
    private func linearHandles(_ c: MaskComponent) -> some View {
        let a = xform.point(c.x0, c.y0)
        let b = xform.point(c.x1, c.y1)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        let nx = -dy / len, ny = dx / len
        let reach: CGFloat = 1600
        Path { p in
            p.move(to: a); p.addLine(to: b)
        }
        .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        .allowsHitTesting(false)
        Path { p in
            p.move(to: CGPoint(x: a.x - nx * reach, y: a.y - ny * reach)); p.addLine(to: CGPoint(x: a.x + nx * reach, y: a.y + ny * reach))
            p.move(to: CGPoint(x: b.x - nx * reach, y: b.y - ny * reach)); p.addLine(to: CGPoint(x: b.x + nx * reach, y: b.y + ny * reach))
        }
        .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
        .allowsHitTesting(false)
        handle(at: a) { p in vm.updateComponent(c.id) { $0.x0 = p.x; $0.y0 = p.y } }
        handle(at: b) { p in vm.updateComponent(c.id) { $0.x1 = p.x; $0.y1 = p.y } }
        HandleDot().scaleEffect(0.7).position(mid)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("maskSpace"))
                .onChanged { v in
                    let m = free(v.location)
                    let cx = (c.x0 + c.x1) / 2, cy = (c.y0 + c.y1) / 2
                    let ddx = m.x - cx, ddy = m.y - cy
                    let lim: (Double) -> Double = { min(max($0, -1.5), 2.5) }
                    vm.updateComponent(c.id) {
                        $0.x0 = lim(c.x0 + ddx); $0.y0 = lim(c.y0 + ddy)
                        $0.x1 = lim(c.x1 + ddx); $0.y1 = lim(c.y1 + ddy)
                    }
                })
    }

    @ViewBuilder
    private func radialHandles(_ c: MaskComponent) -> some View {
        let r = xform.rect
        let centre = xform.point(c.x0, c.y0)
        let a = c.angle * .pi / 180
        let u = CGPoint(x: cos(a), y: sin(a)), v = CGPoint(x: -sin(a), y: cos(a))
        let rx = CGFloat(c.x1) * r.width, ry = CGFloat(c.y1) * r.height
        Ellipse()
            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .frame(width: rx * 2, height: ry * 2)
            .rotationEffect(.degrees(c.angle))
            .position(centre)
            .allowsHitTesting(false)
        handle(at: centre) { p in vm.updateComponent(c.id) { $0.x0 = p.x; $0.y0 = p.y } }
        handle(at: CGPoint(x: centre.x + u.x * rx, y: centre.y + u.y * rx)) { p in
            let pt = xform.point(p.x, p.y)
            let d = (pt.x - centre.x) * u.x + (pt.y - centre.y) * u.y
            vm.updateComponent(c.id) { $0.x1 = max(0.02, min(3, Double(abs(d) / max(r.width, 1)))) }
        }
        handle(at: CGPoint(x: centre.x + v.x * ry, y: centre.y + v.y * ry)) { p in
            let pt = xform.point(p.x, p.y)
            let d = (pt.x - centre.x) * v.x + (pt.y - centre.y) * v.y
            vm.updateComponent(c.id) { $0.y1 = max(0.02, min(3, Double(abs(d) / max(r.height, 1)))) }
        }
    }
}
