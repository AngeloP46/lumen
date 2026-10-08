import SwiftUI

// MARK: - Panel

struct MaskPanel: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Menu {
                        ForEach(MaskKind.allCases) { k in
                            Button { vm.addMask(k) } label: { Label(k.title, systemImage: k.icon) }
                        }
                    } label: {
                        Label("Add mask", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    ForEach(vm.settings.masks) { m in
                        Button { vm.selectedMaskID = m.id } label: { Label(m.name, systemImage: m.kind.icon) }
                            .buttonStyle(.bordered)
                            .tint(m.id == vm.selectedMaskID ? Color.accentColor : Color.gray)
                    }
                }
            }
            if let m = vm.selectedMask {
                detail(m)
            } else {
                Text("Add a mask to edit just part of the photo — brush, gradients, subject, background, luminance or colour.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func mb<T>(_ m: Mask, _ kp: WritableKeyPath<Mask, T>) -> Binding<T> {
        Binding(get: { vm.settings.masks.first { $0.id == m.id }?[keyPath: kp] ?? m[keyPath: kp] },
                set: { v in vm.updateMask(m.id) { $0[keyPath: kp] = v } })
    }

    private func adj(_ m: Mask, _ title: String, _ kp: WritableKeyPath<LocalAdjust, Double>,
                     _ range: ClosedRange<Double> = -100...100, decimals: Int = 0) -> some View {
        AdjustSlider(
            title: title,
            value: Binding(get: { (vm.settings.masks.first { $0.id == m.id }?.adjust ?? m.adjust)[keyPath: kp] },
                           set: { v in vm.updateMask(m.id) { $0.adjust[keyPath: kp] = v } }),
            range: range, decimals: decimals)
    }

    @ViewBuilder
    private func detail(_ m: Mask) -> some View {
        switch m.kind {
        case .brush:
            Text("Paint on the photo.").font(.caption).foregroundStyle(.secondary)
            AdjustSlider(title: "Brush size", value: $vm.brushSize, range: 0.01...0.25, decimals: 2)
            AdjustSlider(title: "Feather", value: mb(m, \.feather), range: 0...100)
            Toggle("Erase", isOn: $vm.brushErase).font(.caption)
        case .linear:
            Text("Drag the two handles. Full effect at the first, none at the second.")
                .font(.caption).foregroundStyle(.secondary)
        case .radial:
            Text("Drag the centre and radius handles.").font(.caption).foregroundStyle(.secondary)
            AdjustSlider(title: "Feather", value: mb(m, \.feather), range: 0...100)
        case .subject, .background:
            Text("Found automatically with on-device AI (the first time takes a moment).")
                .font(.caption).foregroundStyle(.secondary)
        case .luminance:
            AdjustSlider(title: "Darkest", value: mb(m, \.lumLow), range: 0...1, decimals: 2)
            AdjustSlider(title: "Brightest", value: mb(m, \.lumHigh), range: 0...1, decimals: 2)
            AdjustSlider(title: "Smoothness", value: mb(m, \.smooth), range: 0.02...0.5, decimals: 2)
        case .color:
            HStack {
                Text("Tap the photo to pick a colour").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(Color(red: m.colorR, green: m.colorG, blue: m.colorB)).frame(width: 22, height: 22)
            }
            AdjustSlider(title: "Range", value: mb(m, \.tolerance), range: 0.05...0.8, decimals: 2)
        }

        Toggle("Invert", isOn: mb(m, \.invert)).font(.caption)
        AdjustSlider(title: "Mask opacity", value: mb(m, \.amount), range: 0...100)

        Text("Adjustments inside this mask").font(.caption.bold()).padding(.top, 6)
        adj(m, "Exposure", \.exposure, -5...5, decimals: 2)
        adj(m, "Contrast", \.contrast)
        adj(m, "Highlights", \.highlights)
        adj(m, "Shadows", \.shadows)
        adj(m, "Temperature", \.temperature)
        adj(m, "Tint", \.tint)
        adj(m, "Saturation", \.saturation)
        adj(m, "Clarity", \.clarity)
        adj(m, "Sharpening", \.sharpness, 0...100)

        Button(role: .destructive) { vm.deleteMask(m.id) } label: {
            Label("Delete mask", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .padding(.top, 6)
    }
}

// MARK: - On-photo overlay

private struct HandleDot: View {
    var body: some View {
        Circle()
            .fill(Color.black.opacity(0.35))
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .frame(width: 30, height: 30)
    }
}

/// Sits exactly on top of the displayed (un-cropped) preview; coordinates are normalised 0...1, top-left origin.
struct MaskOverlay: View {
    @ObservedObject var vm: EditorViewModel
    let size: CGSize
    @State private var drawing = false

    var body: some View {
        ZStack {
            if let o = vm.maskOverlay {
                Image(uiImage: o).resizable().frame(width: size.width, height: size.height).allowsHitTesting(false)
            }
            if let m = vm.selectedMask {
                controls(m)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "maskSpace")
    }

    private func norm(_ p: CGPoint) -> Pt {
        Pt(x: Double(min(max(p.x / size.width, 0), 1)), y: Double(min(max(p.y / size.height, 0), 1)))
    }

    @ViewBuilder
    private func controls(_ m: Mask) -> some View {
        switch m.kind {
        case .brush:
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("maskSpace"))
                    .onChanged { v in
                        let p = norm(v.location)
                        if drawing { vm.extendStroke(p) } else { drawing = true; vm.beginStroke(p) }
                    }
                    .onEnded { _ in drawing = false })
        case .color:
            Color.clear.contentShape(Rectangle())
                .gesture(SpatialTapGesture(coordinateSpace: .named("maskSpace")).onEnded { v in
                    vm.pickColor(at: norm(v.location))
                })
        case .linear:
            linearHandles(m)
        case .radial:
            radialHandles(m)
        default:
            EmptyView()
        }
    }

    private func handle(at p: CGPoint, onDrag: @escaping (Pt) -> Void) -> some View {
        HandleDot()
            .position(p)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("maskSpace"))
                .onChanged { v in onDrag(norm(v.location)) })
    }

    @ViewBuilder
    private func linearHandles(_ m: Mask) -> some View {
        let a = CGPoint(x: m.x0 * size.width, y: m.y0 * size.height)
        let b = CGPoint(x: m.x1 * size.width, y: m.y1 * size.height)
        Path { p in p.move(to: a); p.addLine(to: b) }
            .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .allowsHitTesting(false)
        handle(at: a) { p in vm.updateMask(m.id) { $0.x0 = p.x; $0.y0 = p.y } }
        handle(at: b) { p in vm.updateMask(m.id) { $0.x1 = p.x; $0.y1 = p.y } }
    }

    @ViewBuilder
    private func radialHandles(_ m: Mask) -> some View {
        let c = CGPoint(x: m.x0 * size.width, y: m.y0 * size.height)
        let rx = m.x1 * size.width
        let ry = m.y1 * size.height
        Ellipse()
            .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .frame(width: rx * 2, height: ry * 2)
            .position(c)
            .allowsHitTesting(false)
        handle(at: c) { p in vm.updateMask(m.id) { $0.x0 = p.x; $0.y0 = p.y } }
        handle(at: CGPoint(x: c.x + rx, y: c.y)) { p in
            vm.updateMask(m.id) { $0.x1 = max(0.02, abs(p.x - $0.x0)) }
        }
        handle(at: CGPoint(x: c.x, y: c.y + ry)) { p in
            vm.updateMask(m.id) { $0.y1 = max(0.02, abs(p.y - $0.y0)) }
        }
    }
}
