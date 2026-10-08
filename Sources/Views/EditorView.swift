import SwiftUI

private enum Tool: String, CaseIterable, Identifiable {
    case presets = "Presets", crop = "Crop", light = "Light", color = "Color"
    case grade = "Grade", curve = "Curve", detail = "Detail", masks = "Masks"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .presets: return "wand.and.stars"
        case .crop: return "crop.rotate"
        case .light: return "sun.max"
        case .color: return "thermometer.medium"
        case .grade: return "circle.hexagongrid"
        case .curve: return "point.topleft.down.curvedto.point.bottomright.up"
        case .detail: return "triangle"
        case .masks: return "circle.dashed.inset.filled"
        }
    }
}

/// How tall the panel is and whether it shows every slider (list) or one at a time (strip).
private struct PanelPlan {
    var height: CGFloat
    var layout: SliderLayout
    var rowHeight: CGFloat = 40
}

struct EditorView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openItem) private var openItem
    @StateObject private var vm: EditorViewModel
    @AppStorage("showHistogram") private var showHistogram = true
    @AppStorage("sliderStyle") private var sliderStyle = "auto"   // auto | strip | list
    @State private var tool: Tool? = Tool(rawValue: DemoMode.value("-lumenDemoTool") ?? "") ?? .light
    @State private var chromeHidden = false

    // pinch-zoom / pan of the preview
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero

    private let item: LibraryItem
    private let toolbarHeight: CGFloat = 52

    init(item: LibraryItem) {
        self.item = item
        _vm = StateObject(wrappedValue: EditorViewModel(item: item))
    }

    var body: some View {
        GeometryReader { root in
            let plan = panelPlan(in: root.size)
            VStack(spacing: 0) {
                canvas
                if !chromeHidden {
                    VStack(spacing: 0) {
                        if let tool {
                            panelContainer(tool, plan: plan)
                        }
                        toolBar
                    }
                    .background(Theme.bar.ignoresSafeArea(edges: .bottom))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(Color.black.ignoresSafeArea())
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            vm.start(store: store)
            if DemoMode.isOn { applyDemo() }
        }
        .onDisappear { vm.flushSave(); store.refreshThumbnail(item) }
        .onChange(of: tool) { _, new in
            vm.maskEditing = (new == .masks)
            vm.cropEditing = (new == .crop)
            if new == .masks, vm.selectedMaskID == nil, let first = vm.settings.masks.first { vm.selectMask(first.id) }
            if new == .presets { vm.loadPresetThumbs(user: store.userPresets) }
            if new == .masks || new == .crop { resetZoom() }
        }
        .onChange(of: zoom) { _, z in vm.zoomChanged(z) }
        .sheet(item: $vm.exported) { result in ExportSheet(vm: vm, url: result.url) }
        .alert("Lumen", isPresented: Binding(get: { vm.message != nil },
                                             set: { if !$0 { vm.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(vm.message ?? "") }
    }

    // MARK: Layout planning

    /// The panel takes whatever vertical room the photo does not need. Sliders are shown as a full list when there
    /// is room for at least four whole rows, otherwise one at a time.
    private func panelPlan(in size: CGSize) -> PanelPlan {
        guard let tool else { return PanelPlan(height: 0, layout: .strip) }
        let aspect = vm.imageSize.height > 0 ? vm.imageSize.width / vm.imageSize.height : 1.5
        let avail = size.height - toolbarHeight
        let photoH = size.width / max(aspect, 0.2)
        let free = max(avail - photoH - 6, 0)
        let cap = avail * 0.6

        // Tools with a fixed layout: (compact, roomy)
        func fixed(_ compact: CGFloat, _ roomy: CGFloat) -> PanelPlan {
            let h = free > compact + 30 ? min(roomy, max(free, compact)) : compact
            return PanelPlan(height: h, layout: .strip)
        }
        // Slider lists: (rows, header height)
        func list(_ rows: Int, _ header: CGFloat) -> PanelPlan {
            let stripH: CGFloat = 100 + (header > 0 ? 0 : 0)
            let pad: CGFloat = 12
            let usable = sliderStyle == "list" ? cap : min(free, cap)
            let fit = Int((usable - header - pad) / 40)
            if sliderStyle == "strip" || fit < 4 { return PanelPlan(height: stripH, layout: .strip) }
            let n = min(rows, fit)
            let rowH: CGFloat = n == rows ? min(max((usable - header - pad) / CGFloat(rows), 40), 48) : 40
            return PanelPlan(height: header + CGFloat(n) * rowH + pad, layout: .list, rowHeight: rowH)
        }

        switch tool {
        case .presets: return fixed(112, 112)
        case .crop: return fixed(168, 184)
        case .grade: return fixed(250, 262)
        case .curve: return fixed(216, 236)
        case .light: return list(6, 44)
        case .color: return list(4, 44)
        case .detail: return list(14, 44)
        case .masks:
            if vm.settings.masks.isEmpty || vm.selectedMask == nil { return fixed(150, 176) }
            return vm.maskTab == .shape ? fixed(250, 330) : list(14, 40)
        }
    }

    private func panelContainer(_ t: Tool, plan: PanelPlan) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.25)).frame(width: 36, height: 4).padding(.top, 5).padding(.bottom, 3)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 8).onEnded { v in
                    if v.translation.height > 24 { withAnimation(.easeOut(duration: 0.18)) { tool = nil } }
                })
            panel(for: t)
                .environment(\.sliderLayout, plan.layout)
                .environment(\.listRowHeight, plan.rowHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: plan.height + 12)
        .background(Theme.panel, in: UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
    }

    /// CI-only: pre-build some edits so the screenshot shows the interesting panels.
    private func applyDemo() {
        if tool == .masks { vm.maskEditing = true }
        if let kind = DemoMode.value("-lumenDemoMask").flatMap({ MaskKind(rawValue: $0) }) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                vm.addMask(kind)
                if kind == .luminance { vm.updateComponent(vm.selectedComponent!.id) { $0.lumHigh = 0.4; $0.lumLow = 0.05 } }
                if DemoMode.value("-lumenDemoMaskTab") == "adjust" {
                    vm.updateMask(vm.selectedMask!.id) { $0.adjust.exposure = 1.0 }
                    vm.maskTab = .adjust
                }
            }
        }
        if DemoMode.value("-lumenDemoEdit") != nil {
            vm.settings.exposure = 0.3; vm.settings.contrast = 20; vm.settings.highlights = -30; vm.settings.vibrance = 25
            vm.settings.grading.shadows = GradeZone(hue: 215, sat: 55, lum: 0)
            vm.settings.grading.highlights = GradeZone(hue: 40, sat: 45, lum: 5)
        }
        if let z = DemoMode.value("-lumenDemoZoom").flatMap(Double.init) { zoom = CGFloat(z); lastZoom = zoom }
        if let r = DemoMode.value("-lumenDemoCrop").flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                vm.selectCropRatio(r)
            }
        }
        sliderStyle = DemoMode.value("-lumenDemoSlider") ?? "auto"
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
                    if tool == .crop { CropOverlay(vm: vm, xform: xform) }
                    if tool == .masks { MaskOverlay(vm: vm, xform: xform) }
                }
                if vm.isLoading || vm.isExporting { ProgressView().tint(.white) }
                if vm.detailLoading && zoom > 1.4 {
                    HStack(spacing: 6) { ProgressView().controlSize(.small).tint(.white); Text("Loading full resolution…").font(.caption) }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .top).padding(.top, 56)
                }
                if vm.loadFailed { Text("This file couldn't be opened.").foregroundStyle(.secondary) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(alignment: .top) { if !chromeHidden { floatingBar } }
            .overlay(alignment: .topLeading) {
                if showHistogram && !chromeHidden {
                    HistogramView(data: vm.histogram).frame(width: 90, height: 40).padding(.leading, 10).padding(.top, 50)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if vm.showOriginal {
                    Text("ORIGINAL").font(.caption2.bold()).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule()).padding(10)
                }
            }
        }
    }

    // MARK: Floating top buttons

    private var floatingBar: some View {
        HStack(spacing: 8) {
            FloatButton(system: "chevron.left") { dismiss() }
            Spacer()
            FloatButton(system: "arrow.uturn.backward", disabled: !vm.canUndo) { vm.undo() }
            FloatButton(system: "arrow.uturn.forward", disabled: !vm.canRedo) { vm.redo() }
            Image(systemName: "eye")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .background(Color.black.opacity(0.25), in: Circle())
                .foregroundStyle(vm.showOriginal ? Theme.accent : Color.white)
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 200, pressing: { vm.showOriginal = $0 }, perform: {})
            Menu {
                Toggle("Histogram", isOn: $showHistogram)
                Picker("Sliders", selection: $sliderStyle) {
                    Text("Automatic").tag("auto")
                    Text("One at a time").tag("strip")
                    Text("Full list").tag("list")
                }
                Button { go(-1) } label: { Label("Previous photo", systemImage: "chevron.left") }.disabled(neighbour(-1) == nil)
                Button { go(1) } label: { Label("Next photo", systemImage: "chevron.right") }.disabled(neighbour(1) == nil)
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
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Color.black.opacity(0.25), in: Circle())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 10).padding(.top, 6)
    }

    // MARK: Gestures

    private var canNavigate: Bool { tool != .masks && tool != .crop }

    /// Pinch, pan, double-tap, tap-to-hide-the-panels and press-to-compare on the photo itself.
    @ViewBuilder
    private func gestureLayer(_ xform: ViewXform) -> some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { resetZoom() } }
            .onTapGesture { if canNavigate { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } } }
            .gesture(zoomGesture)
            .gesture(panGesture, including: (canNavigate && zoom > 1) ? .all : .none)
            .simultaneousGesture(
                DragGesture(minimumDistance: 50).onEnded { v in
                    guard canNavigate, zoom <= 1.05, abs(v.translation.width) > 110, abs(v.translation.height) < 70 else { return }
                    go(v.translation.width < 0 ? 1 : -1)
                })
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35, maximumDistance: 30)
                    .onChanged { _ in if canNavigate { vm.showOriginal = true } }
                    .onEnded { _ in vm.showOriginal = false },
                including: canNavigate ? .all : .none)
    }

    /// The photo before/after this one in the library (rejected photos are skipped).
    private func neighbour(_ delta: Int) -> LibraryItem? {
        let items = store.items.filter { $0.flag != -1 || $0.id == item.id }
        guard let i = items.firstIndex(where: { $0.id == item.id }), items.indices.contains(i + delta) else { return nil }
        return items[i + delta]
    }

    private func go(_ delta: Int) {
        guard let n = neighbour(delta) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        vm.flushSave()
        openItem(n)
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

    // MARK: Tools

    /// Eight tools, all visible at once.
    private var toolBar: some View {
        HStack(spacing: 0) {
            ForEach(Tool.allCases) { t in
                Button { withAnimation(.easeOut(duration: 0.15)) { tool = (tool == t) ? nil : t } } label: {
                    VStack(spacing: 2) {
                        Image(systemName: t.icon).font(.system(size: 18))
                        Text(t.rawValue).font(.system(size: 9.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: toolbarHeight)
                    .foregroundStyle(tool == t ? Theme.accent : Color(white: 0.6))
                }
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func panel(for t: Tool) -> some View {
        switch t {
        case .presets: PresetsPanel(vm: vm)
        case .crop: CropPanel(vm: vm)
        case .light: LightPanel(vm: vm)
        case .color: ColorPanel(vm: vm)
        case .grade: GradePanel(vm: vm)
        case .curve: CurvePanel(vm: vm)
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
