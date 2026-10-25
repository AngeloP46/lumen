import SwiftUI

// MARK: - Small shared bits

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var decimals = 0
    var neutral: Double?
    var labelWidth: CGFloat = 84
    var axID = ""
    var onActive: ((Bool) -> Void)?

    /// Same look and behaviour as the rows on the Light / Color / Detail pages (it is the same row).
    var body: some View {
        let item = ParamItem(id: axID.isEmpty ? title : axID, title: title, value: $value, range: range,
                             decimals: decimals, neutral: neutral)
        SliderRow(item: item, height: 40, labelWidth: max(labelWidth, 84), inset: 0, onActive: onActive) {
            value = neutral ?? (range.contains(0) ? 0 : range.lowerBound)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
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
    /// The same editor for the Depth mask: the bar runs near (left) to far (right).
    var depth = false
    var onActive: ((Bool) -> Void)? = nil

    @State private var active: Int?   // 0 / 1 = band start / end, 2 / 3 = dark / light soft edge
    @State private var featherStart = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar
            HStack(spacing: 6) {
                if depth {
                    preset("Near", 0, 0.35, 0, 0.15)
                    preset("Middle", 0.30, 0.70, 0.12, 0.12)
                    preset("Far", 0.65, 1, 0.15, 0)
                } else {
                    preset("Shadows", 0, 0.30, 0, 0.15)
                    preset("Midtones", 0.30, 0.70, 0.15, 0.15)
                    preset("Highlights", 0.70, 1, 0.15, 0)
                    preset("Whites", 0.88, 1, 0.10, 0)
                }
            }
            LabeledSlider(title: depth ? "Near edge" : "Dark edge", value: soft($lowFeather, limit: { low }), range: 0...(depth ? 100 : 50), neutral: 0, labelWidth: 66, onActive: onActive)
                .opacity(!depth && low <= 0.001 ? 0.35 : 1).allowsHitTesting(depth || low > 0.001)
            LabeledSlider(title: depth ? "Far edge" : "Light edge", value: soft($highFeather, limit: { 1 - high }), range: 0...(depth ? 100 : 50), neutral: 0, labelWidth: 66, onActive: onActive)
                .opacity(!depth && high >= 0.999 ? 0.35 : 1).allowsHitTesting(depth || high < 0.999)
        }
    }

    /// Feather stored as 0...0.5, shown as 0...50 %. Depth feather may extend beyond the available depth values.
    private func soft(_ b: Binding<Double>, limit: @escaping () -> Double) -> Binding<Double> {
        Binding(get: { b.wrappedValue * 100 }, set: { b.wrappedValue = min(max($0 / 100, 0), depth ? 1 : max(limit(), 0)) })
    }

    private func preset(_ title: String, _ lo: Double, _ hi: Double, _ lf: Double, _ hf: Double) -> some View {
        let on = abs(low - lo) < 0.02 && abs(high - hi) < 0.02
        return Chip(title: title, selected: on) { low = lo; high = hi; lowFeather = lf; highFeather = hf; onActive?(true); onActive?(false) }
    }

    private func depthCoverage(_ value: Double) -> Double {
        func step(_ a: Double, _ b: Double) -> Double {
            let t = min(max((value - a) / max(b - a, 0.000001), 0), 1)
            return t * t * (3 - 2 * t)
        }
        let near = low <= 0.001 ? (lowFeather > 0.001 ? step(0, lowFeather) : 1) : step(low - max(lowFeather, 0.001), low)
        let far = high >= 0.999 ? (highFeather > 0.001 ? 1 - step(1 - highFeather, 1) : 1) : 1 - step(high, high + max(highFeather, 0.001))
        return near * far
    }

    /// The brightness bar. White handles (top corners of the band) set where it starts and ends; the small blue
    /// handles (bottom corners) pull its soft edges out, the same as the Dark edge / Light edge sliders.
    private var bar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let barH: CGFloat = 30
            let top: CGFloat = 14              // room above the bar for the white handles
            let x: (Double) -> CGFloat = { CGFloat(min(max($0, 0), 1)) * w }
            let ends: [CGPoint] = [
                CGPoint(x: x(low), y: top), CGPoint(x: x(high), y: top),                                   // 0, 1: band
                CGPoint(x: x(depth && low <= 0.001 ? lowFeather : low - lowFeather), y: top + barH), CGPoint(x: x(depth && high >= 0.999 ? 1 - highFeather : high + highFeather), y: top + barH), // 2, 3: soft edges
            ]
            ZStack(alignment: .topLeading) {
                Group {
                    LinearGradient(colors: depth ? [Color(white: 0.85), Color(red: 0.1, green: 0.14, blue: 0.3)] : [.black, .white],
                                   startPoint: .leading, endPoint: .trailing)
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
                    if depth {
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: barH))
                            for i in 0...100 {
                                let value = Double(i) / 100
                                p.addLine(to: CGPoint(x: x(value), y: barH * CGFloat(1 - depthCoverage(value))))
                            }
                            p.addLine(to: CGPoint(x: w, y: barH)); p.closeSubpath()
                        }
                        .fill(Theme.accent.opacity(0.4)).allowsHitTesting(false)
                    } else {
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
                    }
                }
                .offset(y: top)

                // band handles (white, on top) and soft-edge handles (small, blue, underneath)
                ForEach(0..<4, id: \.self) { i in
                    let p = ends[i]
                    let big = i < 2
                    Circle().fill(big ? Color.white : Theme.accent)
                        .overlay(Circle().stroke(big ? Color.black.opacity(0.35) : Color.white, lineWidth: big ? 1 : 1.5))
                        .shadow(radius: 2)
                        .frame(width: big ? 22 : 16, height: big ? 22 : 16)
                        .scaleEffect(active == i ? 1.25 : 1)
                        .position(x: min(max(p.x, big ? 11 : 8), w - (big ? 11 : 8)), y: p.y)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: top + barH + 14)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("lum-bar")
            .accessibilityValue(String(format: "low %.2f high %.2f soft %.2f %.2f", low, high, lowFeather, highFeather))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if active == nil {
                        // nearest handle to where the finger landed; the top half of the bar picks the band handles,
                        // the bottom half the soft edges
                        let st = g.startLocation
                        let wantSoft = st.y > top + barH / 2
                        let a = wantSoft ? 2 : 0, b = a + 1
                        let da = abs(ends[a].x - st.x), db = abs(ends[b].x - st.x)
                        onActive?(true)
                        if abs(da - db) < 1 { active = st.x < ends[a].x ? a : b } else { active = da < db ? a : b }
                        featherStart = active == 2 ? lowFeather : highFeather
                    }
                    let v = Double(min(max(g.location.x / w, 0), 1))
                    switch active ?? 3 {
                    case 0:
                        low = min(v, high - 0.02)
                        if !depth { lowFeather = min(lowFeather, low) }
                    case 1:
                        high = max(v, low + 0.02)
                        if !depth { highFeather = min(highFeather, 1 - high) }
                    case 2:
                        if depth {
                            // relative drag: held at 0 or 1, moving back responds at once (EndStop)
                            lowFeather = EndStop.value(base: &featherStart, delta: (low <= 0.001 ? 1 : -1) * Double(g.translation.width / w), in: 0...1)
                        } else {
                            lowFeather = min(max(low - v, 0), min(0.5, low))
                        }
                    default:
                        if depth {
                            highFeather = EndStop.value(base: &featherStart, delta: (high >= 0.999 ? -1 : 1) * Double(g.translation.width / w), in: 0...1)
                        } else {
                            highFeather = min(max(v - high, 0), min(0.5, 1 - high))
                        }
                    }
                }
                .onEnded { _ in active = nil; onActive?(false) })
        }
        .frame(height: 58)
    }
}

// MARK: - Mask panel

struct MaskPanel: View {
    @ObservedObject var vm: EditorViewModel
    var lensOnly = false
    @State private var adding = false
    @State private var sel = "Exposure"

    var body: some View {
        VStack(spacing: 4) {
            if lensOnly, let m = vm.selectedMask {
                ScrollView { shapeControls(m).padding(.horizontal, 14).padding(.bottom, 8) }
            } else if vm.userMasks.isEmpty || adding {
                typeGrid
            } else if let m = vm.selectedMask {
                header(m)
                if let why = vm.emptyReason(m) { emptyBanner(why, m) }
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
                    ParamPanel(items: localItems(m), selected: $sel,
                               pageReset: { vm.updateMask(m.id) { $0.adjust = LocalAdjust() } },
                               pageResetEnabled: !m.adjust.isNeutral)
                }
            } else {
                header(nil)
                Text("Select a mask above.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: vm.settings.masks.count) { _, _ in adding = false }
    }

    // MARK: header / add

    /// New mask, grouped like Lightroom: the app finds it (Auto), you draw it (Draw), or it picks by colour,
    /// brightness or distance (Range). Auto fills one row; Draw and Range share the second.
    private var typeGrid: some View {
        GeometryReader { geo in
            let w = geo.size.width - 24
            let gap: CGFloat = 5
            let autoW = (w - gap * 4) / 5
            let pairGap: CGFloat = 14
            let smallW = (w - pairGap - gap * 4) / 6
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    groupTitle("Auto")
                    Spacer()
                    if adding { Button("Cancel") { adding = false }.font(.system(size: 13)) }
                }
                HStack(spacing: gap) {
                    ForEach([MaskKind.subject, .people, .background, .sky, .landscape]) { kindTile($0, width: autoW) }
                }
                HStack(spacing: pairGap) {
                    VStack(alignment: .leading, spacing: 6) {
                        groupTitle("Draw")
                        HStack(spacing: gap) { ForEach([MaskKind.brush, .linear, .radial]) { kindTile($0, width: smallW) } }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        groupTitle("Range")
                        HStack(spacing: gap) { ForEach([MaskKind.color, .luminance, .depth]) { kindTile($0, width: smallW) } }
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 150)
    }

    /// Shown when the AI found nothing for this mask, so it never sits there silently doing nothing.
    private func emptyBanner(_ why: String, _ m: Mask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
            Text(why).font(.system(size: 12, weight: .medium)).lineLimit(2)
            Spacer(minLength: 4)
            if !vm.autoMaskFailed.isEmpty {
                Button("Try again") { vm.retryAI() }
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityIdentifier("mask-empty-retry")
            }
            Button("Remove mask") { vm.deleteMask(m.id) }
                .font(.system(size: 12, weight: .semibold))
                .accessibilityIdentifier("mask-empty-remove")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mask-empty")
    }

    private func groupTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Color(white: 0.5))
            .padding(.leading, 2)
    }

    private func kindTile(_ k: MaskKind, width: CGFloat) -> some View {
        Button { vm.addMask(k); adding = false } label: {
            VStack(spacing: 4) {
                Image(systemName: k.icon).font(.system(size: 18))
                Text(k.title).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: width, height: 50)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
        }
        .accessibilityIdentifier("kind-\(k.rawValue)")
    }

    /// Your masks, a + to add one, the overlay eye, and a ⋯ menu for the rest (fewer buttons in one row, so mask
    /// names are not cut off).
    private func header(_ m: Mask?) -> some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button { adding = true } label: {
                        Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 32)
                            .background(Theme.chip, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .accessibilityIdentifier("mask-add")
                    .accessibilityLabel("New mask")
                    ForEach(lensOnly ? vm.settings.masks : vm.userMasks) { mk in
                        let empty = vm.emptyReason(mk) != nil
                        Chip(title: mk.name, system: empty ? "exclamationmark.triangle" : mk.components.first?.kind.icon,
                             selected: mk.id == vm.selectedMaskID) {
                            vm.selectMask(mk.id)
                        }
                    }
                }
                .padding(.leading, 12)
            }
            if let m {
                IconButton(system: eyeOn ? "eye" : "eye.slash", active: eyeOn) {
                    if vm.maskTab == .shape { vm.overlayEnabled.toggle() } else { vm.peekOverlay.toggle() }
                }
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("mask-eye")
                Menu {
                    Button { vm.panMode.toggle() } label: {
                        Label(vm.panMode ? "Stop moving the photo" : "Move the photo with one finger",
                              systemImage: vm.panMode ? "checkmark" : "hand.draw")
                    }
                    Divider()
                    Button(role: .destructive) { vm.deleteMask(m.id) } label: { Label("Delete mask", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 18))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(vm.panMode ? Theme.accent : Color.white)
                }
                .accessibilityIdentifier("mask-menu")
                .padding(.trailing, 6)
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
                       track: [Color]? = nil, section: String) -> ParamItem {
        ParamItem(id: title, title: title,
                  value: Binding(get: { vm.settings.masks.first { $0.id == m.id }?.adjust[keyPath: kp] ?? 0 },
                                 set: { v in vm.updateMask(m.id) { $0.adjust[keyPath: kp] = v } }),
                  range: range, decimals: decimals, track: track, section: section)
    }

    private func localItems(_ m: Mask) -> [ParamItem] {
        [
            local(m, "Exposure", \.exposure, range: -5...5, decimals: 2, section: "Light"),
            local(m, "Brightness", \.brightness, section: "Light"),
            local(m, "Contrast", \.contrast, section: "Light"),
            local(m, "Highlights", \.highlights, section: "Light"),
            local(m, "Shadows", \.shadows, section: "Light"),
            local(m, "Whites", \.whites, section: "Light"),
            local(m, "Blacks", \.blacks, section: "Light"),
            local(m, "Saturation", \.saturation, track: Tracks.fullSaturation, section: "Colour"),
            local(m, "Temp", \.temperature, track: Tracks.temperature, section: "Colour"),
            local(m, "Tint", \.tint, track: Tracks.tint, section: "Colour"),
            local(m, "Clarity", \.clarity, section: "Effects"),
            local(m, "Texture", \.texture, section: "Effects"),
            local(m, "Dehaze", \.dehaze, section: "Effects"),
            local(m, "Sharpen", \.sharpness, range: 0...100, section: "Detail"),
            local(m, "Noise", \.noise, range: 0...100, section: "Detail"),
        ]
    }

    // MARK: shape tab

    private var addSubtractMenu: some View {
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

    @ViewBuilder
    private func shapeControls(_ m: Mask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if m.components.count > 1 {
                // the parts of this mask (only shown once there is more than one); a part the AI found nothing for
                // shows a warning sign
                HStack(spacing: 2) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(m.components) { c in
                                Chip(title: c.kind.title,
                                     system: vm.emptyReason(c) != nil ? "exclamationmark.triangle" : (c.op == .add ? c.kind.icon : c.op.symbol),
                                     selected: c.id == vm.selectedComponent?.id) {
                                    vm.selectedComponentID = c.id
                                }
                            }
                            addSubtractMenu
                        }
                    }
                    invertButtons(m)
                }
            } else {
                HStack { addSubtractMenu; Spacer(); invertButtons(m) }
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
                if m.components.count > 1 {
                    // just the selected part (e.g. how much a Subject subtract takes away), not the whole mask
                    LabeledSlider(title: "Part opacity", value: cb(c, \.amount), range: 0...100, neutral: 100)
                }
            }
            LabeledSlider(title: m.components.count > 1 ? "Mask opacity" : "Opacity", value: mb(m, \.amount),
                          range: 0...100, neutral: 100)
        }
    }

    /// Invert this part (only with more than one part) and invert the whole mask: small icons, lit when on.
    @ViewBuilder
    private func invertButtons(_ m: Mask) -> some View {
        if m.components.count > 1, let c = vm.selectedComponent {
            IconButton(system: "circle.lefthalf.filled", active: c.invert) { vm.updateComponent(c.id) { $0.invert.toggle() } }
                .accessibilityLabel("Invert part").accessibilityIdentifier("invert-part")
        }
        IconButton(system: "arrow.left.arrow.right", active: m.invert) { vm.updateMask(m.id) { $0.invert.toggle() } }
            .accessibilityLabel("Invert mask").accessibilityIdentifier("invert-mask")
    }

    @ViewBuilder
    private func componentControls(_ c: MaskComponent) -> some View {
        switch c.kind {
        case .linear:
            hint("Full effect at the first line, fading to none at the second. Drag the blue pin to move it, the round arrow to turn it.", kind: .linear)
        case .radial:
            hint("Drag the blue pin to move it, the side handles to resize, the round arrow to turn it.", kind: .radial)
            LabeledSlider(title: "Feather", value: cb(c, \.feather), range: 0...100, neutral: 50)
            LabeledSlider(title: "Angle", value: cb(c, \.angle), range: -90...90, neutral: 0)
        case .brush:
            Picker("Brush", selection: $vm.brushErase) {
                Text("Paint").tag(false)
                Text("Erase").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("brush-mode")
            hint("Paint on the photo with your finger. Size and Feather apply to the strokes you paint next.", kind: .brush)
            // size shown 1...100 (100 = a quarter of the photo's long edge)
            LabeledSlider(title: "Size", value: Binding(get: { (vm.brushSize * 400).rounded() },
                                                        set: { vm.brushSize = max($0, 1) / 400 }),
                          range: 1...100, neutral: 24)
            LabeledSlider(title: "Feather", value: cb(c, \.feather), range: 0...100, neutral: 50)
            Toggle("Auto mask (stick to similar colours)", isOn: cb(c, \.autoMask)).font(.system(size: 13))
            Button(role: .destructive) { vm.updateComponent(c.id) { $0.strokes = [] } } label: {
                Label("Clear strokes", systemImage: "xmark.circle").font(.caption)
            }
            .buttonStyle(.bordered)
        case .subject, .background, .sky, .people:
            if vm.autoMaskBusy {
                HStack { ProgressView(); Text("Finding it…").font(.caption).foregroundStyle(.secondary) }
            } else if c.kind == .background && vm.autoMaskMissing.contains(EditSession.aiSubject) {
                hint("No subject found in this photo, so the background is all of it. Subtract shapes to keep parts out.")
            } else if c.kind == .people && vm.autoMaskMissing.contains(EditSession.aiPeople) {
                hint("Couldn't find anyone in this photo. Try Subject, or a Brush mask instead.")
            } else if (c.kind == .sky && vm.autoMaskMissing.contains(EditSession.aiSky))
                        || (c.kind != .sky && c.kind != .people && vm.autoMaskMissing.contains(EditSession.aiSubject)) {
                hint("Couldn't find a \(c.kind == .sky ? "sky" : "subject") in this photo. Try a Brush, Linear or Luminance mask instead.")
            } else {
                hint(c.kind == .sky ? "The sky was selected automatically. Add or subtract shapes to fix it."
                                    : "Selected automatically. Add or subtract shapes to fix it.")
            }
            LabeledSlider(title: "Soften", value: cb(c, \.feather), range: 0...100, neutral: 0)
        case .luminance:
            hint("Drag the white handles for the band and the small blue ones to soften its edges, or tap the photo to pick a brightness.", kind: .luminance)
            LumRangeEditor(low: cb(c, \.lumLow), high: cb(c, \.lumHigh),
                           lowFeather: cb(c, \.lumLowFeather), highFeather: cb(c, \.lumHighFeather),
                           histogram: vm.histogram?.luma)
        case .landscape:
            let field = vm.sceneField
            if !EditSession.hasSceneModel {
                hint("This build has no scene model, so the Landscape mask can't work yet.")
            } else if vm.autoMaskBusy && field == nil {
                HStack { ProgressView(); Text("Looking at the scene…").font(.caption).foregroundStyle(.secondary) }
            } else if let field {
                // only what is in this photo (plus anything already picked, so it can be taken off again)
                let shown = ScenePart.landscapeParts.filter { field.found.contains($0) || c.scene.contains($0.rawValue) }
                let absent = ScenePart.landscapeParts.filter { !shown.contains($0) }
                if shown.isEmpty {
                    hint("No water, plants, mountains, buildings or ground found in this photo.")
                } else {
                    hint(c.scene.isEmpty ? "Found in this photo: pick one or more." : "Tap to add or remove parts.")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(shown) { part in
                            let on = c.scene.contains(part.rawValue)
                            Button {
                                vm.updateComponent(c.id) { comp in
                                    if on { comp.scene.removeAll { $0 == part.rawValue } } else { comp.scene.append(part.rawValue) }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: part.icon).font(.system(size: 13))
                                    Text(part.title).font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                                    Spacer(minLength: 0)
                                    if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                                }
                                .padding(.horizontal, 10).frame(height: 36)
                                .background(on ? Theme.accent.opacity(0.3) : Theme.chip, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Theme.accent : Color.clear, lineWidth: 1.4))
                                .foregroundStyle(.white)
                            }
                            .accessibilityIdentifier("scene-\(part.rawValue)")
                        }
                    }
                }
                if !absent.isEmpty && !shown.isEmpty {
                    Text("Not in this photo: " + ListFormatter.localizedString(byJoining: absent.map { $0.title.lowercased() }))
                        .font(.system(size: 11)).foregroundStyle(Color(white: 0.45))
                }
            }
            LabeledSlider(title: "Soften", value: cb(c, \.feather), range: 0...100, neutral: 0)
        case .depth:
            if !EditSession.hasDepthModel {
                hint("This build has no depth model, so the Depth mask can't work yet.")
            } else if vm.autoMaskBusy && vm.depthField == nil {
                HStack { ProgressView(); Text("Measuring depth…").font(.caption).foregroundStyle(.secondary) }
            } else if vm.autoMaskMissing.contains(EditSession.aiDepth) {
                hint("Couldn't estimate depth for this photo. Try a Linear or Brush mask instead.")
            } else {
                hint("Left is near, right is far. Drag the white handles to pick a distance, or tap the photo to select things that far away.", kind: .depth)
            }
            LumRangeEditor(low: cb(c, \.lumLow), high: cb(c, \.lumHigh),
                           lowFeather: cb(c, \.lumLowFeather), highFeather: cb(c, \.lumHighFeather),
                           histogram: vm.depthField?.histogram, depth: true)
        case .color:
            hint("Tap the photo to pick a colour. Turn on the + to add more colours (up to 4).", kind: .color)
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

    /// How-to text. With a `kind` it shows only until that kind of mask has been used once (it is how-to, not news);
    /// without one it always shows (status messages such as "couldn't find a sky").
    @AppStorage("maskHintsSeen") private var hintsSeen = ""
    @ViewBuilder
    private func hint(_ s: String, kind: MaskKind? = nil) -> some View {
        if let kind, hintsSeen.split(separator: ",").contains(Substring(kind.rawValue)) {
            EmptyView()
        } else {
            Text(s).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .onDisappear {
                    guard let kind, !hintsSeen.split(separator: ",").contains(Substring(kind.rawValue)) else { return }
                    hintsSeen = hintsSeen.isEmpty ? kind.rawValue : hintsSeen + "," + kind.rawValue
                }
        }
    }
}

// MARK: - On-photo overlay (handles, brush, picker)

/// Mask handles are drawn 30 pt but take hold within 48 pt (owner, 25 Oct: hard to grab), the same on screen at any zoom.
private let handleHit: CGFloat = 48

private struct HandleDot: View {
    /// The shape's real edge is off screen: this handle waits at the screen's edge on its line (drawn dashed).
    var away = false
    var body: some View {
        Circle()
            .fill(Color.black.opacity(0.35))
            .overlay(Circle().stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: away ? [4, 3] : [])))
            .frame(width: 30, height: 30)
            .frame(width: handleHit, height: handleHit)
            .contentShape(Circle())
    }
}

/// The blue pin: drag it to move the whole shape (Lightroom's pin).
private struct PinDot: View {
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
            .overlay(Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
            .shadow(color: .black.opacity(0.5), radius: 2)
            .frame(width: 30, height: 30)
            .frame(width: handleHit, height: handleHit)
            .contentShape(Circle())
    }
}

/// Drag it round to turn the shape.
private struct RotateDot: View {
    var body: some View {
        Circle()
            .fill(Color.black.opacity(0.45))
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .overlay(Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
            .frame(width: 30, height: 30)
            .frame(width: handleHit, height: handleHit)
            .contentShape(Circle())
    }
}

/// Covers the whole canvas. Masks are stored against the uncropped, unturned photo (the source); the photo is shown
/// cropped and turned, so every position goes through `geo` (source <-> shown photo) and `xform` (shown photo <->
/// screen, following pinch / zoom / pan).
struct MaskOverlay: View {
    @ObservedObject var vm: EditorViewModel
    let xform: ViewXform
    let geo: SourceGeometry
    @State private var drawing = false
    @State private var cursor: CGPoint?
    /// A radial's size handle being dragged: the radius (screen points) and the finger when it started.
    @State private var radiusDrag: (startR: CGFloat, start: CGPoint)?

    var body: some View {
        ZStack {
            if vm.maskTab == .shape, vm.overlayEnabled, let c = vm.selectedComponent {
                controls(c)
            }
        }
        .frame(width: xform.canvas.width, height: xform.canvas.height)
        .coordinateSpace(name: "maskSpace")
    }

    /// A source point (normalised) on screen.
    private func screen(_ x: Double, _ y: Double) -> CGPoint {
        let o = geo.toOutput(Pt(x: x, y: y))
        return xform.point(o.x, o.y)
    }
    /// A screen point on the source, kept on the photo (painting, picking).
    private func norm(_ p: CGPoint) -> Pt {
        let s = geo.toSource(xform.unclamped(p, limit: -10...10))
        return Pt(x: min(max(s.x, 0), 1), y: min(max(s.y, 0), 1))
    }
    /// Handles may go past the photo's edges (zoom the photo out in Masks to reach further), so a gradient or radial
    /// can be much bigger than the picture.
    private func free(_ p: CGPoint) -> Pt {
        let s = geo.toSource(xform.unclamped(p, limit: -10...10))
        return Pt(x: min(max(s.x, -1.5), 2.5), y: min(max(s.y, -1.5), 2.5))
    }
    /// Screen points per source pixel.
    private var scale: CGFloat { xform.rect.width / max(geo.output.width, 1) }

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
        case .luminance, .depth:
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
        // brush size is a fraction of the source photo's long edge
        let diameter = CGFloat(vm.brushSize) * max(geo.source.width, geo.source.height) * scale
        return ZStack {
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("maskSpace"))
                    .onChanged { v in
                    guard !vm.pinching else { return }
                        cursor = v.location
                        guard xform.rect.contains(v.location) else { return }
                        let p = norm(v.location)
                        if drawing { vm.extendStroke(p) } else { drawing = true; vm.beginStroke(p) }
                    }
                    .onEnded { _ in drawing = false; cursor = nil; vm.endStroke() })
            if let cursor {
                Circle().stroke(Color.white, lineWidth: 1.5).frame(width: diameter, height: diameter)
                    .position(cursor).allowsHitTesting(false)
            }
        }
    }

    private func handle(at p: CGPoint, onDrag: @escaping (CGPoint) -> Void) -> some View {
        HandleDot()
            .position(p)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("maskSpace"))
                .onChanged { v in
                    guard !vm.pinching else { return }; onDrag(v.location) })
    }

    @ViewBuilder
    private func linearHandles(_ c: MaskComponent) -> some View {
        let a = screen(c.x0, c.y0)
        let b = screen(c.x1, c.y1)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        let nx = -dy / len, ny = dx / len
        let reach: CGFloat = 1600
        // the rotate knob sits on the centre line, a little way from the pin
        let knob = CGPoint(x: mid.x + nx * 70, y: mid.y + ny * 70)
        Path { p in
            p.move(to: a); p.addLine(to: b)
            // centre line, where the effect is half strength
            p.move(to: CGPoint(x: mid.x - nx * reach, y: mid.y - ny * reach)); p.addLine(to: CGPoint(x: mid.x + nx * reach, y: mid.y + ny * reach))
        }
        .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        .allowsHitTesting(false)
        Path { p in
            p.move(to: CGPoint(x: a.x - nx * reach, y: a.y - ny * reach)); p.addLine(to: CGPoint(x: a.x + nx * reach, y: a.y + ny * reach))
            p.move(to: CGPoint(x: b.x - nx * reach, y: b.y - ny * reach)); p.addLine(to: CGPoint(x: b.x + nx * reach, y: b.y + ny * reach))
        }
        .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
        .allowsHitTesting(false)
        handle(at: a) { loc in let p = free(loc); vm.updateComponent(c.id) { $0.x0 = p.x; $0.y0 = p.y } }
        handle(at: b) { loc in let p = free(loc); vm.updateComponent(c.id) { $0.x1 = p.x; $0.y1 = p.y } }
        // turn: keep the centre and the width, point the lines along the finger
        RotateDot().accessibilityElement(children: .ignore).accessibilityIdentifier("mask-rotate").position(knob)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("maskSpace"))
                .onChanged { v in
                    guard !vm.pinching else { return }
                    let fx = v.location.x - mid.x, fy = v.location.y - mid.y
                    let fl = hypot(fx, fy)
                    guard fl > 8 else { return }
                    // the knob lies along n; a->b is n turned back a quarter
                    let ux = fx / fl, uy = fy / fl
                    let half = CGPoint(x: uy * len / 2, y: -ux * len / 2)
                    let pa = free(CGPoint(x: mid.x - half.x, y: mid.y - half.y))
                    let pb = free(CGPoint(x: mid.x + half.x, y: mid.y + half.y))
                    vm.updateComponent(c.id) { $0.x0 = pa.x; $0.y0 = pa.y; $0.x1 = pb.x; $0.y1 = pb.y }
                })
        // move: the blue pin carries both lines
        PinDot().accessibilityElement(children: .ignore).accessibilityIdentifier("mask-pin").position(mid)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("maskSpace"))
                .onChanged { v in
                    guard !vm.pinching else { return }
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
        let centre = screen(c.x0, c.y0)
        // the ellipse's own angle plus however far the photo is turned on screen
        let deg = (geo.mirrored ? -c.angle : c.angle) + geo.clockwise
        let a = deg * .pi / 180
        let u = CGPoint(x: cos(a), y: sin(a)), v = CGPoint(x: -sin(a), y: cos(a))
        // radii are fractions of the source photo's width / height
        let pxW = geo.source.width * scale, pxH = geo.source.height * scale
        let rx = CGFloat(c.x1) * pxW, ry = CGFloat(c.y1) * pxH
        Ellipse()
            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .frame(width: rx * 2, height: ry * 2)
            .rotationEffect(.degrees(deg))
            .position(centre)
            .allowsHitTesting(false)
        // a handle on every side (owner, 25 Oct: with big circles, zoomed out, the right and bottom ones were off screen or
        // under the panel); each keeps on screen and changes the size by how far the finger moves
        radiusHandle(c, centre: centre, dir: u, r: rx, px: pxW, across: true)
        radiusHandle(c, centre: centre, dir: CGPoint(x: -u.x, y: -u.y), r: rx, px: pxW, across: true)
        radiusHandle(c, centre: centre, dir: v, r: ry, px: pxH, across: false)
        radiusHandle(c, centre: centre, dir: CGPoint(x: -v.x, y: -v.y), r: ry, px: pxH, across: false)
        // turn: a knob just below the centre pin (thumb side), clear of the edge handle; drag it round the centre.
        // A small ellipse puts it just outside its lower edge instead.
        let knobR: CGFloat = ry > 110 ? 60 : ry + 40
        RotateDot().accessibilityElement(children: .ignore).accessibilityIdentifier("mask-rotate").position(CGPoint(x: centre.x + v.x * knobR, y: centre.y + v.y * knobR))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("maskSpace"))
                .onChanged { g in
                    guard !vm.pinching else { return }
                    let fx = g.location.x - centre.x, fy = g.location.y - centre.y
                    guard hypot(fx, fy) > 12 else { return }
                    // the knob sits along +v, i.e. at (screen angle + 90°); an ellipse looks the same turned 180°, so this matches
                    var d = Double(atan2(fy, fx)) * 180 / .pi + 90 - Double(geo.clockwise)
                    d = (d + 90).truncatingRemainder(dividingBy: 180)
                    if d < 0 { d += 180 }
                    d -= 90
                    if geo.mirrored { d = -d }
                    vm.updateComponent(c.id) { $0.angle = (d * 2).rounded() / 2 }
                })
        // the move pin last, on top: with a small ellipse the handles' grab areas reach it
        PinDot().accessibilityElement(children: .ignore).accessibilityIdentifier("mask-pin").position(centre)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("maskSpace"))
                .onChanged { v in
                    guard !vm.pinching else { return }; let p = free(v.location); vm.updateComponent(c.id) { $0.x0 = p.x; $0.y0 = p.y } })
    }

    /// One of a radial's four size handles. On the ellipse's edge, or, when that is off screen, at the screen's edge on
    /// the same line (drawn dashed). Dragged, it changes the radius by how far the finger moves along its line, so a
    /// handle waiting at the screen's edge never jumps.
    private func radiusHandle(_ c: MaskComponent, centre: CGPoint, dir: CGPoint, r: CGFloat, px: CGFloat, across: Bool) -> some View {
        // what can be seen and reached: clear of the top buttons and the canvas's edges
        let vis = CGRect(x: 24, y: 64, width: max(xform.canvas.width - 48, 1), height: max(xform.canvas.height - 88, 1))
        var t = r
        if vis.contains(centre) {
            if dir.x > 0.001 { t = min(t, (vis.maxX - centre.x) / dir.x) }
            if dir.x < -0.001 { t = min(t, (vis.minX - centre.x) / dir.x) }
            if dir.y > 0.001 { t = min(t, (vis.maxY - centre.y) / dir.y) }
            if dir.y < -0.001 { t = min(t, (vis.minY - centre.y) / dir.y) }
        }
        t = max(t, 0)
        return HandleDot(away: t < r - 1)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(across ? "mask-size-across" : "mask-size-down")
            .position(x: centre.x + dir.x * t, y: centre.y + dir.y * t)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("maskSpace"))
                .onChanged { g in
                    guard !vm.pinching else { return }
                    if radiusDrag == nil { radiusDrag = (r, g.startLocation) }
                    guard let s = radiusDrag else { return }
                    let d = (g.location.x - s.start.x) * dir.x + (g.location.y - s.start.y) * dir.y
                    let size = max(0.02, min(3, Double(max(s.startR + d, 1) / max(px, 1))))
                    vm.updateComponent(c.id) { if across { $0.x1 = size } else { $0.y1 = size } }
                }
                .onEnded { _ in radiusDrag = nil })
    }
}
