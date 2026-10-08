import SwiftUI

private enum Tool: String, CaseIterable, Identifiable {
    case presets = "Presets", crop = "Crop", light = "Light", color = "Color", mix = "Mix"
    case curve = "Curve", grade = "Grading", effects = "Effects", detail = "Detail", masks = "Masks"
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
            canvas
            if let tool {
                ScrollView { panel(for: tool).padding(.horizontal, 16).padding(.vertical, 8) }
                    .frame(height: 270)
                    .background(Color(white: 0.07))
            }
            toolStrip
        }
        .background(Color.black)
        .navigationTitle(item.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear { vm.start(store: store) }
        .onDisappear { store.refreshThumbnail(item) }
        .onChange(of: tool) { _, new in
            vm.maskEditing = (new == .masks)
            if new == .masks, vm.selectedMaskID == nil { vm.selectedMaskID = vm.settings.masks.first?.id }
            if new == .presets { vm.loadPresetThumbs(user: store.userPresets) }
            if new == .masks || new == .crop { resetZoom() }
        }
        .sheet(item: $vm.exported) { result in ExportSheet(vm: vm, url: result.url) }
        .alert("Lumen", isPresented: Binding(get: { vm.message != nil },
                                             set: { if !$0 { vm.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(vm.message ?? "") }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = vm.preview {
                    let size = fit(img.size, in: geo.size)
                    ZStack {
                        Image(uiImage: img).resizable().frame(width: size.width, height: size.height)
                        if tool == .masks, !vm.showOriginal {
                            MaskOverlay(vm: vm, size: size)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(zoom)
                    .offset(pan)
                    .onTapGesture(count: 2) { resetZoom() }
                    .gesture(zoomGesture, including: canNavigate ? .all : .none)
                    .gesture(panGesture, including: (canNavigate && zoom > 1) ? .all : .none)
                    .gesture(cropDrag(size: size), including: tool == .crop ? .all : .none)
                }
                if vm.isLoading || vm.isExporting { ProgressView().tint(.white) }
                if vm.loadFailed { Text("This file couldn't be opened.").foregroundStyle(.secondary) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(alignment: .topLeading) {
                if showHistogram {
                    HistogramView(data: vm.histogram).frame(width: 110, height: 52).padding(8).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if vm.showOriginal {
                    Text("ORIGINAL").font(.caption2.bold()).padding(6)
                        .background(.ultraThinMaterial, in: Capsule()).padding(8)
                }
            }
            .overlay(alignment: .bottom) { ratingBar.padding(.bottom, 6) }
        }
    }

    private var canNavigate: Bool { tool != .masks && tool != .crop }

    private func fit(_ img: CGSize, in box: CGSize) -> CGSize {
        guard img.width > 0, img.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let s = min(box.width / img.width, box.height / img.height)
        return CGSize(width: img.width * s, height: img.height * s)
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
                guard let start = cropStart else { return }
                let k = 2 * max(1, vm.settings.cropZoom)
                vm.settings.cropX = min(max(start.0 - Double(v.translation.width / size.width) * k, -1), 1)
                vm.settings.cropY = min(max(start.1 + Double(v.translation.height / size.height) * k, -1), 1)
            }
            .onEnded { _ in cropStart = nil }
    }

    private var ratingBar: some View {
        let current = store.item(item.id) ?? item
        return HStack(spacing: 14) {
            Button { store.setFlag(current, -1) } label: {
                Image(systemName: current.flag == -1 ? "flag.fill" : "flag").foregroundStyle(current.flag == -1 ? .red : .white)
            }
            ForEach(1...5, id: \.self) { n in
                Button { store.setRating(current, n) } label: {
                    Image(systemName: n <= current.rating ? "star.fill" : "star")
                        .foregroundStyle(n <= current.rating ? .yellow : .white)
                }
            }
            Button { store.setFlag(current, 1) } label: {
                Image(systemName: current.flag == 1 ? "flag.fill" : "flag").foregroundStyle(current.flag == 1 ? .green : .white)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { vm.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!vm.canUndo)
            Button { vm.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!vm.canRedo)
            Image(systemName: "eye")
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 200, pressing: { vm.showOriginal = $0 }, perform: {})
            Menu {
                Toggle("Histogram", isOn: $showHistogram)
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
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    // MARK: Panels

    private var toolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Tool.allCases) { t in
                    Button { tool = (tool == t) ? nil : t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icon).font(.title3)
                            Text(t.rawValue).font(.caption2)
                        }
                        .frame(width: 66, height: 48)
                        .foregroundStyle(tool == t ? Color.accentColor : Color.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
        .background(Color(white: 0.1))
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
