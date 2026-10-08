import SwiftUI

extension EditorViewModel {
    /// A strip entry bound to one Double on EditSettings.
    func param(_ title: String, _ kp: WritableKeyPath<EditSettings, Double>,
               range: ClosedRange<Double> = -100...100, decimals: Int = 0,
               neutral: Double? = nil, track: [Color]? = nil) -> ParamItem {
        ParamItem(id: title, title: title,
                  value: Binding(get: { self.settings[keyPath: kp] }, set: { self.settings[keyPath: kp] = $0 }),
                  range: range, decimals: decimals, neutral: neutral, track: track)
    }
}

// MARK: - Light / Color / Effects / Detail

struct LightPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var sel = "Exposure"
    var body: some View {
        ParamStrip(items: [
            vm.param("Exposure", \.exposure, range: -5...5, decimals: 2),
            vm.param("Contrast", \.contrast),
            vm.param("Highlights", \.highlights),
            vm.param("Shadows", \.shadows),
            vm.param("Whites", \.whites),
            vm.param("Blacks", \.blacks),
        ], selected: $sel, leading: AnyView(
            Button { vm.auto() } label: {
                Label("Auto", systemImage: "wand.and.stars").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 12)
                    .background(Theme.accent.opacity(0.9), in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(.white)
            }))
    }
}

struct ColorPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var sel = "Temp"
    var body: some View {
        ParamStrip(items: [
            vm.param("Temp", \.temperature, track: Tracks.temperature),
            vm.param("Tint", \.tint, track: Tracks.tint),
            vm.param("Vibrance", \.vibrance),
            vm.param("Saturation", \.saturation),
        ], selected: $sel, leading: AnyView(
            Button { vm.settings.blackAndWhite.toggle() } label: {
                Label("B&W", systemImage: "circle.lefthalf.filled").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 12)
                    .background(vm.settings.blackAndWhite ? Theme.accent : Theme.chip, in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(.white)
            }))
    }
}

struct EffectsPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var sel = "Texture"
    var body: some View {
        ParamStrip(items: [
            vm.param("Texture", \.texture),
            vm.param("Clarity", \.clarity),
            vm.param("Dehaze", \.dehaze),
            vm.param("Vignette", \.vignette),
            vm.param("Midpoint", \.vignetteMidpoint, range: 0...100, neutral: 50),
            vm.param("Feather", \.vignetteFeather, range: 0...100, neutral: 50),
            vm.param("Roundness", \.vignetteRoundness, range: 0...100),
            vm.param("Grain", \.grain, range: 0...100),
            vm.param("Grain size", \.grainSize, range: 0...100, neutral: 25),
            vm.param("Roughness", \.grainRoughness, range: 0...100, neutral: 50),
        ], selected: $sel, leading: nil)
    }
}

struct DetailPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var sel = "Sharpen"
    var body: some View {
        ParamStrip(items: [
            vm.param("Sharpen", \.sharpness, range: 0...100),
            vm.param("Masking", \.sharpenMasking, range: 0...100),
            vm.param("Noise", \.noiseReduction, range: 0...100),
            vm.param("Colour noise", \.colorNoise, range: 0...100),
        ], selected: $sel, leading: nil)
    }
}

// MARK: - Crop

struct CropPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var sel = "Angle"
    private let aspects: [(String, Double)] = [
        ("Original", 0), ("1:1", 1), ("4:5", 0.8), ("5:4", 1.25),
        ("3:2", 1.5), ("2:3", 2.0 / 3), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16),
    ]

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    IconButton(system: "rotate.left") { vm.settings.quarterTurns -= 1 }
                    IconButton(system: "rotate.right") { vm.settings.quarterTurns += 1 }
                    ForEach(aspects, id: \.0) { name, ratio in
                        Chip(title: name, selected: abs(vm.settings.cropAspect - ratio) < 0.001) {
                            vm.settings.cropAspect = ratio
                            vm.settings.cropX = 0
                            vm.settings.cropY = 0
                        }
                    }
                    IconButton(system: "arrow.counterclockwise") {
                        vm.settings.cropAspect = 0; vm.settings.cropZoom = 1
                        vm.settings.cropX = 0; vm.settings.cropY = 0
                        vm.settings.straighten = 0; vm.settings.quarterTurns = 0
                    }
                }
                .padding(.horizontal, 12)
            }
            ParamStrip(items: [
                vm.param("Angle", \.straighten, range: -45...45, decimals: 1),
                vm.param("Zoom", \.cropZoom, range: 1...3, decimals: 2),
            ], selected: $sel, leading: nil)
            Text("Drag the photo to reposition the crop.").font(.caption2).foregroundStyle(.secondary)
        }
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
            .padding(.horizontal, 12)
        }
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

// MARK: - Colour mixer

struct MixPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var mode = 0 // 0 hue, 1 saturation, 2 luminance
    @State private var sel = "Red"
    private let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]

    var body: some View {
        VStack(spacing: 4) {
            Picker("Mode", selection: $mode) {
                Text("Hue").tag(0)
                Text("Saturation").tag(1)
                Text("Luminance").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            ParamStrip(items: (0..<8).map { i in
                ParamItem(id: HSLSettings.names[i], title: HSLSettings.names[i], value: binding(i), dot: colors[i])
            }, selected: $sel, leading: nil)
        }
    }

    private func binding(_ i: Int) -> Binding<Double> {
        Binding(
            get: {
                let b = vm.settings.hsl.bands[i]
                return mode == 0 ? b.hue : (mode == 1 ? b.sat : b.lum)
            },
            set: { v in
                if mode == 0 { vm.settings.hsl.bands[i].hue = v }
                else if mode == 1 { vm.settings.hsl.bands[i].sat = v }
                else { vm.settings.hsl.bands[i].lum = v }
            })
    }
}

// MARK: - Colour grading

struct GradePanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var zone = 0
    @State private var sel = "Hue"
    private let zones: [WritableKeyPath<ColorGrading, GradeZone>] = [\.shadows, \.midtones, \.highlights]

    var body: some View {
        let z = vm.settings.grading[keyPath: zones[zone]]
        VStack(spacing: 4) {
            HStack {
                Picker("Zone", selection: $zone) {
                    Text("Shadows").tag(0)
                    Text("Midtones").tag(1)
                    Text("Highlights").tag(2)
                }
                .pickerStyle(.segmented)
                Circle()
                    .fill(Color(hue: z.hue / 360, saturation: z.sat / 100, brightness: 1))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1))
            }
            .padding(.horizontal, 12)
            ParamStrip(items: [
                ParamItem(id: "Hue", title: "Hue", value: zoneBinding(\.hue), range: 0...360, track: Tracks.hue),
                ParamItem(id: "Sat", title: "Sat", value: zoneBinding(\.sat), range: 0...100, track: Tracks.saturation),
                ParamItem(id: "Lum", title: "Lum", value: zoneBinding(\.lum)),
                ParamItem(id: "Blending", title: "Blending",
                          value: Binding(get: { vm.settings.grading.blending }, set: { vm.settings.grading.blending = $0 }),
                          range: 0...100, neutral: 50),
                ParamItem(id: "Balance", title: "Balance",
                          value: Binding(get: { vm.settings.grading.balance }, set: { vm.settings.grading.balance = $0 })),
            ], selected: $sel, leading: nil)
        }
    }

    private func zoneBinding(_ field: WritableKeyPath<GradeZone, Double>) -> Binding<Double> {
        let kp = zones[zone]
        return Binding(get: { vm.settings.grading[keyPath: kp][keyPath: field] },
                       set: { vm.settings.grading[keyPath: kp][keyPath: field] = $0 })
    }
}
