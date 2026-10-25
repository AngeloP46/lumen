import SwiftUI

extension EditorViewModel {
    /// A panel entry bound to one Double on EditSettings.
    func param(_ title: String, _ kp: WritableKeyPath<EditSettings, Double>,
               range: ClosedRange<Double> = -100...100, decimals: Int = 0,
               neutral: Double? = nil, track: [Color]? = nil, section: String? = nil) -> ParamItem {
        ParamItem(id: title, title: title,
                  value: Binding(get: { self.settings[keyPath: kp] }, set: { self.settings[keyPath: kp] = $0 }),
                  range: range, decimals: decimals, neutral: neutral, track: track, section: section)
    }
}

/// The row of buttons at the top of a slider page: actions on the left, Reset on the right. Same on every page.
struct PanelActions<Leading: View>: View {
    var resetTitle = "Reset"
    var resetEnabled = true
    let reset: () -> Void
    @ViewBuilder let leading: () -> Leading
    @Environment(\.sliderLayout) private var layout

    var body: some View {
        HStack(spacing: 6) {
            if layout == .strip {
                // one-at-a-time row: Reset is a small round icon first, so the slider names keep the room
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Theme.chip, in: Circle())
                        .foregroundStyle(.white)
                }
                .opacity(resetEnabled ? 1 : 0.45)
                .disabled(!resetEnabled)
                .accessibilityLabel(resetTitle)
                .accessibilityIdentifier("pill-\(resetTitle)")
                leading()
            } else {
                leading()
                Spacer(minLength: 6)
                PillButton(title: resetTitle, system: "arrow.counterclockwise", action: reset)
                    .opacity(resetEnabled ? 1 : 0.45)
                    .disabled(!resetEnabled)
            }
        }
    }
}

struct PillButton: View {
    let title: String
    var system: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: system)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(active ? Theme.accent : Theme.chip, in: Capsule())
                .foregroundStyle(.white)
        }
        .accessibilityIdentifier("pill-\(title)")
    }
}

// MARK: - Light / Colour / Detail

struct LightPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var sel = "Exposure"
    var body: some View {
        // HDR is a photo-wide mode: it lives in the top bar now (owner's request 2026-10-10)
        let items = [
            vm.param("Exposure", \.exposure, range: -5...5, decimals: 2),
            vm.param("Brightness", \.brightness),
            vm.param("Contrast", \.contrast),
            vm.param("Highlights", \.highlights),
            vm.param("Shadows", \.shadows),
            vm.param("Whites", \.whites),
            vm.param("Blacks", \.blacks),
        ]
        return ParamPanel(items: items, selected: $sel, header: AnyView(
            PanelActions(resetEnabled: vm.settings.hasEdits(.light), reset: { vm.settings.reset(.light) }) {
                // lit while the values Auto chose are untouched; tap again to undo it
                PillButton(title: "Auto", system: vm.autoBusy ? "hourglass" : "wand.and.stars", active: vm.autoActive) { vm.toggleAuto() }
                    .accessibilityIdentifier("pill-auto")
                    .accessibilityValue(vm.autoActive ? "on" : "off")
            }))
    }
}

struct ColorPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var sel = "Saturation"
    var body: some View {
        if vm.colorMix {
            HSLPanel(vm: vm, back: { vm.colorMix = false })
        } else {
            // owner's order (2026-10-10): Saturation, Vibrance, then Temp and Tint
            ParamPanel(items: [
                vm.param("Saturation", \.saturation, track: Tracks.fullSaturation, section: "Colour"),
                vm.param("Vibrance", \.vibrance, track: Tracks.vibrance, section: "Colour"),
                vm.param("Temp", \.temperature, track: Tracks.temperature, section: "White balance"),
                vm.param("Tint", \.tint, track: Tracks.tint, section: "White balance"),
            ], selected: $sel, header: AnyView(
                // the page's Reset leaves the colour mix alone (it has its own resets), as before
                PanelActions(resetEnabled: pageEdited, reset: resetPage) {
                    PillButton(title: "B&W", system: "circle.lefthalf.filled", active: vm.settings.blackAndWhite) {
                        vm.settings.blackAndWhite.toggle()
                    }
                    PillButton(title: "Colour mix", system: "paintpalette", active: !vm.settings.hsl.isNeutral) { vm.colorMix = true }
                }),
               accessories: ["White balance": AnyView(
                PillButton(title: vm.wbPicking ? "Tap the photo" : "Pick", system: "eyedropper", active: vm.wbPicking) {
                    vm.wbPicking.toggle()
                }
                .accessibilityIdentifier("pill-wb"))])
        }
    }

    private var pageEdited: Bool {
        let s = vm.settings
        return s.temperature != 0 || s.tint != 0 || s.vibrance != 0 || s.saturation != 0 || s.blackAndWhite
    }

    private func resetPage() {
        var s = vm.settings
        s.temperature = 0; s.tint = 0; s.vibrance = 0; s.saturation = 0; s.blackAndWhite = false
        vm.settings = s
    }
}

/// The 8-colour mixer: pick a colour, then adjust its hue, saturation and luminance together.
struct HSLPanel: View {
    @ObservedObject var vm: EditorViewModel
    let back: () -> Void
    @State private var band = 0
    @State private var sel = "Hue"

    private static let hues: [Double] = [0, 28, 55, 120, 180, 220, 275, 315]

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30).background(Theme.chip, in: Circle())
                }
                .foregroundStyle(.white)
                ForEach(0..<8, id: \.self) { i in
                    Button { band = i } label: {
                        ZStack {
                            Circle().fill(color(i)).frame(width: 28, height: 28)
                            if vm.settings.hsl.bands[i] != HSLBand() {
                                Circle().fill(Color.black.opacity(0.55)).frame(width: 7, height: 7)
                            }
                        }
                        .padding(3)
                        .overlay(Circle().stroke(i == band ? Color.white : Color.clear, lineWidth: 2))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)
            ParamPanel(items: [
                ParamItem(id: "Hue", title: "Hue", value: bandBinding(\.hue),
                          track: [hsv(wrap(Self.hues[band] - 40)), hsv(Self.hues[band]), hsv(wrap(Self.hues[band] + 40))]),
                ParamItem(id: "Sat", title: "Saturation", value: bandBinding(\.sat),
                          track: [Color(white: 0.5), color(band)]),
                ParamItem(id: "Lum", title: "Luminance", value: bandBinding(\.lum),
                          track: [.black, color(band), .white]),
            ], selected: $sel, header: AnyView(
                HStack(spacing: 6) {
                    PillButton(title: "Reset \(HSLSettings.names[band])", system: "arrow.counterclockwise") {
                        vm.settings.hsl.bands[band] = HSLBand()
                    }
                    PillButton(title: "Reset all colours", system: "arrow.counterclockwise") {
                        vm.settings.hsl = HSLSettings()
                    }
                    Spacer()
                }))
        }
    }

    private func wrap(_ h: Double) -> Double { (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
    private func hsv(_ h: Double) -> Color { Color(hue: h / 360, saturation: 0.9, brightness: 1) }
    private func color(_ i: Int) -> Color { hsv(Self.hues[i]) }

    private func bandBinding(_ kp: WritableKeyPath<HSLBand, Double>) -> Binding<Double> {
        let i = band
        return Binding(get: { vm.settings.hsl.bands[i][keyPath: kp] }, set: { vm.settings.hsl.bands[i][keyPath: kp] = $0 })
    }
}

struct DetailPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var sel = "Texture"
    var body: some View {
        // AI Denoise is a one-off job (the screen locks with progress), not a slider you drag. Its pill sits in the
        // actions row like Light's Auto and Colour's B&W: the first tap cleans the photo, then it is lit while AI
        // Denoise is on and switches it off / on; the strength slider is in Noise reduction once the photo is cleaned.
        ParamPanel(items: [
            vm.param("Texture", \.texture, section: "Effects"),
            vm.param("Clarity", \.clarity, section: "Effects"),
            vm.param("Dehaze", \.dehaze, section: "Effects"),
            vm.param("Sharpen", \.sharpness, range: 0...100, section: "Sharpening"),
            vm.param("Masking", \.sharpenMasking, range: 0...100, section: "Sharpening"),
        ] + (EditSession.hasDenoiseModel && vm.denoiseReady ? [vm.param("AI Denoise", \.aiDenoise, range: 0...100, section: "Noise reduction")] : []) + [
            vm.param("Noise", \.noiseReduction, range: 0...100, section: "Noise reduction"),
            vm.param("Colour noise", \.colorNoise, range: 0...100, section: "Noise reduction"),
            vm.param("Vignette", \.vignette, section: "Vignette"),
            vm.param("Midpoint", \.vignetteMidpoint, range: 0...100, neutral: 50, section: "Vignette"),
            vm.param("Feather", \.vignetteFeather, range: 0...100, neutral: 50, section: "Vignette"),
            vm.param("Roundness", \.vignetteRoundness, range: 0...100, section: "Vignette"),
            vm.param("Grain", \.grain, range: 0...100, section: "Grain"),
            vm.param("Grain size", \.grainSize, range: 0...100, neutral: 25, section: "Grain"),
            vm.param("Roughness", \.grainRoughness, range: 0...100, neutral: 50, section: "Grain"),
        ], selected: $sel, header: AnyView(
            PanelActions(resetEnabled: vm.settings.hasEdits(.detail), reset: { vm.settings.reset(.detail) }) {
                if EditSession.hasDenoiseModel {
                    PillButton(title: "AI Denoise", system: "wand.and.sparkles", active: vm.denoiseReady && vm.settings.effective.aiDenoise > 0) {
                        vm.toggleDenoise()
                    }
                    .accessibilityIdentifier("btn-ai-denoise")
                    .accessibilityValue(vm.denoiseReady && vm.settings.effective.aiDenoise > 0 ? "on" : "off")
                }
            }))
    }
}

// MARK: - Presets

struct PresetsPanel: View {
    @ObservedObject var vm: EditorViewModel
    @EnvironmentObject var store: LibraryStore
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            // Strength: how much of the last preset to apply (shows until you edit something else)
            if vm.presetStrengthAvailable {
                SliderRow(item: ParamItem(id: "Strength", title: "Strength",
                                          value: Binding(get: { vm.presetAmount }, set: { vm.setPresetAmount($0) }),
                                          range: 0...100, neutral: 100), height: 40) {
                    vm.setPresetAmount(100)
                }
            }
            GeometryReader { geo in
                if geo.size.height > 160 {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 10)], spacing: 10) { tiles }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) { tiles }
                            .padding(.horizontal, 12).padding(.top, 8)
                    }
                }
            }
        }
        .onAppear { vm.loadPresetThumbs(user: store.userPresets) }
        .alert("Save preset", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { store.addUserPreset(name: n, from: vm.settings) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var tiles: some View {
        Button { newName = ""; naming = true } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.chip)
                    Image(systemName: "plus").font(.title3)
                }
                .frame(width: 72, height: 72)
                Text("Save").font(.caption2)
            }
        }
        ForEach(Preset.all) { p in
            tile(name: p.name, image: vm.presetThumbs[p.name]) { vm.apply(p) }
        }
        ForEach(store.userPresets) { p in
            tile(name: p.name, image: vm.presetThumbs[p.id.uuidString]) { vm.apply(preset: p.settings) }
                .contextMenu {
                    Button(role: .destructive) { store.deleteUserPreset(p) } label: {
                        Label("Delete preset", systemImage: "trash")
                    }
                }
        }
    }

    private func tile(name: String, image: UIImage?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Color(white: 0.15)
                    if let image { Image(uiImage: image).resizable().scaledToFill() }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(name).font(.caption2).foregroundStyle(.primary)
            }
        }
    }
}

// MARK: - Colour grading (three colour wheels)

/// Hue ring with saturation towards the rim. Drag the puck; angle = hue, distance from centre = saturation.
struct ColorWheel: View {
    @Binding var hue: Double
    @Binding var sat: Double

    private static let ring: [Color] = (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let r = d / 2
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let a = hue * .pi / 180
            let pr = CGFloat(sat / 100) * r
            ZStack {
                Circle().fill(AngularGradient(colors: Self.ring, center: .center))
                Circle().fill(RadialGradient(colors: [Color(white: 0.5), Color(white: 0.5).opacity(0)],
                                             center: .center, startRadius: 0, endRadius: r))
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)
                // guide cross
                Path { p in
                    p.move(to: CGPoint(x: c.x - r, y: c.y)); p.addLine(to: CGPoint(x: c.x + r, y: c.y))
                    p.move(to: CGPoint(x: c.x, y: c.y - r)); p.addLine(to: CGPoint(x: c.x, y: c.y + r))
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                Circle()
                    .fill(sat > 0.5 ? Color(hue: hue / 360, saturation: min(sat / 100 + 0.2, 1), brightness: 1) : Color.white.opacity(0.9))
                    .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .frame(width: 24, height: 24)
                    .position(x: c.x + cos(a) * pr, y: c.y + sin(a) * pr)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let dx = v.location.x - c.x, dy = v.location.y - c.y
                let dist = hypot(dx, dy)
                var deg = atan2(dy, dx) * 180 / .pi
                if deg < 0 { deg += 360 }
                if dist > 4 { hue = (deg * 10).rounded() / 10 }
                sat = (min(dist / r, 1) * 100).rounded()
            })
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Colour grading. Like Lightroom on a phone: one big wheel at a time (Shadows / Midtones / Highlights) with full-size
/// Hue, Saturation and Luminance sliders, plus an "All" overview with the three wheels side by side, Blend and Balance.
struct GradePanel: View {
    @ObservedObject var vm: EditorViewModel
    @AppStorage("gradeTab") private var tab = "Shadows"
    private let zones: [(String, WritableKeyPath<ColorGrading, GradeZone>)] = [
        ("Shadows", \.shadows), ("Midtones", \.midtones), ("Highlights", \.highlights),
    ]
    /// The three zone wheels plus Global (tints every tone): each has its own big-wheel tab.
    private var allZones: [(String, WritableKeyPath<ColorGrading, GradeZone>)] { zones + [("Global", \.global)] }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 6) {
                tabs
                if let i = allZones.firstIndex(where: { $0.0 == tab }) {
                    zoneDetail(i, size: geo.size)
                } else {
                    overview
                }
            }
        }
    }

    private func edited(_ z: GradeZone) -> Bool { z.sat != 0 || z.lum != 0 }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(["All"] + allZones.map(\.0), id: \.self) { t in
                let i = allZones.firstIndex { $0.0 == t }
                let dot = i.map { edited(vm.settings.grading[keyPath: allZones[$0].1]) } ?? !vm.settings.grading.isNeutral
                Button { tab = t } label: {
                    HStack(spacing: 4) {
                        Text(t).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                        if dot { EditedDot() }
                    }
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .background(tab == t ? Theme.accent.opacity(0.85) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(tab == t ? Color.white : Color(white: 0.65))
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("grade-tab-\(t)")
            }
        }
        .padding(2)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 12).padding(.top, 6)
    }

    // MARK: one zone, big

    private func zoneDetail(_ i: Int, size: CGSize) -> some View {
        let kp = allZones[i].1
        let z = vm.settings.grading[keyPath: kp]
        let wheel = max(140, min(size.height - 32 - 3 * 40 - 34, size.width - 150, 260))
        return ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                HStack(alignment: .center, spacing: 14) {
                    ColorWheel(hue: zb(kp, \.hue), sat: zb(kp, \.sat))
                        .frame(width: wheel, height: wheel)
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("grade-wheel")
                    VStack(alignment: .leading, spacing: 10) {
                        Text(allZones[i].0).font(.system(size: 15, weight: .semibold))
                        Circle()
                            .fill(z.sat > 0.5 ? Color(hue: z.hue / 360, saturation: min(z.sat / 100 + 0.2, 1), brightness: 1)
                                              : Color(white: 0.5))
                            .frame(width: 34, height: 34)
                            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1.5))
                        PillButton(title: "Reset", system: "arrow.counterclockwise") {
                            vm.settings.grading[keyPath: kp] = GradeZone()
                        }
                        .opacity(z == GradeZone() ? 0.45 : 1)
                        .disabled(z == GradeZone())
                        .accessibilityIdentifier("grade-reset-zone")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                rows([
                    ParamItem(id: "Hue", title: "Hue", value: zb(kp, \.hue), range: 0...360, neutral: 0, track: Tracks.hue),
                    ParamItem(id: "Grade saturation", title: "Saturation", value: zb(kp, \.sat), range: 0...100, neutral: 0,
                              track: [Color(white: 0.5), Color(hue: z.hue / 360, saturation: 0.9, brightness: 1)]),
                    ParamItem(id: "Grade luminance", title: "Luminance", value: zb(kp, \.lum), track: [.black, .white]),
                ])
            }
            .padding(.bottom, 6)
        }
    }

    // MARK: all three

    private var overview: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in wheelColumn(i) }
                }
                .padding(.horizontal, 12).padding(.top, 6)
                rows([
                    ParamItem(id: "Blend", title: "Blend", value: gb(\.blending), range: 0...100, neutral: 50),
                    ParamItem(id: "Balance", title: "Balance", value: gb(\.balance)),
                ])
                HStack {
                    Spacer()
                    PillButton(title: "Reset all", system: "arrow.counterclockwise") { vm.settings.grading = ColorGrading() }
                        .opacity(vm.settings.grading == ColorGrading() ? 0.45 : 1)
                        .disabled(vm.settings.grading == ColorGrading())
                }
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 6)
        }
    }

    private func wheelColumn(_ i: Int) -> some View {
        let kp = zones[i].1
        let z = vm.settings.grading[keyPath: kp]
        return VStack(spacing: 4) {
            // tap the name to open that wheel big
            Button { tab = zones[i].0 } label: {
                HStack(spacing: 3) {
                    Text(zones[i].0).font(.system(size: 12, weight: .semibold))
                    if edited(z) { EditedDot() }
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
            }
            .foregroundStyle(.white)
            ColorWheel(hue: zb(kp, \.hue), sat: zb(kp, \.sat))
                .frame(maxWidth: 124)
            HStack(spacing: 4) {
                Image(systemName: "sun.max").font(.system(size: 10)).foregroundStyle(.secondary)
                ScrubSlider(value: zb(kp, \.lum), height: 30, bubble: false)
                Button { vm.settings.grading[keyPath: kp] = GradeZone() } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .foregroundStyle(z == GradeZone() ? Color(white: 0.35) : Theme.accent)
                .disabled(z == GradeZone())
            }
            Text("H \(Int(z.hue))°  S \(Int(z.sat))  L \(Int(z.lum))")
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: helpers

    private func rows(_ items: [ParamItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { it in
                SliderRow(item: it, height: 40) {
                    it.value.wrappedValue = it.neutral ?? 0
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
    }

    private func zb(_ kp: WritableKeyPath<ColorGrading, GradeZone>, _ f: WritableKeyPath<GradeZone, Double>) -> Binding<Double> {
        Binding(get: { vm.settings.grading[keyPath: kp][keyPath: f] },
                set: { vm.settings.grading[keyPath: kp][keyPath: f] = $0 })
    }

    private func gb(_ kp: WritableKeyPath<ColorGrading, Double>) -> Binding<Double> {
        Binding(get: { vm.settings.grading[keyPath: kp] }, set: { vm.settings.grading[keyPath: kp] = $0 })
    }
}
