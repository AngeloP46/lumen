import SwiftUI

private enum Tool: String, CaseIterable, Identifiable {
    case presets = "Presets", crop = "Crop", light = "Light", color = "Color", mix = "Mix"
    case curve = "Curve", grade = "Grade", effects = "Effects", detail = "Detail", masks = "Masks"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .presets: return "wand.and.stars"
        case .crop: return "crop.rotate"
        case .light: return "sun.max"
        case .color: return "thermometer.medium"
        case .mix: return "paintpalette"
        case .curve: return "point.topleft.down.curvedto.point.bottomright.up"
        case .grade: return "circle.hexagongrid"
        case .effects: return "sparkles"
        case .detail: return "triangle"
        case .masks: return "circle.dashed.inset.filled"
        }
    }
}

struct EditorView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: EditorViewModel
    @AppStorage("showHistogram") private var showHistogram = true
    @State private var tool: Tool? = .light

    // pinch-zoom / pan of the preview
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    @State private var cropStart: (Double, Double)?

    private let item: LibraryItem

    init(item: LibraryItem) {
        self.item = item
        _vm = StateObject(wrappedValue: EditorViewModel(item: item))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            canvas
            if let tool {
                panel(for: tool)
                    .frame(height: panelHeight(tool))
                    .frame(maxWidth: .infinity)
                    .background(Theme.panel)
            }
            toolStrip
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { vm.start(store: store) }
        .onDisappear { vm.flushSave(); store.refreshThumbnail(item) }
        .onChange(of: tool) { _, new in
            vm.maskEditing = (new == .masks)
            if new == .masks, vm.selectedMaskID == nil, let first = vm.settings.masks.first { vm.selectMask(first.id) }
            if new == .presets { vm.loadPresetThumbs(user: store.userPresets) }
            if new == .masks || new == .crop { resetZoom() }
        }
        .sheet(item: $vm.exported) { result in ExportSheet(vm: vm, url: result.url) }
        .alert("Lumen", isPresented: Binding(get: { vm.message != nil },
                                             set: { if !$0 { vm.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(vm.message ?? "") }
    }

    private func panelHeight(_ t: Tool) -> CGFloat {
        switch t {
        case .light, .color, .effects, .detail: return 96
        case .presets: return 118
        case .crop: return 156
        case .curve: return 196
        case .mix, .grade: return 142
        case .masks:
            if vm.settings.masks.isEmpty || vm.selectedMask == nil { return 170 }
            return vm.maskTab == .shape ? 270 : 150
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            IconButton(system: "chevron.left") { dismiss() }
            Text(item.displayName).font(.system(size: 14, weight: .medium)).lineLimit(1).foregroundStyle(Color(white: 0.8))
            Spacer()
            IconButton(system: "arrow.uturn.backward", disabled: !vm.canUndo) { vm.undo() }
            IconButton(system: "arrow.uturn.forward", disabled: !vm.canRedo) { vm.redo() }
            Image(systemName: "eye")
                .font(.system(size: 17))
                .frame(width: 38, height: 38)
                .foregroundStyle(vm.showOriginal ? Theme.accent : Color.white)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 200, pressing: { vm.showOriginal = $0 }, perform: {})
            Menu {
                Toggle("Histogram", isOn: $showHistogram)
                Menu("Rating") {
                    let current = store.item(item.id) ?? item
                    ForEach(0...5, id: \.self) { n in
                        Button { store.setRating(current, n == current.rating ? 0 : n) } label: {
                            Label(n == 0 ? "No rating" : String(repeating: "★", count: n),
                                  systemImage: current.rating == n ? "checkmark" : "star")
                        }
                    }
                    Button { store.setFlag(current, 1) } label: { Label("Pick", systemImage: "flag") }
                    Button { store.setFlag(current, -1) } label: { Label("Reject", systemImage: "flag.slash") }
                }
                Divider()
                Button { store.clipboard = vm.settings } label: { Label("Copy edits", systemImage: "doc.on.doc") }
                Button { if let c = store.clipboard { vm.settings = c } } label: {
                    Label("Paste edits", systemImage: "doc.on.clipboard")
                }.disabled(store.clipboard == nil)
                Button(role: .destructive) { vm.reset() } label: { Label("Reset all", systemImage: "arrow.counterclockwise") }
                Divider()
                ForEach(ExportFormat.allCases) { f in
                    Button { vm.export(f) } label: { Label("Export \(f.label)", systemImage: "square.and.arrow.up") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 17)).frame(width: 38, height: 38).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 40)
        .background(Color.black)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let xform = ViewXform(canvas: geo.size, image: vm.imageSize, zoom: zoom, pan: pan)
            ZStack {
                Color.black
                CanvasView(model: vm.canvas, xform: xform)
                    .allowsHitTesting(false)
                if vm.imageSize != .zero {
                    gestureLayer(xform)
                    if tool == .masks { MaskOverlay(vm: vm, xform: xform) }
                }
                if vm.isLoading || vm.isExporting { ProgressView().tint(.white) }
                if vm.loadFailed { Text("This file couldn't be opened.").foregroundStyle(.secondary) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(alignment: .topLeading) {
                if showHistogram {
                    HistogramView(data: vm.histogram).frame(width: 96, height: 44).padding(8).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if vm.showOriginal {
                    Text("ORIGINAL").font(.caption2.bold()).padding(6)
                        .background(.ultraThinMaterial, in: Capsule()).padding(8)
                }
            }
        }
    }

    private var canNavigate: Bool { tool != .masks && tool != .crop }

    /// Pinch, pan, double-tap and press-to-compare on the photo itself.
    @ViewBuilder
    private func gestureLayer(_ xform: ViewXform) -> some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { resetZoom() } }
            .gesture(zoomGesture)
            .gesture(panGesture, including: (canNavigate && zoom > 1) ? .all : .none)
            .gesture(cropDrag(size: xform.rect.size), including: tool == .crop ? .all : .none)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35, maximumDistance: 30)
                    .onChanged { _ in if canNavigate { vm.showOriginal = true } }
                    .onEnded { _ in vm.showOriginal = false },
                including: canNavigate ? .all : .none)
    }

    private func resetZoom() {
        zoom = 1; lastZoom = 1; pan = .zero; lastPan = .zero
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in zoom = min(max(lastZoom * v.magnification, 1), 6) }
            .onEnded { _ in
                lastZoom = zoom
                if zoom <= 1 { pan = .zero; lastPan = .zero }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in pan = CGSize(width: lastPan.width + v.translation.width, height: lastPan.height + v.translation.height) }
            .onEnded { _ in lastPan = pan }
    }

    private func cropDrag(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                if cropStart == nil { cropStart = (vm.settings.cropX, vm.settings.cropY) }
                guard let start = cropStart, size.width > 0, size.height > 0 else { return }
                let k = 2 * max(1, vm.settings.cropZoom)
                vm.settings.cropX = min(max(start.0 - Double(v.translation.width / size.width) * k, -1), 1)
                vm.settings.cropY = min(max(start.1 + Double(v.translation.height / size.height) * k, -1), 1)
            }
            .onEnded { _ in cropStart = nil }
    }

    // MARK: Tools

    private var toolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Tool.allCases) { t in
                    Button { withAnimation(.easeOut(duration: 0.15)) { tool = (tool == t) ? nil : t } } label: {
                        VStack(spacing: 2) {
                            Image(systemName: t.icon).font(.system(size: 19))
                            Text(t.rawValue).font(.system(size: 10))
                        }
                        .frame(width: 62, height: 46)
                        .foregroundStyle(tool == t ? Theme.accent : Color(white: 0.6))
                    }
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 50)
        .background(Theme.bar)
    }

    @ViewBuilder
    private func panel(for t: Tool) -> some View {
        switch t {
        case .presets: PresetsPanel(vm: vm)
        case .crop: CropPanel(vm: vm)
        case .light: LightPanel(vm: vm)
        case .color: ColorPanel(vm: vm)
        case .mix: MixPanel(vm: vm)
        case .curve: CurvePanel(vm: vm)
        case .grade: GradePanel(vm: vm)
        case .effects: EffectsPanel(vm: vm)
        case .detail: DetailPanel(vm: vm)
        case .masks: MaskPanel(vm: vm)
        }
    }
}

struct ExportSheet: View {
    @ObservedObject var vm: EditorViewModel
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green)
                Text(url.lastPathComponent).font(.headline)
                Button {
                    Task { await vm.saveToPhotos(url); dismiss() }
                } label: { Label("Save to Photos", systemImage: "photo.badge.plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                ShareLink(item: url) {
                    Label("Share / Save to Files", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .navigationTitle("Exported")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
