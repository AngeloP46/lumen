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

/// What a tool needs: heights for the compact and roomy forms, and for slider tools the row count and header height.
private struct ToolSpec {
    var compact: CGFloat
    var roomy: CGFloat
    var rows = 0
    var header: CGFloat = 0
}

/// The panel as it will be drawn this frame.
private struct PanelPlan {
    var height: CGFloat
    var layout: SliderLayout
    var rowHeight: CGFloat = 40
    var minHeight: CGFloat = 100
    var maxHeight: CGFloat = 600
    var key = ""
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

    // panel height the user chose by dragging the handle (per tool); nil = automatic
    @State private var panelUser: [String: CGFloat] = [:]
    @State private var panelLive: CGFloat?
    @State private var panelDragStart: CGFloat?

    // pinch-zoom / pan of the preview
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var pinchBase: (zoom: CGFloat, pan: CGSize)?
    @State private var panBase: CGSize?
    @GestureState private var holding = false
    @State private var lastHoldEnd = Date.distantPast

    private let item: LibraryItem
    private let toolbarHeight: CGFloat = 52
    private let maxZoom: CGFloat = 8

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
            vm.panMode = false
            if new == .masks, vm.selectedMaskID == nil, let first = vm.settings.masks.first { vm.selectMask(first.id) }
            if new == .presets { vm.loadPresetThumbs(user: store.userPresets) }
            if new == .crop { resetZoom() }
        }
        .onChange(of: zoom) { _, z in vm.zoomChanged(z) }
        .onChange(of: holding) { _, h in
            vm.showOriginal = h
            if !h { lastHoldEnd = Date() }
        }
        .sheet(item: $vm.exported) { result in ExportSheet(vm: vm, url: result.url) }
        .alert("Lumen", isPresented: Binding(get: { vm.message != nil },
                                             set: { if !$0 { vm.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(vm.message ?? "") }
    }

    // MARK: Layout planning

    private func spec(_ t: Tool) -> ToolSpec {
        switch t {
        case .presets: return ToolSpec(compact: 112, roomy: 112)
        case .crop: return ToolSpec(compact: 168, roomy: 184)
        case .grade: return ToolSpec(compact: 250, roomy: 262)
        case .curve: return ToolSpec(compact: 216, roomy: 236)
        case .light: return ToolSpec(compact: 100, roomy: 0, rows: 6, header: 44)
        case .color: return ToolSpec(compact: 100, roomy: 0, rows: 4, header: 44)
        case .detail: return ToolSpec(compact: 100, roomy: 0, rows: 14, header: 44)
        case .masks:
            if vm.settings.masks.isEmpty || vm.selectedMask == nil { return ToolSpec(compact: 150, roomy: 176) }
            return vm.maskTab == .shape ? ToolSpec(compact: 250, roomy: 330)
                                        : ToolSpec(compact: 100, roomy: 0, rows: 14, header: 40)
        }
    }

    /// The panel takes whatever vertical room the photo does not need, unless the user dragged it to a height of their
    /// own. Sliders are shown as a full list when there is room for at least four whole rows, otherwise one at a time.
    private func panelPlan(in size: CGSize) -> PanelPlan {
        guard let tool else { return PanelPlan(height: 0, layout: .strip) }
        let sp = spec(tool)
        let aspect = vm.imageSize.height > 0 ? vm.imageSize.width / vm.imageSize.height : 1.5
        let avail = size.height - toolbarHeight
        let photoH = size.width / max(aspect, 0.2)
        let free = max(avail - photoH - 6, 0)
        let pad: CGFloat = 12

        var auto: CGFloat
        if sp.rows > 0 {
            let cap = avail * 0.6
            let usable = sliderStyle == "list" ? cap : min(free, cap)
            let fit = Int((usable - sp.header - pad) / 40)
            if sliderStyle == "strip" || fit < 4 {
                auto = sp.compact
            } else {
                let n = min(sp.rows, fit)
                let rowH: CGFloat = n == sp.rows ? min(max((usable - sp.header - pad) / CGFloat(sp.rows), 40), 48) : 40
                auto = sp.header + CGFloat(n) * rowH + pad
            }
        } else {
            auto = free > sp.compact + 30 ? min(sp.roomy, max(free, sp.compact)) : sp.compact
        }

        let key = tool.rawValue + (tool == .masks ? vm.maskTab.rawValue : "")
        let minH: CGFloat = sp.rows > 0 ? 100 : min(sp.compact, 120)
        let maxH = max(avail * 0.78, minH)
        let base = panelUser[key] ?? auto
        let h = min(max(panelLive ?? base, minH), maxH)

        var layout = SliderLayout.strip
        var rowH: CGFloat = 40
        if sp.rows > 0, sliderStyle != "strip", h >= sp.header + 4 * 40 + pad {
            layout = .list
            let all = sp.header + CGFloat(sp.rows) * 40 + pad
            rowH = h >= all ? min(max((h - sp.header - pad) / CGFloat(sp.rows), 40), 48) : 40
        }
        return PanelPlan(height: h, layout: layout, rowHeight: rowH, minHeight: minH, maxHeight: maxH, key: key)
    }

    private func panelContainer(_ t: Tool, plan: PanelPlan) -> some View {
        VStack(spacing: 0) {
            // grab handle: drag up for more of the controls, down for more of the photo (all the way down closes it)
            ZStack {
                Capsule().fill(Color.white.opacity(0.3)).frame(width: 44, height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("panel-handle")
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { v in
                        if panelDragStart == nil { panelDragStart = plan.height }
                        panelLive = (panelDragStart ?? plan.height) - v.translation.height
                    }
                    .onEnded { v in
                        let raw = (panelDragStart ?? plan.height) - v.translation.height
                        if raw < plan.minHeight - 45 {
                            withAnimation(.easeOut(duration: 0.18)) { tool = nil }
                        } else {
                            panelUser[plan.key] = min(max(raw, plan.minHeight), plan.maxHeight)
                        }
                        panelLive = nil
                        panelDragStart = nil
                    }
            )
            .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { panelUser[plan.key] = nil } }

            panel(for: t)
                .environment(\.sliderLayout, plan.layout)
                .environment(\.listRowHeight, plan.rowHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: plan.height + 24)
        .background(Theme.panel, in: UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel")
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
        if let z = DemoMode.value("-lumenDemoZoom").flatMap(Double.init) { zoom = CGFloat(z) }
        if let r = DemoMode.value("-lumenDemoCrop").flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                vm.selectCropRatio(r)
            }
        }
        if let h = DemoMode.value("-lumenDemoPanel").flatMap(Double.init), let t = tool {
            panelUser[t.rawValue + (t == .masks ? vm.maskTab.rawValue : "")] = CGFloat(h)
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
                    if tool == .masks { MaskOverlay(vm: vm, xform: xform).allowsHitTesting(!vm.panMode) }
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("canvas")
            // pinch works over every tool (including the mask and crop overlays), anchored on your fingers
            .simultaneousGesture(zoomGesture(xform), including: tool == .crop ? .none : .all)
            .overlay(alignment: .top) { if !chromeHidden { floatingBar } }
            .overlay(alignment: .topLeading) {
                if showHistogram && !chromeHidden {
                    HistogramView(data: vm.histogram).frame(width: 90, height: 40).padding(.leading, 10).padding(.top, 50)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if vm.showOriginal {
                    Text("ORIGINAL").accessibilityIdentifier("original-label").font(.caption2.bold()).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule()).padding(10)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: Floating top buttons

    private var floatingBar: some View {
        HStack(spacing: 8) {
            FloatButton(system: "chevron.left") { dismiss() }.accessibilityIdentifier("btn-back")
            Spacer()
            FloatButton(system: "arrow.uturn.backward", disabled: !vm.canUndo) { vm.undo() }.accessibilityIdentifier("btn-undo")
            FloatButton(system: "arrow.uturn.forward", disabled: !vm.canRedo) { vm.redo() }.accessibilityIdentifier("btn-redo")
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
    private var canPan: Bool { canNavigate || (tool == .masks && vm.panMode) }

    /// Tap = hide/show the panels, double-tap = zoom to that spot (or back), press and hold = see the original until
    /// you let go, drag = pan when zoomed, swipe sideways = next/previous photo.
    @ViewBuilder
    private func gestureLayer(_ xform: ViewXform) -> some View {
        Color.clear.contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("photo")
            .accessibilityLabel(item.displayName)
            .accessibilityValue("zoom \(String(format: "%.1f", Double(zoom))) original \(vm.showOriginal) chrome \(chromeHidden ? "hidden" : "shown")")
            .gesture(
                SpatialTapGesture(count: 2)
                    .exclusively(before: TapGesture(count: 1))
                    .onEnded { value in
                        switch value {
                        case .first(let tap): toggleZoom(at: tap.location, xform)
                        case .second: if canNavigate { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }
                        }
                    },
                including: tool == .crop ? .none : .all)
            .gesture(panGesture(xform), including: (canPan && zoom > 1.01) ? .all : .none)
            .simultaneousGesture(
                DragGesture(minimumDistance: 50).onEnded { v in
                    guard canNavigate, zoom <= 1.05, Date().timeIntervalSince(lastHoldEnd) > 0.5,
                          abs(v.translation.width) > 110, abs(v.translation.height) < 70 else { return }
                    go(v.translation.width < 0 ? 1 : -1)
                })
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.3, maximumDistance: 25)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($holding) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    },
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
        zoom = 1; pan = .zero; pinchBase = nil; panBase = nil
    }

    /// Keeps the photo from being dragged away: it can only move as far as its edges reach the edges of the view.
    private func clampPan(_ p: CGSize, zoom z: CGFloat, _ xf: ViewXform) -> CGSize {
        guard z > 1.001, xf.image.width > 0, xf.image.height > 0 else { return .zero }
        let fit = min(xf.canvas.width / xf.image.width, xf.canvas.height / xf.image.height)
        let w = xf.image.width * fit * z, h = xf.image.height * fit * z
        let mx = max((w - xf.canvas.width) / 2, 0), my = max((h - xf.canvas.height) / 2, 0)
        return CGSize(width: min(max(p.width, -mx), mx), height: min(max(p.height, -my), my))
    }

    /// Zooms to `z` keeping the image point under `anchor` where it was.
    private func setZoom(_ z: CGFloat, anchor: CGPoint, from base: (zoom: CGFloat, pan: CGSize), _ xf: ViewXform) {
        let nz = min(max(z, 1), maxZoom)
        let c = CGPoint(x: xf.canvas.width / 2, y: xf.canvas.height / 2)
        let ratio = nz / base.zoom
        let dx = anchor.x - c.x, dy = anchor.y - c.y
        let p = CGSize(width: dx - (dx - base.pan.width) * ratio, height: dy - (dy - base.pan.height) * ratio)
        zoom = nz
        pan = clampPan(p, zoom: nz, xf)
    }

    private func toggleZoom(at p: CGPoint, _ xf: ViewXform) {
        withAnimation(.easeInOut(duration: 0.22)) {
            if zoom > 1.05 { resetZoom() } else { setZoom(3, anchor: p, from: (1, .zero), xf) }
        }
    }

    private func zoomGesture(_ xf: ViewXform) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchBase == nil {
                    pinchBase = (zoom, pan)
                    if tool == .masks { vm.cancelRecentStroke() }   // the first finger of a pinch must not leave a brush dab
                }
                if let b = pinchBase { setZoom(b.zoom * v.magnification, anchor: v.startLocation, from: b, xf) }
            }
            .onEnded { _ in
                pinchBase = nil
                if zoom < 1.02 { withAnimation(.easeOut(duration: 0.15)) { resetZoom() } }
            }
    }

    private func panGesture(_ xf: ViewXform) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                if panBase == nil { panBase = pan }
                if let b = panBase {
                    pan = clampPan(CGSize(width: b.width + v.translation.width, height: b.height + v.translation.height),
                                   zoom: zoom, xf)
                }
            }
            .onEnded { _ in panBase = nil }
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
                .accessibilityIdentifier("tool-\(t.rawValue)")
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
