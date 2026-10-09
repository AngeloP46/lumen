import SwiftUI

extension EditorViewModel {
    /// A panel entry bound to one Double on EditSettings.
    func param(_ title: String, _ kp: WritableKeyPath<EditSettings, Double>,
               range: ClosedRange<Double> = -100...100, decimals: Int = 0,
               neutral: Double? = nil, track: [Color]? = nil) -> ParamItem {
        ParamItem(id: title, title: title,
                  value: Binding(get: { self.settings[keyPath: kp] }, set: { self.settings[keyPath: kp] = $0 }),
                  range: range, decimals: decimals, neutral: neutral, track: track)
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
        var items = [
            vm.param("Exposure", \.exposure, range: -5...5, decimals: 2),
            vm.param("Contrast", \.contrast),
            vm.param("Highlights", \.highlights),
            vm.param("Shadows", \.shadows),
            vm.param("Whites", \.whites),
            vm.param("Blacks", \.blacks),
        ]
        if vm.settings.hdr {
            items.append(vm.param("HDR range", \.hdrStops, range: 1...3, decimals: 1, neutral: 2))
        }
        return ParamPanel(items: items, selected: $sel, header: AnyView(
            HStack(spacing: 6) {
                PillButton(title: "Auto", system: "wand.and.stars") { vm.auto() }
                PillButton(title: "HDR", system: "sun.max", active: vm.settings.hdr) {
                    vm.settings.hdr.toggle()
                }
                .accessibilityIdentifier("pill-hdr")
                PillButton(title: "Reset", system: "arrow.counterclockwise") {
                    vm.settings.exposure = 0; vm.settings.contrast = 0; vm.settings.highlights = 0
                    vm.settings.shadows = 0; vm.settings.whites = 0; vm.settings.blacks = 0
                }
                Spacer()
            }))
    }
}

struct ColorPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var sel = "Temp"
    var body: some View {
        if vm.colorMix {
            HSLPanel(vm: vm, back: { vm.colorMix = false })
        } else {
            ParamPanel(items: [
                vm.param("Temp", \.temperature, track: Tracks.temperature),
                vm.param("Tint", \.tint, track: Tracks.tint),
                vm.param("Vibrance", \.vibrance),
                vm.param("Saturation", \.saturation),
            ], selected: $sel, header: AnyView(
                HStack(spacing: 6) {
                    PillButton(title: "B&W", system: "circle.lefthalf.filled", active: vm.settings.blackAndWhite) {
                        vm.settings.blackAndWhite.toggle()
                    }
                    PillButton(title: "Colour mix", system: "paintpalette") { vm.colorMix = true }
                    PillButton(title: "Reset", system: "arrow.counterclockwise") {
                        vm.settings.temperature = 0; vm.settings.tint = 0
                        vm.settings.vibrance = 0; vm.settings.saturation = 0; vm.settings.blackAndWhite = false
                    }
                    Spacer()
                }))
        }
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
        ParamPanel(items: [
            vm.param("Texture", \.texture),
            vm.param("Clarity", \.clarity),
            vm.param("Dehaze", \.dehaze),
            vm.param("Sharpen", \.sharpness, range: 0...100),
            vm.param("Masking", \.sharpenMasking, range: 0...100),
            vm.param("Noise", \.noiseReduction, range: 0...100),
            vm.param("Colour noise", \.colorNoise, range: 0...100),
            vm.param("Vignette", \.vignette),
            vm.param("Midpoint", \.vignetteMidpoint, range: 0...100, neutral: 50),
            vm.param("Feather", \.vignetteFeather, range: 0...100, neutral: 50),
            vm.param("Roundness", \.vignetteRoundness, range: 0...100),
            vm.param("Grain", \.grain, range: 0...100),
            vm.param("Grain size", \.grainSize, range: 0...100, neutral: 25),
            vm.param("Roughness", \.grainRoughness, range: 0...100, neutral: 50),
        ], selected: $sel, header: AnyView(
            HStack {
                PillButton(title: "Reset", system: "arrow.counterclockwise") {
                    var s = vm.settings
                    s.texture = 0; s.clarity = 0; s.dehaze = 0; s.sharpness = 0; s.sharpenMasking = 0
                    s.noiseReduction = 0; s.colorNoise = 0; s.vignette = 0; s.vignetteMidpoint = 50
                    s.vignetteFeather = 50; s.vignetteRoundness = 0; s.grain = 0; s.grainSize = 25; s.grainRoughness = 50
                    vm.settings = s
                }
                Spacer()
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
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
            .padding(.horizontal, 12).padding(.top, 8)
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

struct GradePanel: View {
    @ObservedObject var vm: EditorViewModel
    private let zones: [(String, WritableKeyPath<ColorGrading, GradeZone>)] = [
        ("Shadows", \.shadows), ("Midtones", \.midtones), ("Highlights", \.highlights),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in wheelColumn(i) }
                }
                .padding(.horizontal, 12).padding(.top, 8)
                HStack(spacing: 14) {
                    LabeledSlider(title: "Blend", value: gb(\.blending), range: 0...100, neutral: 50, labelWidth: 38)
                    LabeledSlider(title: "Balance", value: gb(\.balance), range: -100...100, neutral: 0, labelWidth: 50)
                }
                .padding(.horizontal, 14)
                HStack {
                    Spacer()
                    PillButton(title: "Reset all", system: "arrow.counterclockwise") { vm.settings.grading = ColorGrading() }
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
            HStack {
                Text(zones[i].0).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { vm.settings.grading[keyPath: kp] = GradeZone() } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11))
                }
                .foregroundStyle(z == GradeZone() ? Color(white: 0.35) : Theme.accent)
            }
            ColorWheel(hue: Binding(get: { vm.settings.grading[keyPath: kp].hue },
                                    set: { vm.settings.grading[keyPath: kp].hue = $0 }),
                       sat: Binding(get: { vm.settings.grading[keyPath: kp].sat },
                                    set: { vm.settings.grading[keyPath: kp].sat = $0 }))
                .frame(maxWidth: 124)
            HStack(spacing: 4) {
                Image(systemName: "sun.max").font(.system(size: 10)).foregroundStyle(.secondary)
                ScrubSlider(value: Binding(get: { vm.settings.grading[keyPath: kp].lum },
                                           set: { vm.settings.grading[keyPath: kp].lum = $0 }),
                            height: 26, bubble: false)
            }
            Text("H \(Int(z.hue))°  S \(Int(z.sat))  L \(Int(z.lum))")
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func gb(_ kp: WritableKeyPath<ColorGrading, Double>) -> Binding<Double> {
        Binding(get: { vm.settings.grading[keyPath: kp] }, set: { vm.settings.grading[keyPath: kp] = $0 })
    }
}
