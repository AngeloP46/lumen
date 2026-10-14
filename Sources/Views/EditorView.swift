import SwiftUI

private enum Tool: String, CaseIterable, Identifiable {
    // tool bar order, left to right; Presets is last (least used)
    case crop = "Crop", light = "Light", color = "Color", grade = "Grade"
    case curve = "Curve", detail = "Detail", masks = "Masks", heal = "Heal", presets = "Presets"
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
        case .heal: return "bandage"
        }
    }
    /// The part of the edit this tool owns (Presets owns none).
    var section: EditSection? { EditSection(rawValue: rawValue) }
}

/// What a tool needs: heights for the compact and roomy forms, and for slider tools the row count and header height.
private struct ToolSpec {
    var compact: CGFloat
    var roomy: CGFloat
    var rows = 0
    var header: CGFloat = 0
    /// Extra height of the section headings inside a full list (not needed to show a scrolling list).
    var sections: CGFloat = 0
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
    /// Portrait: the tool bar can be folded down to a thin strip (owner's request 2026-10-11: tools are switched now and
    /// then, not every second, so the full bar is not worth its height all the time).
    @AppStorage("toolBarCollapsed") private var toolsCollapsed = false
    /// Wide screen (phone on its side): photo on the left at full height, controls in a column on the right.
    @State private var landscape = false
    @State private var tool: Tool? = Tool(rawValue: DemoMode.value("-lumenDemoTool") ?? "") ?? .light
    @State private var chromeHidden = false
    @State private var showExportChoices = false
    // DRAFT — sandbox: App Store export gate (plan §4.1). Flag-off builds never see this.
#if APP_STORE
    @State private var showProPaywall = false
    @ObservedObject private var proStore = LumenStore.shared
    @Environment(\.scenePhase) private var scenePhase
#endif
    @State private var showEdits = false
    @State private var showPasteSome = false
    @State private var wbMark: CGPoint?

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
    // reset by SwiftUI when a pan or pinch ends *or is cancelled by the system* (onEnded is not called then)
    @GestureState private var panTouching = false
    @GestureState private var pinchTouching = false
    @State private var lastHoldEnd = Date.distantPast
    // two-finger pinch/pan (TwoFingerWatcher): where it started, and whether fingers are on the photo right now
    @State private var twoFinger: (zoom: CGFloat, pan: CGSize, centre: CGPoint, spread: CGFloat)?
    @State private var lastPinchEnd = Date.distantPast

    private let item: LibraryItem
    private let toolbarHeight: CGFloat = 52
    private let collapsedBarHeight: CGFloat = 30
    private let landscapeBarHeight: CGFloat = 44
    private var portraitBarHeight: CGFloat { toolsCollapsed ? collapsedBarHeight : toolbarHeight }
    private let maxZoom: CGFloat = 8

    init(item: LibraryItem) {
        self.item = item
        _vm = StateObject(wrappedValue: EditorViewModel(item: item))
    }

    var body: some View {
        GeometryReader { root in
            let wide = root.size.width > root.size.height * 1.1
            Group {
                if wide {
                    // phone on its side: the photo keeps the full height, the controls live in a column on the right
                    let sideW = min(400, max(300, root.size.width * 0.4))
                    HStack(spacing: 0) {
                        canvas
                        if !chromeHidden {
                            VStack(spacing: 0) {
                                if let tool {
                                    panelContainer(tool, plan: sidePlan(height: root.size.height - landscapeBarHeight - 24))
                                } else {
                                    Spacer(minLength: 0)
                                }
                                toolBar(compact: true)
                            }
                            .frame(width: sideW)
                            .background(Theme.bar.ignoresSafeArea(edges: [.bottom, .trailing]))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                } else {
                    let plan = panelPlan(in: root.size)
                    VStack(spacing: 0) {
                        canvas
                        if !chromeHidden {
                            VStack(spacing: 0) {
                                if let tool {
                                    panelContainer(tool, plan: plan)
                                }
                                if toolsCollapsed { collapsedToolBar } else { toolBar(compact: false) }
                            }
                            .background(Theme.bar.ignoresSafeArea(edges: .bottom))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .onChange(of: wide, initial: true) { _, w in landscape = w }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            vm.start(store: store)
            if DemoMode.isOn { applyDemo() }
        }
        .onDisappear { vm.flushSave(); store.refreshThumbnail(item) }
        .onChange(of: tool) { _, new in
            vm.wbPicking = false
            wbMark = nil
            vm.maskEditing = (new == .masks)
            vm.cropEditing = (new == .crop)
            vm.panMode = false
            if new == .masks, vm.selectedMaskID == nil, let first = vm.settings.masks.first { vm.selectMask(first.id) }
            if new == .presets { vm.loadPresetThumbs(user: store.userPresets) }
            if new != .heal { vm.selectedHealID = nil; vm.healMessage = nil; vm.cancelPeople() }
            if new == .crop || (new != .masks && zoom < 0.999) { withAnimation(.easeOut(duration: 0.18)) { resetZoom() } }
        }
        .onChange(of: zoom) { _, z in vm.zoomChanged(z) }
        .onChange(of: panTouching) { _, down in if !down { panBase = nil } }
        .onChange(of: pinchTouching) { _, down in
            guard !down else { return }
            DispatchQueue.main.async {   // after onEnded, if there is one
                if pinchBase != nil { pinchBase = nil; withAnimation(.easeOut(duration: 0.18)) { if zoom < minZoom { resetZoom() } } }
            }
        }
        .onChange(of: holding) { _, h in
            // a hold that started on the brush painted a dab first: take it back
            if h && tool == .masks { vm.cancelRecentStroke() }
            vm.showOriginal = h && twoFinger == nil
            if !h { lastHoldEnd = Date() }
        }
        .sheet(isPresented: $showExportChoices) {
            ExportOptionsSheet(count: 1, hdrAvailable: vm.settings.hdr) { options in
#if APP_STORE
                Task {
                    await proStore.refreshStatus()
                    if vm.settings.usesProFeatures && !proStore.isPro {
                        showExportChoices = false
                        showProPaywall = true
                    } else { vm.export(options) }
                }
#else
                vm.export(options)
#endif
            }
        }
        // DRAFT — sandbox: paywall sheet for the export gate (App Store builds only)
#if APP_STORE
        .sheet(isPresented: $showProPaywall) {
            PaywallView(store: proStore)
        }
        .task { await proStore.refreshStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await proStore.refreshStatus() } }
        }
#endif
        .sheet(item: $vm.exported) { result in ExportSheet(vm: vm, url: result.url) }
        .sheet(isPresented: $showEdits) { EditsSheet(vm: vm) }
        .sheet(isPresented: $showPasteSome) {
            if let c = store.clipboard { PasteSomeSheet(clip: c) { vm.paste($0, from: c) } }
        }
        .onChange(of: vm.wbPicking) { _, on in if !on { wbMark = nil } }
        .alert("Lumen", isPresented: Binding(get: { vm.message != nil },
                                             set: { if !$0 { vm.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(vm.message ?? "") }
    }

    // MARK: Layout planning

    private func spec(_ t: Tool) -> ToolSpec {
        switch t {
        case .presets: return ToolSpec(compact: vm.presetStrengthAvailable ? 152 : 112, roomy: vm.presetStrengthAvailable ? 152 : 112)
        case .crop: return ToolSpec(compact: 200, roomy: 240)
        case .heal: return ToolSpec(compact: 150, roomy: 150)
        case .grade: return ToolSpec(compact: 250, roomy: 262)
        case .curve: return ToolSpec(compact: 280, roomy: 340)   // the curve fills its panel: bigger is easier
        case .light: return ToolSpec(compact: 100, roomy: 0, rows: 6, header: 44)
        case .color:
            // the colour mixer has a row of swatches above its three sliders
            return vm.colorMix ? ToolSpec(compact: 150, roomy: 0, rows: 3, header: 44 + 46)
                               : ToolSpec(compact: 100, roomy: 0, rows: 4, header: 44, sections: 2 * 30)
        case .detail: return ToolSpec(compact: 100, roomy: 0, rows: 14, header: 8, sections: 5 * 30)
        case .masks:
            if vm.settings.masks.isEmpty || vm.selectedMask == nil { return ToolSpec(compact: 166, roomy: 176) }
            // header rows (mask chips + Shape/Adjust tabs) sit above the sliders; Reset rides on the first heading
            return vm.maskTab == .shape ? ToolSpec(compact: 250, roomy: 330)
                                        : ToolSpec(compact: 190, roomy: 0, rows: 14, header: 82, sections: 4 * 30)
        }
    }

    /// The everyday tools (everything but Crop and the mask Shape tab) share one panel height whenever the photo
    /// leaves room for it, so switching between them never moves or resizes the photo.
    private func sharesHeight(_ t: Tool) -> Bool {
        switch t {
        case .crop, .heal: return false
        case .masks: return vm.selectedMask != nil && vm.maskTab == .adjust
        default: return true
        }
    }

    /// The panel takes whatever vertical room the photo does not need, unless the user dragged it to a height of their
    /// own. Sliders are shown as a full list when there is room for at least four whole rows, otherwise one at a time.
    private func panelPlan(in size: CGSize) -> PanelPlan {
        guard let tool else { return PanelPlan(height: 0, layout: .strip) }
        let sp = spec(tool)
        let aspect = vm.imageSize.height > 0 ? vm.imageSize.width / vm.imageSize.height : 1.5
        let avail = size.height - portraitBarHeight
        let photoH = size.width / max(aspect, 0.2)
        let free = max(avail - photoH - 6, 0)
        let pad: CGFloat = 12
        let shared = sliderStyle == "list" ? avail * 0.6 : min(free, avail * 0.6, 400)
        let useShared = sharesHeight(tool) && sliderStyle != "strip" && shared >= 260

        var auto: CGFloat
        if useShared {
            auto = shared
        } else if sp.rows > 0 {
            let cap = avail * 0.6
            let usable = sliderStyle == "list" ? cap : min(free, cap)
            let head = sp.header + sp.sections
            let fit = Int((usable - head - pad) / 40)
            if sliderStyle == "strip" || usable < listMin(sp, pad) {
                auto = sp.compact
            } else if fit >= sp.rows {
                let rowH = min(max((usable - head - pad) / CGFloat(sp.rows), 40), 48)
                auto = head + CGFloat(sp.rows) * rowH + pad
            } else {
                auto = usable   // a scrolling list that uses the room the photo leaves
            }
        } else {
            auto = free > sp.compact + 30 ? min(sp.roomy, max(free, sp.compact)) : sp.compact
        }

        let key = useShared ? "shared" : tool.rawValue + (tool == .masks ? vm.maskTab.rawValue : "")
        let minH: CGFloat = sp.rows > 0 ? sp.compact : min(sp.compact, 120)
        let maxH = max(avail * 0.78, minH)
        let base = panelUser[key] ?? auto
        var h = min(max(panelLive ?? base, minH), maxH)

        var layout = SliderLayout.strip
        var rowH: CGFloat = 40
        if sp.rows > 0, sliderStyle != "strip", h >= listMin(sp, pad) {
            layout = .list
            let head = sp.header + sp.sections
            let all = head + CGFloat(sp.rows) * 40 + pad
            rowH = h >= all ? min(max((h - head - pad) / CGFloat(sp.rows), 40), 54) : 40
        }
        // One slider at a time needs only its own row: the panel hugs it and the photo gets the rest of the screen.
        // While the finger is on the grab handle the panel follows it, so it can still be pulled up into the list.
        if sp.rows > 0, layout == .strip, panelLive == nil { h = sp.compact }
        return PanelPlan(height: h, layout: layout, rowHeight: rowH, minHeight: minH, maxHeight: maxH, key: key)
    }

    /// The smallest height that shows a useful list: the header, one section heading and four rows (it scrolls).
    private func listMin(_ sp: ToolSpec, _ pad: CGFloat) -> CGFloat {
        sp.header + (sp.sections > 0 ? 30 : 0) + CGFloat(min(4, sp.rows)) * 40 + pad
    }

    /// Landscape: the side column's panel uses all of the column's height; sliders as a list.
    private func sidePlan(height: CGFloat) -> PanelPlan {
        guard let tool else { return PanelPlan(height: 0, layout: .strip) }
        let sp = spec(tool)
        let h = max(height, 120)
        let layout: SliderLayout = (sp.rows > 0 && sliderStyle != "strip") ? .list : .strip
        return PanelPlan(height: h, layout: layout, rowHeight: 40, minHeight: h, maxHeight: h, key: "landscape")
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
                        // a release short of the list settles back onto the single slider row, smoothly
                        withAnimation(.easeOut(duration: 0.18)) { panelLive = nil }
                        panelDragStart = nil
                    }
            )
            .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { panelUser[plan.key] = nil } }

            if let sec = t.section, !vm.settings.isOn(sec) {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash").font(.system(size: 12))
                    Text("\(sec.rawValue) is switched off").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("Turn on") { vm.settings.setOn(sec, true) }
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityIdentifier("section-turn-on")
                }
                .foregroundStyle(Color(white: 0.8))
                .padding(.horizontal, 14).frame(height: 30)
                .background(Color.orange.opacity(0.18))
            }
            panel(for: t)
                .environment(\.sliderLayout, plan.layout)
                .environment(\.listRowHeight, plan.rowHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: plan.height + 24)
        .clipped()   // nothing may ever spill over the tool bar
        // fold the tool bar away for more photo (tap the thin strip to bring it back). Laid over the grab row rather
        // than inside it: the grab row's own drag and double-tap would swallow the tap.
        .overlay(alignment: .topTrailing) {
            if !landscape && !toolsCollapsed {
                Button { withAnimation(.easeOut(duration: 0.18)) { toolsCollapsed = true } } label: {
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(white: 0.6))
                        .frame(width: 48, height: 24).contentShape(Rectangle())
                }
                .padding(.trailing, 4)
                .accessibilityIdentifier("tools-collapse")
                .accessibilityLabel("Hide tools")
            }
        }
        .background(Theme.panel, in: UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel")
    }

    /// CI-only: pre-build some edits so the screenshot shows the interesting panels.
    private func applyDemo() {
        // opening straight into a tool skips onChange(of: tool), which normally switches these modes on
        if tool == .masks { vm.maskEditing = true }
        if tool == .crop { vm.cropEditing = true }
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
        if DemoMode.value("-lumenDemoMix") != nil { vm.colorMix = true }
        // DRAFT — sandbox (CI screenshots): put non-zero Pro values into the demo edits so the
        // watermark and export gate are exercised without touching any real photo.
#if APP_STORE
        if DemoMode.proEdits { vm.settings.sharpness = 40; vm.settings.texture = 25 }
#endif
        if let z = DemoMode.value("-lumenDemoZoom").flatMap(Double.init) { zoom = CGFloat(z) }
        if let r = DemoMode.value("-lumenDemoCrop").flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                vm.selectCropRatio(r)
            }
        }
        if let h = DemoMode.value("-lumenDemoPanel").flatMap(Double.init), let t = tool {
            panelUser[t.rawValue + (t == .masks ? vm.maskTab.rawValue : "")] = CGFloat(h)
            panelUser["shared"] = CGFloat(h)
        }
        sliderStyle = DemoMode.value("-lumenDemoSlider") ?? "auto"
        // DRAFT — sandbox (CI screenshots): pre-build the interesting state per tool so each App Store
        // screenshot shows a real edit, not a neutral photo. Nothing here runs in normal use.
#if APP_STORE
        if DemoMode.value("-lumenDemoCurve") != nil {
            vm.settings.curves.set(0, [CurvePoint(x: 0, y: 0.06), CurvePoint(x: 0.3, y: 0.27),
                                       CurvePoint(x: 0.7, y: 0.74), CurvePoint(x: 1, y: 0.96)])
        }
        if DemoMode.value("-lumenDemoGrade") != nil {
            vm.settings.grading.shadows = GradeZone(hue: 210, sat: 48, lum: -6)
            vm.settings.grading.midtones = GradeZone(hue: 45, sat: 38, lum: 4)
            vm.settings.grading.highlights = GradeZone(hue: 25, sat: 42, lum: 8)
        }
        if DemoMode.value("-lumenDemoDetail2") != nil {
            vm.settings.sharpness = 45; vm.settings.texture = 30; vm.settings.clarity = 18
            vm.settings.vignette = -18; vm.settings.grain = 10
        }
        if DemoMode.value("-lumenDemoExport") != nil {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                showExportChoices = true
            }
        }
        if tool == .heal && DemoMode.value("-lumenDemoPeople") != nil {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                vm.findPeople()
            }
        }
        if DemoMode.paywall {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                showProPaywall = true
            }
        }
#endif
    }

    // MARK: Canvas

    /// The photo sits directly on top of the panel (spare height above it, under the floating buttons and the
    /// histogram) and grows upwards into that space when zoomed. Masks and Crop keep it centred, so handles and the crop
    /// frame have room all round.
    private var alignBottom: Bool { !chromeHidden && !landscape && tool != .masks && tool != .crop }

    private var canvas: some View {
        photoArea
        .overlay(alignment: .top) { if !chromeHidden { floatingBar } }
        .overlay(alignment: .topLeading) {
            if showHistogram && !chromeHidden {
                VStack(alignment: .leading, spacing: 3) {
                    // not a button: it sits over the photo, where a press and hold must still show the original.
                    // The clipping warning is in More → View.
                    // Photomator-sized (owner, 2026-10-11; was 90 x 40): More → Histogram hides it
                    HistogramView(data: vm.histogram).frame(width: vm.settings.hdr ? 190 : 156, height: 76)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(vm.clipWarning ? Theme.accent : Color.clear, lineWidth: 1.5))
                        .accessibilityIdentifier("histogram")
                        .accessibilityValue(vm.clipWarning ? "clipping on" : "clipping off")
                    // RAW or not: a JPEG has no hidden highlight detail for Highlights or HDR to bring back
                    Text(vm.fileKind).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.white.opacity(0.75))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.35), in: Capsule())
                        .accessibilityIdentifier("file-kind")
                }
                .padding(.leading, 10).padding(.top, 50)
                .allowsHitTesting(false)
            }
        }
    }

    // DRAFT — sandbox: the export gate (plan §4.1). Free users with a Pro feature active
    // see the paywall instead of the export options; everyone else is unchanged.
    private func requestExport() {
#if APP_STORE
        Task {
            await proStore.refreshStatus()
            if vm.settings.usesProFeatures && !proStore.isPro {
                showProPaywall = true
            } else { showExportChoices = true }
        }
#else
        showExportChoices = true
#endif
    }

    private var photoArea: some View {
        GeometryReader { geo in
            let xform = ViewXform(canvas: geo.size, image: vm.imageSize, zoom: zoom, pan: pan, bottomAlign: alignBottom)
            let origin = geo.frame(in: .global).origin
            ZStack {
                Color.black
                CanvasView(model: vm.canvas, xform: xform, hdr: vm.settings.hdr)
                    .allowsHitTesting(false)
                // DRAFT — sandbox: watermark on Pro-edited previews for free users (plan §5.1).
                // A tiled diagonal pattern (the classic "SAMPLE" protection look, 14 Oct) stretched
                // over the photo's own frame, so it moves with the picture under pinch/pan and is
                // clipped to the photo, not the screen.
#if APP_STORE
                if vm.settings.usesProFeatures && !proStore.isPro && !DemoMode.noWM {
                    let wmXform = ViewXform(canvas: geo.size, image: vm.imageSize, zoom: zoom, pan: pan, bottomAlign: alignBottom)
                    let r = wmXform.rect
                    LumaforgeMark()
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.midX - geo.size.width / 2, y: r.midY - geo.size.height / 2)
                        .clipped()
                }
#endif
                if vm.imageSize != .zero {
                    gestureLayer(xform)
                    if tool == .crop { CropOverlay(vm: vm, xform: xform) }
                    if tool == .masks {
                        MaskOverlay(vm: vm, xform: xform, geo: SourceGeometry(source: vm.sourceSize, settings: vm.settings))
                            .allowsHitTesting(!vm.panMode)
                            // hidden (not removed, so a drag in progress survives) while the original is showing
                            .opacity(vm.showOriginal ? 0 : 1)
                    }
                    if tool == .heal {
                        HealOverlay(vm: vm, xform: xform, geo: SourceGeometry(source: vm.sourceSize, settings: vm.settings))
                            .opacity(vm.showOriginal ? 0 : 1)
                    }
                    if tool == .color && vm.wbPicking && !vm.colorMix { wbLayer(xform) }
                    if vm.splitCompare && !vm.showOriginal && tool != .crop { splitLayer(xform) }
                }
                if vm.isLoading || vm.isExporting { ProgressView().tint(.white) }
                if vm.detailLoading && zoom > 1.4 {
                    HStack(spacing: 6) { ProgressView().controlSize(.small).tint(.white); Text("Loading full resolution…").font(.caption) }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .top).padding(.top, 156)   // below the histogram
                }
                if vm.loadFailed { Text("This file couldn't be opened.").foregroundStyle(.secondary) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            // the view or the photo's shape can change while zoomed (panel opened, Masks tool left): keep the pan in bounds
            .onChange(of: xform) { _, xf in
                let p = clampPan(pan, zoom: zoom, xf)
                if p != pan { pan = p }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("canvas")
            // two fingers pinch and pan together over every tool except Crop (including the mask overlay)
            .background(TwoFingerInstaller(enabled: !showEdits && !showPasteSome && !showExportChoices && vm.exported == nil) { phase, p, d in
                twoFingers(phase, CGPoint(x: p.x - origin.x, y: p.y - origin.y), d, xform)
            })
            // fallback pinch in case the watcher above never sees the fingers
            .simultaneousGesture(zoomGesture(xform), including: tool == .crop ? .none : .all)
            // press and hold = the original, in every tool but Crop and the mask Shape tab (there a finger places the
            // mask: handles, brush, picks, and a pause before dragging used to flick to the original)
            .simultaneousGesture(holdGesture, including: canCompare ? .all : .none)
            .overlay(alignment: .bottomLeading) {
                if vm.settings.hdr && !chromeHidden && tool != .crop {
                    Text(vm.hdrBadge).accessibilityIdentifier("hdr-badge").font(.caption2.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule()).padding(10)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if tool == .color && vm.wbPicking && !vm.colorMix && !vm.showOriginal {
                    Text("Tap something that should be white or grey").font(.caption2.bold())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule()).padding(8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if vm.clipWarning && !chromeHidden {
                    Button { vm.clipWarning = false } label: {
                        HStack(spacing: 4) {
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                            Circle().fill(Color.blue).frame(width: 7, height: 7)
                            Text("Clipping").font(.caption2.bold())
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .accessibilityIdentifier("clip-badge")
                }
            }
            .overlay {
                // an automatic mask is still being worked out: say so on the photo (a tap must never look ignored)
                if tool == .masks, !chromeHidden, let busy = vm.aiPending(vm.selectedMask) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text(busy).font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mask-busy")
                }
            }
            .overlay(alignment: .bottom) {
                // the AI found nothing for the selected mask: say so on the photo too
                if tool == .masks, !chromeHidden, let m = vm.selectedMask, let why = vm.emptyReason(m) {
                    Label(why, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 12)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("mask-empty-photo")
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

    /// Before / after: a line across the photo, original on the left; drag it, or tap × to finish.
    private func splitLayer(_ xform: ViewXform) -> some View {
        let r = xform.rect
        let x = r.minX + r.width * vm.splitPos
        let top = max(r.minY, 0), bottom = min(r.maxY, xform.canvas.height)
        return ZStack {
            Rectangle().fill(Color.white).frame(width: 2, height: max(bottom - top, 0))
                .position(x: x, y: (top + bottom) / 2)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .allowsHitTesting(false)
            HStack(spacing: 0) {
                Text("BEFORE").padding(.trailing, 10)
                Text("AFTER").padding(.leading, 10)
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black, radius: 2)
            .position(x: x, y: max(top + 16, 16))
            .allowsHitTesting(false)
            // the handle: drag sideways to move the line
            Circle().fill(Color.white).frame(width: 30, height: 30)
                .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.black))
                .shadow(color: .black.opacity(0.5), radius: 2)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("split-handle")
                .accessibilityValue(String(format: "%.2f", Double(vm.splitPos)))
                .position(x: x, y: (top + bottom) / 2)
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    guard r.width > 0 else { return }
                    vm.splitPos = min(max((g.location.x - r.minX) / r.width, 0.02), 0.98)
                })
            Button { vm.splitCompare = false } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26).background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.white)
            .accessibilityIdentifier("split-close")
            .position(x: x, y: max(min(bottom - 22, xform.canvas.height - 22), top + 40))
        }
        .frame(width: xform.canvas.width, height: xform.canvas.height)
    }

    /// Color tool, white balance picker on: a tap on the photo makes that spot neutral.
    private func wbLayer(_ xform: ViewXform) -> some View {
        let sg = SourceGeometry(source: vm.sourceSize, settings: vm.settings)
        return ZStack {
            Color.clear.contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { v in
                    guard xform.rect.contains(v.location) else { return }
                    let p = sg.toSource(xform.unclamped(v.location, limit: -10...10))
                    vm.pickWhiteBalance(at: Pt(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)))
                    wbMark = v.location
                })
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("wb-layer")
            if let m = wbMark {
                Circle().stroke(Color.white, lineWidth: 2).frame(width: 30, height: 30)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1).frame(width: 33, height: 33))
                    .position(m).allowsHitTesting(false)
            }
        }
    }

    // MARK: Floating top buttons

    private var floatingBar: some View {
        HStack(spacing: 8) {
            FloatButton(system: "chevron.left") { dismiss() }.accessibilityIdentifier("btn-back")
            // HDR is a photo-wide mode, so it sits up here rather than inside the Light page
            Button { vm.settings.hdr.toggle() } label: {
                Text("HDR").font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(vm.settings.hdr ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                    .background(Color.black.opacity(vm.settings.hdr ? 0 : 0.25), in: Capsule())
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("pill-hdr")
            .accessibilityValue(vm.settings.hdr ? "on" : "off")
            Spacer()
            // every tool's edits: switch one off to compare, reset one, or reset all
            FloatButton(system: "switch.2", active: !vm.settings.disabled.isEmpty) { showEdits = true }
                .accessibilityIdentifier("btn-edits")
            FloatButton(system: "arrow.uturn.backward", disabled: !vm.canUndo) { vm.undo() }.accessibilityIdentifier("btn-undo")
            FloatButton(system: "arrow.uturn.forward", disabled: !vm.canRedo) { vm.redo() }.accessibilityIdentifier("btn-redo")
            // Export has its own button: it used to be the last entry of a long menu that could not always be scrolled.
            // DRAFT — sandbox: the export gate lives here (plan §4.1); flag-off builds run the same line as before.
            FloatButton(system: "square.and.arrow.up") { requestExport() }.accessibilityIdentifier("btn-export")
            Menu {
                // Short, flat, most-used first. Nothing in here changes while the menu is open.
                Button { store.clipboard = vm.settings } label: { Label("Copy edits", systemImage: "doc.on.doc") }
                Button { if var c = store.clipboard { c.heals = vm.settings.heals; vm.settings = c } } label: {
                    Label("Paste edits", systemImage: "doc.on.clipboard")
                }.disabled(store.clipboard == nil)
                Button { showPasteSome = true } label: {
                    Label("Paste some edits…", systemImage: "checklist")
                }.disabled(store.clipboard == nil)
                Button(role: .destructive) { vm.reset() } label: { Label("Reset all edits", systemImage: "arrow.counterclockwise") }
                Divider()
                Button { go(-1) } label: { Label("Previous photo", systemImage: "chevron.left") }.disabled(neighbour(-1) == nil)
                Button { go(1) } label: { Label("Next photo", systemImage: "chevron.right") }.disabled(neighbour(1) == nil)
                Divider()
                Menu {
                    let current = store.item(item.id) ?? item
                    ForEach(0...5, id: \.self) { n in
                        Button { store.setRating(current, n == current.rating ? 0 : n) } label: {
                            Label(n == 0 ? "No rating" : String(repeating: "★", count: n),
                                  systemImage: current.rating == n ? "checkmark" : "star")
                        }
                    }
                    Button { store.setFlag(current, 1) } label: { Label("Pick", systemImage: "flag") }
                    Button { store.setFlag(current, -1) } label: { Label("Reject", systemImage: "flag.slash") }
                } label: { Label("Rating and flags", systemImage: "star") }
                Menu {
                    Button { showHistogram.toggle() } label: {
                        Label("Histogram", systemImage: showHistogram ? "checkmark" : "chart.bar")
                    }
                    Button { vm.clipWarning.toggle() } label: {
                        Label("Clipping warning", systemImage: vm.clipWarning ? "checkmark" : "exclamationmark.triangle")
                    }
                    Button { vm.splitPos = 0.5; vm.splitCompare.toggle() } label: {
                        Label("Before / after split", systemImage: vm.splitCompare ? "checkmark" : "rectangle.split.2x1")
                    }
                    Button { sliderStyle = "auto" } label: {
                        Label("Sliders: automatic", systemImage: sliderStyle == "auto" ? "checkmark" : "slider.horizontal.3")
                    }
                    Button { sliderStyle = "strip" } label: {
                        Label("Sliders: one at a time", systemImage: sliderStyle == "strip" ? "checkmark" : "slider.horizontal.3")
                    }
                    Button { sliderStyle = "list" } label: {
                        Label("Sliders: full list", systemImage: sliderStyle == "list" ? "checkmark" : "slider.horizontal.3")
                    }
                } label: { Label("View", systemImage: "eye") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Color.black.opacity(0.25), in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("btn-menu")
        }
        .padding(.horizontal, 10).padding(.top, 6)
    }

    // MARK: Gestures

    private var canNavigate: Bool { tool != .masks && tool != .crop && tool != .heal }
    // in Heal a resting finger is the start of a stroke, not a request to see the original
    private var canCompare: Bool { tool != .crop && tool != .heal && !(tool == .masks && vm.maskTab == .shape && vm.selectedMask != nil) }
    /// One finger pans a zoomed photo wherever it is not busy with something else (mask handles, brush, crop frame).
    private var canPan: Bool { tool != .crop }
    /// In Masks the photo can be made smaller than the screen, so a gradient or radial can reach far past its edges.
    private var minZoom: CGFloat { tool == .masks ? 0.3 : 1 }

    /// Tap = hide/show the panels, double-tap = zoom to that spot (or back), press and hold = see the original until
    /// you let go, drag = pan when zoomed, swipe sideways = next/previous photo.
    @ViewBuilder
    private func gestureLayer(_ xform: ViewXform) -> some View {
        Color.clear.contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("photo")
            .accessibilityLabel(item.displayName)
            .accessibilityValue("zoom \(String(format: "%.1f", Double(zoom))) original \(vm.showOriginal) chrome \(chromeHidden ? "hidden" : "shown") overlay \(vm.overlayVisible) image \(Int(vm.imageSize.width))x\(Int(vm.imageSize.height)) drawn \(Int(xform.rect.minY)) \(Int(xform.rect.maxY)) of \(Int(xform.canvas.height))")
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
            .gesture(panGesture(xform), including: canPan ? .all : .none)
            .simultaneousGesture(
                DragGesture(minimumDistance: 50).onEnded { v in
                    guard canNavigate, zoom <= 1.05, zoom >= 0.95, twoFinger == nil,
                          Date().timeIntervalSince(lastHoldEnd) > 0.5, Date().timeIntervalSince(lastPinchEnd) > 0.4,
                          abs(v.translation.width) > 110, abs(v.translation.height) < 70 else { return }
                    go(v.translation.width < 0 ? 1 : -1)
                })
    }

    /// Holding still shows the original; once the finger starts moving it is a pan, a stroke or a handle drag instead.
    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3, maximumDistance: 25)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($holding) { value, state, _ in
                if case .second(true, let drag) = value {
                    state = drag.map { hypot($0.translation.width, $0.translation.height) < 14 } ?? true
                }
            }
    }

    /// The photo before/after this one in the library, in the order the library shows them (rejected photos skipped).
    private func neighbour(_ delta: Int) -> LibraryItem? {
        let shown = store.browseOrder.compactMap { store.item($0) }
        let base = shown.contains(where: { $0.id == item.id }) ? shown : store.items
        let items = base.filter { $0.flag != -1 || $0.id == item.id }
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
    /// Zoomed out in Masks it may move further, so handles can be put well past any edge of the picture.
    private func clampPan(_ p: CGSize, zoom z: CGFloat, _ xf: ViewXform) -> CGSize {
        guard xf.image.width > 0, xf.image.height > 0, xf.canvas.width > 0, xf.canvas.height > 0 else { return .zero }
        let fit = min(xf.canvas.width / xf.image.width, xf.canvas.height / xf.image.height)
        let w = xf.image.width * fit * z, h = xf.image.height * fit * z
        var mx = max((w - xf.canvas.width) / 2, 0), my = max((h - xf.canvas.height) / 2, 0)
        if tool == .masks && z < 0.999 { mx += xf.canvas.width * 0.3; my += xf.canvas.height * 0.3 }
        guard mx > 0.5 || my > 0.5 else { return .zero }
        return CGSize(width: min(max(p.width, -mx), mx), height: min(max(p.height, -my), my))
    }

    /// Zooms to `z` keeping the image point under `anchor` where it was.
    /// How far below the view's centre the photo's centre sits at zoom `z` (photo resting on the panel), before panning.
    private func drop(_ z: CGFloat, _ xf: ViewXform) -> CGFloat {
        var x = xf
        x.zoom = z
        x.pan = .zero
        return x.rect.midY - xf.canvas.height / 2
    }

    private func setZoom(_ z: CGFloat, anchor: CGPoint, from base: (zoom: CGFloat, pan: CGSize), _ xf: ViewXform) {
        let nz = min(max(z, minZoom), maxZoom)
        let c = CGPoint(x: xf.canvas.width / 2, y: xf.canvas.height / 2)
        let ratio = nz / base.zoom
        let dx = anchor.x - c.x
        // the photo point under the anchor stays under it (allowing for the photo resting on the panel)
        let qy = (anchor.y - c.y - drop(base.zoom, xf) - base.pan.height) / base.zoom
        let p = CGSize(width: dx - (dx - base.pan.width) * ratio, height: anchor.y - c.y - drop(nz, xf) - qy * nz)
        zoom = nz
        pan = clampPan(p, zoom: nz, xf)
    }

    private func toggleZoom(at p: CGPoint, _ xf: ViewXform) {
        withAnimation(.easeInOut(duration: 0.22)) {
            if zoom > 1.05 || zoom < 0.95 { resetZoom() } else { setZoom(3, anchor: p, from: (1, .zero), xf) }
        }
    }

    /// Two fingers: zoom by how far apart they are, around the point between them, and move the photo with that point,
    /// all at once (like Photos). `p` is in canvas coordinates.
    private func twoFingers(_ phase: TwoFingerWatcher.Phase, _ p: CGPoint, _ spread: CGFloat, _ xf: ViewXform) {
        guard tool != .crop, xf.image != .zero else { return }
        switch phase {
        case .began:
            if DemoMode.isOn { DemoMode.log(String(format: "pinch began spread %.0f tool %@", Double(spread), tool?.rawValue ?? "none")) }
            vm.pinching = true
            if tool == .masks { vm.cancelRecentStroke() }   // the first finger of a pinch must not leave a brush dab
            if tool == .heal { vm.healCancel() }
            twoFinger = (zoom, pan, p, spread)
            panBase = nil
            pinchBase = nil
            vm.showOriginal = false
        case .changed:
            guard let b = twoFinger else { return }
            // a little give past the limits while the fingers are down; it settles back when they lift
            let z = min(max(b.zoom * spread / b.spread, minZoom * 0.8), maxZoom * 1.15)
            let c = CGPoint(x: xf.canvas.width / 2, y: xf.canvas.height / 2)
            let qx = (b.centre.x - c.x - b.pan.width) / b.zoom
            let qy = (b.centre.y - c.y - drop(b.zoom, xf) - b.pan.height) / b.zoom
            zoom = z
            pan = clampPan(CGSize(width: p.x - c.x - qx * z, height: p.y - c.y - drop(z, xf) - qy * z), zoom: z, xf)
        case .ended:
            vm.pinching = false
            guard twoFinger != nil else { return }
            twoFinger = nil
            lastPinchEnd = Date()
            settleZoom(xf)
        }
    }

    /// After a pinch: back inside the zoom limits; anything close to "fit" snaps to it.
    private func settleZoom(_ xf: ViewXform) {
        let target = min(max(zoom, minZoom), maxZoom)
        guard target != zoom || abs(target - 1) < 0.03 else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            if abs(target - 1) < 0.03 { resetZoom() } else { zoom = target; pan = clampPan(pan, zoom: target, xf) }
        }
    }

    private func zoomGesture(_ xf: ViewXform) -> some Gesture {
        MagnifyGesture()
            .updating($pinchTouching) { _, state, _ in state = true }
            .onChanged { v in
                guard twoFinger == nil, Date().timeIntervalSince(lastPinchEnd) > 0.3 else { return }
                if pinchBase == nil {
                    pinchBase = (zoom, pan)
                    if tool == .masks { vm.cancelRecentStroke() }   // the first finger of a pinch must not leave a brush dab
                    if tool == .heal { vm.healCancel() }
                }
                if let b = pinchBase { setZoom(b.zoom * v.magnification, anchor: v.startLocation, from: b, xf) }
            }
            .onEnded { _ in
                guard pinchBase != nil else { return }
                pinchBase = nil
                settleZoom(xf)
            }
    }

    /// One finger moves a zoomed photo. Picks up from wherever a pinch left it, so lifting one of two fingers never jumps.
    private func panGesture(_ xf: ViewXform) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($panTouching) { _, state, _ in state = true }
            .onChanged { v in
                if twoFinger != nil { panBase = nil; return }
                if panBase == nil {
                    panBase = CGSize(width: pan.width - v.translation.width, height: pan.height - v.translation.height)
                }
                if let b = panBase {
                    let p = clampPan(CGSize(width: b.width + v.translation.width, height: b.height + v.translation.height),
                                     zoom: zoom, xf)
                    if p != pan { pan = p }
                }
            }
            .onEnded { _ in panBase = nil }
    }

    // MARK: Tools

    /// The folded tool bar: the current tool's name; tap to bring the tools back.
    private var collapsedToolBar: some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { toolsCollapsed = false } } label: {
            HStack(spacing: 6) {
                if let tool { Image(systemName: tool.icon).font(.system(size: 13)) }
                Text(tool?.rawValue ?? "Tools").font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color(white: 0.75))
            .frame(maxWidth: .infinity).frame(height: collapsedBarHeight)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("tools-expand")
        .accessibilityLabel("Show tools")
    }

    /// Eight tools, all visible at once. `compact` (landscape side column): icons only, a slimmer bar.
    private func toolBar(compact: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Tool.allCases) { t in
                Button { withAnimation(.easeOut(duration: 0.15)) { tool = (tool == t) ? nil : t } } label: {
                    let sec = t.section
                    let off = sec.map { !vm.settings.isOn($0) } ?? false
                    let edited = sec.map { vm.settings.hasEdits($0) } ?? false
                    VStack(spacing: 2) {
                        Image(systemName: t.icon).font(.system(size: 18))
                            .opacity(off ? 0.35 : 1)
                            .overlay(alignment: .topTrailing) {
                                if off { Image(systemName: "eye.slash").font(.system(size: 9, weight: .bold)).offset(x: 8, y: -4) }
                            }
                        if !compact { Text(t.rawValue).font(.system(size: 9.5, weight: .medium)) }
                        // the same "changed" dot as on the sliders: this tool has edits
                        Circle().fill(edited && !off ? Theme.accent : Color.clear).frame(width: 4, height: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? landscapeBarHeight : toolbarHeight)
                    .foregroundStyle(tool == t ? Theme.accent : Color(white: 0.6))
                }
                .accessibilityIdentifier("tool-\(t.rawValue)")
                .accessibilityLabel(t.rawValue)
                .accessibilityValue(t.section.map { vm.settings.isOn($0) ? "on" : "off" } ?? "")
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
        case .heal: HealPanel(vm: vm)
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
