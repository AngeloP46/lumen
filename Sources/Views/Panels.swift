import SwiftUI

struct LightPanel: View {
    @ObservedObject var vm: EditorViewModel
    var body: some View {
        VStack(spacing: 0) {
            KPSlider(vm: vm, title: "Exposure", kp: \.exposure, range: -5...5, decimals: 2)
            KPSlider(vm: vm, title: "Contrast", kp: \.contrast)
            KPSlider(vm: vm, title: "Highlights", kp: \.highlights)
            KPSlider(vm: vm, title: "Shadows", kp: \.shadows)
            KPSlider(vm: vm, title: "Whites", kp: \.whites)
            KPSlider(vm: vm, title: "Blacks", kp: \.blacks)
        }
    }
}

struct ColorPanel: View {
    @ObservedObject var vm: EditorViewModel
    var body: some View {
        VStack(spacing: 0) {
            KPSlider(vm: vm, title: "Temperature", kp: \.temperature, track: Tracks.temperature)
            KPSlider(vm: vm, title: "Tint", kp: \.tint, track: Tracks.tint)
            KPSlider(vm: vm, title: "Vibrance", kp: \.vibrance)
            KPSlider(vm: vm, title: "Saturation", kp: \.saturation)
        }
    }
}

struct EffectsPanel: View {
    @ObservedObject var vm: EditorViewModel
    var body: some View {
        VStack(spacing: 0) {
            KPSlider(vm: vm, title: "Texture", kp: \.texture)
            KPSlider(vm: vm, title: "Clarity", kp: \.clarity)
            KPSlider(vm: vm, title: "Dehaze", kp: \.dehaze)
            KPSlider(vm: vm, title: "Vignette", kp: \.vignette)
            KPSlider(vm: vm, title: "Grain", kp: \.grain, range: 0...100)
        }
    }
}

struct DetailPanel: View {
    @ObservedObject var vm: EditorViewModel
    var body: some View {
        VStack(spacing: 0) {
            KPSlider(vm: vm, title: "Sharpening", kp: \.sharpness, range: 0...100)
            KPSlider(vm: vm, title: "Noise reduction", kp: \.noiseReduction, range: 0...100)
            Text("Tip: zoom in (pinch) to judge sharpening and noise.")
                .font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
        }
    }
}

struct CropPanel: View {
    @ObservedObject var vm: EditorViewModel
    private let aspects: [(String, Double)] = [
        ("Original", 0), ("1:1", 1), ("4:5", 0.8), ("5:4", 1.25),
        ("3:2", 1.5), ("2:3", 2.0 / 3), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16),
    ]

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(aspects, id: \.0) { name, ratio in
                        let selected = abs(vm.settings.cropAspect - ratio) < 0.001
                        Button(name) {
                            vm.settings.cropAspect = ratio
                            vm.settings.cropX = 0
                            vm.settings.cropY = 0
                        }
                        .buttonStyle(.bordered)
                        .tint(selected ? Color.accentColor : Color.gray)
                    }
                }
            }
            KPSlider(vm: vm, title: "Straighten", kp: \.straighten, range: -45...45, decimals: 1)
            KPSlider(vm: vm, title: "Zoom", kp: \.cropZoom, range: 1...3, decimals: 2)
            HStack(spacing: 12) {
                Button { vm.settings.quarterTurns -= 1 } label: { Label("Left", systemImage: "rotate.left") }
                Button { vm.settings.quarterTurns += 1 } label: { Label("Right", systemImage: "rotate.right") }
                Button {
                    vm.settings.cropAspect = 0; vm.settings.cropZoom = 1
                    vm.settings.cropX = 0; vm.settings.cropY = 0
                    vm.settings.straighten = 0; vm.settings.quarterTurns = 0
                } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
            }
            .buttonStyle(.bordered)
            Text("Drag the photo to reposition the crop.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct PresetsPanel: View {
    @ObservedObject var vm: EditorViewModel
    @EnvironmentObject var store: LibraryStore
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Preset.all) { p in
                        tile(name: p.name, image: vm.presetThumbs[p.name]) { vm.apply(p) }
                    }
                    ForEach(store.userPresets) { p in
                        tile(name: p.name, image: vm.presetThumbs[p.id.uuidString]) {
                            vm.apply(preset: p.settings)
                        }
                        .contextMenu {
                            Button(role: .destructive) { store.deleteUserPreset(p) } label: {
                                Label("Delete preset", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            Button { newName = ""; naming = true } label: {
                Label("Save current edit as preset", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
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
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(name).font(.caption2).foregroundStyle(.primary)
            }
        }
    }
}

struct MixPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var mode = 0 // 0 hue, 1 saturation, 2 luminance
    private let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]

    var body: some View {
        VStack(spacing: 2) {
            Picker("Mode", selection: $mode) {
                Text("Hue").tag(0)
                Text("Saturation").tag(1)
                Text("Luminance").tag(2)
            }
            .pickerStyle(.segmented)
            ForEach(0..<8, id: \.self) { i in
                AdjustSlider(title: HSLSettings.names[i], value: binding(i), tint: colors[i])
            }
        }
    }

    private func binding(_ i: Int) -> Binding<Double> {
        Binding(
            get: {
                let b = vm.settings.hsl.bands[i]
                if mode == 0 { return b.hue }
                if mode == 1 { return b.sat }
                return b.lum
            },
            set: { v in
                if mode == 0 { vm.settings.hsl.bands[i].hue = v }
                else if mode == 1 { vm.settings.hsl.bands[i].sat = v }
                else { vm.settings.hsl.bands[i].lum = v }
            })
    }
}

struct GradePanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var zone = 0
    private let zones: [WritableKeyPath<ColorGrading, GradeZone>] = [\.shadows, \.midtones, \.highlights]

    var body: some View {
        let z = vm.settings.grading[keyPath: zones[zone]]
        VStack(spacing: 2) {
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
            AdjustSlider(title: "Hue", value: zoneBinding(\.hue), range: 0...360, track: Tracks.hue)
            AdjustSlider(title: "Saturation", value: zoneBinding(\.sat), range: 0...100, track: Tracks.saturation)
            AdjustSlider(title: "Luminance", value: zoneBinding(\.lum))
            KPGrade(vm: vm, title: "Blending", kp: \.blending, range: 0...100)
            KPGrade(vm: vm, title: "Balance", kp: \.balance, range: -100...100)
        }
    }

    private func zoneBinding(_ field: WritableKeyPath<GradeZone, Double>) -> Binding<Double> {
        let kp = zones[zone]
        return Binding(get: { vm.settings.grading[keyPath: kp][keyPath: field] },
                       set: { vm.settings.grading[keyPath: kp][keyPath: field] = $0 })
    }
}

private struct KPGrade: View {
    @ObservedObject var vm: EditorViewModel
    let title: String
    let kp: WritableKeyPath<ColorGrading, Double>
    let range: ClosedRange<Double>

    var body: some View {
        AdjustSlider(title: title,
                     value: Binding(get: { vm.settings.grading[keyPath: kp] },
                                    set: { vm.settings.grading[keyPath: kp] = $0 }),
                     range: range)
    }
}
