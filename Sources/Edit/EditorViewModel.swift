import SwiftUI
import Photos
import CoreImage
import UniformTypeIdentifiers

private let histQueue = DispatchQueue(label: "lumen.hist", qos: .utility)
private let workQueue = DispatchQueue(label: "lumen.work", qos: .userInitiated)

struct ExportResult: Identifiable {
    let id = UUID()
    let url: URL
}

enum MaskTab: String, CaseIterable, Identifiable {
    case shape = "Shape", adjust = "Adjust"
    var id: String { rawValue }
}

@MainActor
final class EditorViewModel: ObservableObject {
    let item: LibraryItem
    let canvas = CanvasModel()
    /// The screen's EDR headroom right now and at most (1 = no HDR room). Only tracked while HDR is on.
    private var currentHeadroom: CGFloat = 1
    private var potentialHeadroom: CGFloat = 1
    /// iPhone screens only switch into HDR once something brighter than white is drawn, and report a current headroom
    /// of 1 until then. Waiting for it meant HDR never switched on, so the potential headroom is used until the screen
    /// is in HDR mode; after that the real (current) headroom, so the highlights roll off instead of clipping.
    private var effectiveHeadroom: CGFloat { currentHeadroom > 1.05 ? currentHeadroom : potentialHeadroom }
    /// Stops above SDR white the screen shows for this photo right now (0 = none). Drives the HDR badge.
    @Published private(set) var hdrScreenStops: Double = 0
    private var loadGeneration = 0

    @Published var settings = EditSettings() {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    @Published var showOriginal = false { didSet { requestRender(); if DemoMode.isOn { DemoMode.log("original \(showOriginal)") } } }
    @Published private(set) var histogram: HistogramData?
    @Published private(set) var imageSize: CGSize = .zero
    @Published private(set) var isLoading = true
    @Published private(set) var loadFailed = false
    @Published var isExporting = false
    @Published var exported: ExportResult?
    @Published var message: String?
    @Published private(set) var presetThumbs: [String: UIImage] = [:]

    // Mask editing
    @Published var maskEditing = false { didSet { requestRender() } }
    @Published var maskTab: MaskTab = .shape { didSet { requestRender() } }
    @Published var overlayEnabled = true { didSet { requestRender() } }
    @Published var peekOverlay = false { didSet { requestRender() } }
    @Published var selectedMaskID: UUID? { didSet { requestRender() } }
    @Published var selectedComponentID: UUID?
    @Published var brushSize = 0.06
    @Published var brushErase = false
    @Published var colorAddMode = false
    @Published var colorMix = false           // Color tool is showing the colour mixer
    @Published var panMode = false          // single finger pans the zoomed photo instead of painting / dragging handles
    private var strokeStart: Date?
    @Published private(set) var autoMaskBusy = false
    @Published private(set) var autoMaskMissing: Set<String> = []

    // Crop editing: the whole straightened picture is shown with a frame on top
    @Published var cropEditing = false { didSet { requestRender() } }

    // Full-resolution source used while zoomed in (100% view)
    @Published private(set) var detailLoading = false
    private var detailSource: ImageSource?
    private var detailBuilding = false
    private var zoomLevel: CGFloat = 1
    private var releaseTask: Task<Void, Never>?

    private var session: EditSession?
    private var source: ImageSource?
    private weak var store: LibraryStore?
    private var started = false
    private var histPending = false
    private var histImage: CIImage?
    private var histHDRImage: CIImage?
    private var histStops: (Double, Double) = (2, 0)
    private var saveWork: DispatchWorkItem?

    // Undo / redo
    private var undoStack: [EditSettings] = []
    private var redoStack: [EditSettings] = []
    private var applyingHistory = false
    private var lastChange = Date.distantPast
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(item: LibraryItem) {
        self.item = item
        canvas.onHeadroom = { [weak self] current, potential in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentHeadroom = current
                self.potentialHeadroom = potential
                if self.settings.hdr { self.requestRender() }
            }
        }
    }

    var selectedMask: Mask? { settings.masks.first { $0.id == selectedMaskID } }
    var selectedComponent: MaskComponent? {
        guard let m = selectedMask else { return nil }
        return m.components.first { $0.id == selectedComponentID } ?? m.components.first
    }
    var overlayVisible: Bool {
        maskEditing && !showOriginal && selectedMask != nil && ((maskTab == .shape && overlayEnabled) || peekOverlay)
    }

    // MARK: Loading

    func start(store: LibraryStore) {
        guard !started else { return }
        started = true
        self.store = store
        applyingHistory = true
        settings = store.settings(for: item)
        applyingHistory = false
        let url = store.fileURL(item)
        let wantsHDR = settings.hdr
        let asked = Date()
        workQueue.async {
            let began = Date()
            let s = EditSession(url: url, expandHDR: wantsHDR)
            let src = s?.makeSource(maxEdge: 2560, materialize: true)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if DemoMode.isOn {
                    DemoMode.log(String(format: "loaded %@ queued %.1fs decoded %.1fs", url.lastPathComponent,
                                        began.timeIntervalSince(asked), Date().timeIntervalSince(began)))
                }
                self.session = s
                self.source = src
                self.isLoading = false
                self.loadFailed = (src == nil)
                if let src { self.imageSize = src.size }
                self.requestRender()
                self.prepareAutoMasksIfNeeded()
                // HDR was switched while the photo was still loading: decode it again the other way
                if self.settings.hdr != wantsHDR { self.reloadSource() }
            }
        }
    }

    /// HDR on or off changes how the file is decoded (RAW: more highlight range; gain-map JPEG/HEIC: the HDR version),
    /// so decode it again. Automatic masks already found are kept.
    private func reloadSource() {
        guard let store, session != nil else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let url = store.fileURL(item)
        let wantsHDR = settings.hdr
        let previous = source
        workQueue.async {
            let s = EditSession(url: url, expandHDR: wantsHDR)
            let src = s?.makeSource(maxEdge: 2560, materialize: true)
            Task { @MainActor [weak self] in
                guard let self, generation == self.loadGeneration, let s, let src else { return }
                if let previous, previous.size == src.size {
                    let (masks, tried) = previous.snapshotMasks()
                    for key in tried { src.storeMask(key, masks[key]) }
                }
                self.session = s
                self.source = src
                self.detailSource = nil
                if DemoMode.isOn { DemoMode.log("reloaded hdr \(wantsHDR)") }
                self.requestRender()
                self.prepareAutoMasksIfNeeded()
            }
        }
    }

    /// What the file is, so it is clear whether there is extra highlight detail to work with (RAW) or not (JPEG).
    var fileKind: String {
        let ext = (item.fileName as NSString).pathExtension.lowercased()
        let raw = UTType(filenameExtension: ext)?.conforms(to: .rawImage) ?? false
        return raw ? "RAW · \(ext.uppercased())" : (ext == "jpg" ? "JPEG" : ext.uppercased())
    }

    /// The HDR badge: how far above white the screen is showing this photo, or why nothing is.
    var hdrBadge: String {
        if hdrScreenStops < 0.1 {
            return ProcessInfo.processInfo.isLowPowerModeEnabled ? "HDR · off in Low Power Mode" : "HDR · screen can't show it now"
        }
        if let h = histogram, h.sdrFraction != nil, h.hdrPeakStops < 0.05 { return "HDR · nothing above white in this photo" }
        return String(format: "HDR +%.1f", hdrScreenStops)
    }

    private func settingsChanged(from old: EditSettings) {
        if !applyingHistory {
            if undoStack.isEmpty || Date().timeIntervalSince(lastChange) > 0.6 {
                undoStack.append(old)
                if undoStack.count > 100 { undoStack.removeFirst() }
                redoStack.removeAll()
            }
            lastChange = Date()
        }
        scheduleSave()
        requestRender()
        if settings.masks != old.masks { prepareAutoMasksIfNeeded() }
        if settings.hdr != old.hdr { reloadSource() }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let s = settings, item = item
        let work = DispatchWorkItem { [weak store] in
            Task { @MainActor in store?.save(s, for: item) }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flushSave() {
        saveWork?.cancel()
        store?.save(settings, for: item)
    }

    // MARK: Rendering

    /// Rebuilds the (lazy) graph and hands it to the Metal view. Cheap enough to call on every slider tick.
    func requestRender() {
        guard let session, let source else { return }
        let s = showOriginal ? EditSettings() : settings
        let skipGeometry = maskEditing && !showOriginal
        let applyCrop = !(cropEditing && !showOriginal)
        let useDetail = zoomLevel > 1.4 && detailSource != nil
        let active = (useDetail ? detailSource : nil) ?? source
        // HDR: show as much of the highlights' range as the screen can display right now (headroom 1 = none)
        let screenStops = min(max(log2(Double(effectiveHeadroom)), 0), settings.hdrStops)
        let hdrWeight = s.hdr ? screenStops / max(s.hdrStops, 0.01) : 0
        let badgeStops = settings.hdr ? screenStops : 0
        if hdrScreenStops != badgeStops { hdrScreenStops = badgeStops }
        var img = session.develop(s, source: active, geometry: !skipGeometry, applyCrop: applyCrop, hdrWeight: hdrWeight)
        // the histogram always reads the small SDR preview, even while the 100% view is showing
        let base = (useDetail || hdrWeight > 0) ? session.develop(s, source: source, geometry: !skipGeometry, applyCrop: applyCrop) : img
        // in HDR the histogram shows everything the photo holds above white, also what the screen can't show now
        let hdrImg: CIImage? = s.hdr ? session.develop(s, source: source, geometry: !skipGeometry, applyCrop: applyCrop, hdrWeight: 1) : nil
        if overlayVisible, let m = selectedMask {
            img = session.overlay(img, mask: m, source: active, gain: exp2(s.exposure))
        }
        // sized from the preview so the shape stays right (crop, rotation, original) while the 100% view is showing
        if base.extent.size != imageSize { imageSize = base.extent.size }
        canvas.update(img)
        scheduleHistogram(base, hdr: hdrImg, stops: s.hdrStops, screenStops: screenStops)
    }

    // MARK: 100% view

    func zoomChanged(_ z: CGFloat) {
        let wasDetail = zoomLevel > 1.4
        zoomLevel = z
        if z > 1.4 {
            releaseTask?.cancel()
            releaseTask = nil
            if detailSource == nil { buildDetail() } else if !wasDetail { requestRender() }
        } else {
            if wasDetail { requestRender() }
            if z <= 1.05, detailSource != nil, releaseTask == nil {
                releaseTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    if self.zoomLevel <= 1.05 { self.detailSource = nil }
                    self.releaseTask = nil
                }
            }
        }
    }

    private func buildDetail() {
        guard let session, let source, !detailBuilding else { return }
        let native = max(session.nativeSize.width, session.nativeSize.height)
        guard native > source.longEdge * 1.15 else { return }
        detailBuilding = true
        detailLoading = true
        let edge = min(native, 6000)
        workQueue.async {
            let src = session.makeSource(maxEdge: edge, materialize: true)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.detailBuilding = false
                self.detailLoading = false
                self.detailSource = src
                self.syncDetailMasks()
                self.requestRender()
                // zoomed back out while it was building: start the usual release countdown
                if self.zoomLevel <= 1.05 { self.zoomChanged(self.zoomLevel) }
            }
        }
    }

    /// Automatic masks are found once on the preview and shared with the full-resolution source.
    private func syncDetailMasks() {
        guard let source, let detail = detailSource else { return }
        let (masks, tried) = source.snapshotMasks()
        let sx = detail.size.width / source.size.width, sy = detail.size.height / source.size.height
        for key in tried { detail.storeMask(key, masks[key]?.transformed(by: CGAffineTransform(scaleX: sx, y: sy))) }
    }

    // MARK: Crop frame

    /// Aspect ratio of the picture currently shown (the whole straightened picture while cropping).
    private var shownAspect: Double { imageSize.height > 0 ? Double(imageSize.width / imageSize.height) : 1.5 }

    /// Aspect of the original file after any 90° turns.
    var originalAspect: Double {
        guard let source else { return 1.5 }
        let a = Double(source.size.width / source.size.height)
        return abs(settings.quarterTurns) % 2 == 1 ? 1 / a : a
    }

    func setCropFrame(_ l: Double, _ t: Double, _ r: Double, _ b: Double) {
        settings.cropL = l; settings.cropT = t; settings.cropR = r; settings.cropB = b
    }

    func resetCropFrame() {
        settings.cropAspect = 0
        setCropFrame(0, 0, 1, 1)
    }

    /// Locks the frame to `ratio` (0 = free) and fits the largest centred frame of that shape.
    func setCropAspect(_ ratio: Double) {
        var s = settings
        s.cropAspect = ratio
        if ratio > 0 {
            let a0 = shownAspect
            let fw: Double, fh: Double
            if ratio >= a0 { fw = 1; fh = a0 / ratio } else { fh = 1; fw = ratio / a0 }
            s.cropL = (1 - fw) / 2; s.cropR = (1 + fw) / 2
            s.cropT = (1 - fh) / 2; s.cropB = (1 + fh) / 2
        }
        settings = s
    }

    /// Swaps landscape/portrait for the locked ratio.
    func flipCropOrientation() {
        guard settings.cropAspect > 0, abs(settings.cropAspect - 1) > 0.001 else { return }
        setCropAspect(1 / settings.cropAspect)
    }

    private func scheduleHistogram(_ img: CIImage, hdr: CIImage? = nil, stops: Double = 2, screenStops: Double = 0) {
        histImage = img
        histHDRImage = hdr
        histStops = (stops, screenStops)
        guard !histPending else { return }
        histPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let img = self.histImage else { return }
            let hdrImg = self.histHDRImage
            let (stops, screenStops) = self.histStops
            self.histPending = false
            histQueue.async {
                let e = img.extent
                guard !e.isEmpty, !e.isInfinite, max(e.width, e.height) > 0 else { return }
                let k = 160 / max(e.width, e.height)
                let small = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
                guard let cg = LumenGPU.context.createCGImage(small, from: small.extent, format: .RGBA8,
                                                              colorSpace: LumenGPU.displaySpace) else { return }
                var h = Histogram.compute(cg)
                if let hdrImg, h != nil { Histogram.addHDR(&h!, hdrImg, stops: stops, screenStops: screenStops) }
                Task { @MainActor [weak self] in self?.histogram = h }
            }
        }
    }

    private func prepareAutoMasksIfNeeded() {
        guard let session, let source, !autoMaskBusy else { return }
        let needs = settings.masks.contains { m in m.components.contains { $0.kind.isAutomatic } }
        guard needs else { return }
        let snapshot = settings
        autoMaskBusy = true
        workQueue.async {
            session.prepareAutoMasks(snapshot, source: source)
            let missing: Set<String> = Set([EditSession.aiSubject, EditSession.aiSky].filter { source.hasTried($0) && source.cachedMask($0) == nil })
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.autoMaskBusy = false
                self.autoMaskMissing = missing
                self.syncDetailMasks()
                self.requestRender()
                // masks may have changed while we were busy
                if self.settings.masks != snapshot.masks { self.prepareAutoMasksIfNeeded() }
            }
        }
    }

    // MARK: History

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(settings)
        applyingHistory = true
        settings = last
        applyingHistory = false
        lastChange = .distantPast
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(settings)
        applyingHistory = true
        settings = next
        applyingHistory = false
        lastChange = .distantPast
    }

    func reset() { settings = EditSettings() }

    func auto() {
        guard let session, let source else { return }
        settings = session.autoSettings(source: source, current: settings)
    }

    // MARK: Presets

    func apply(preset edits: EditSettings) {
        var s = edits
        s.masks = settings.masks
        s.straighten = settings.straighten
        s.quarterTurns = settings.quarterTurns
        s.cropAspect = settings.cropAspect
        s.cropL = settings.cropL; s.cropT = settings.cropT
        s.cropR = settings.cropR; s.cropB = settings.cropB
        s.hdr = settings.hdr; s.hdrStops = settings.hdrStops
        if s.temperature == 0 && s.tint == 0 {
            s.temperature = settings.temperature
            s.tint = settings.tint
        }
        settings = s
    }

    func apply(_ p: Preset) {
        var s = EditSettings()
        p.apply(&s)
        apply(preset: s)
    }

    func loadPresetThumbs(user: [UserPreset]) {
        guard let session, presetThumbs.isEmpty || presetThumbs.count < Preset.all.count + user.count else { return }
        var jobs: [(String, EditSettings)] = Preset.all.map { p in
            var s = EditSettings()
            p.apply(&s)
            return (p.name, s)
        }
        jobs += user.map { ($0.id.uuidString, $0.settings) }
        let turns = settings.quarterTurns
        workQueue.async {
            guard let thumbSource = session.makeSource(maxEdge: 200, materialize: false) else { return }
            for (key, var s) in jobs {
                s.masks = []
                s.quarterTurns = turns
                guard let cg = session.renderCGImage(s, source: thumbSource) else { continue }
                let img = UIImage(cgImage: cg)
                Task { @MainActor [weak self] in self?.presetThumbs[key] = img }
            }
        }
    }

    // MARK: Masks

    func addMask(_ kind: MaskKind) {
        var m = Mask.make(kind)
        m.name = uniqueName(kind.title)
        settings.masks.append(m)
        selectedMaskID = m.id
        selectedComponentID = m.components.first?.id
        maskTab = .shape
        overlayEnabled = true
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(settings.masks.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    func selectMask(_ id: UUID) {
        selectedMaskID = id
        selectedComponentID = settings.masks.first { $0.id == id }?.components.first?.id
    }

    func addComponent(_ kind: MaskKind, op: MaskOp) {
        guard let id = selectedMaskID else { return }
        let c = MaskComponent.make(kind, op: op)
        updateMask(id) { $0.components.append(c) }
        selectedComponentID = c.id
        overlayEnabled = true
    }

    func deleteComponent(_ cid: UUID) {
        guard let id = selectedMaskID else { return }
        updateMask(id) { m in
            if m.components.count > 1 { m.components.removeAll { $0.id == cid } }
            // the first component is the base: its op is ignored when rendering and locked in the panel
            if !m.components.isEmpty { m.components[0].op = .add }
        }
        selectedComponentID = selectedMask?.components.first?.id
    }

    func updateMask(_ id: UUID, _ change: (inout Mask) -> Void) {
        guard let i = settings.masks.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.masks[i])
    }

    func updateComponent(_ cid: UUID, _ change: (inout MaskComponent) -> Void) {
        guard let id = selectedMaskID else { return }
        updateMask(id) { m in
            guard let i = m.components.firstIndex(where: { $0.id == cid }) else { return }
            change(&m.components[i])
        }
    }

    func deleteMask(_ id: UUID) {
        settings.masks.removeAll { $0.id == id }
        if selectedMaskID == id {
            if let last = settings.masks.last { selectMask(last.id) } else { selectedMaskID = nil; selectedComponentID = nil }
        }
    }

    func beginStroke(_ p: Pt) {
        guard let c = selectedComponent, c.kind == .brush else { return }
        let stroke = BrushStroke(points: [p], size: brushSize, erase: brushErase)
        strokeStart = Date()
        updateComponent(c.id) { $0.strokes.append(stroke) }
    }

    /// A pinch starts with one finger down, which paints a stray dab: take it back.
    func cancelRecentStroke() {
        guard let c = selectedComponent, c.kind == .brush, let t = strokeStart, Date().timeIntervalSince(t) < 0.8,
              let last = c.strokes.last, last.points.count <= 4 else { return }
        strokeStart = nil
        updateComponent(c.id) { _ = $0.strokes.popLast() }
    }

    func extendStroke(_ p: Pt) {
        guard let c = selectedComponent, c.kind == .brush else { return }
        updateComponent(c.id) { comp in
            guard var last = comp.strokes.popLast() else { return }
            if let prev = last.points.last, hypot(prev.x - p.x, prev.y - p.y) < 0.002 {
                comp.strokes.append(last)
                return
            }
            last.points.append(p)
            comp.strokes.append(last)
        }
    }

    /// Tap on the photo while a colour or luminance mask is selected.
    func pick(at p: Pt, addToSelection: Bool = false) {
        guard let c = selectedComponent, let source else { return }
        let rgb = source.stats.average(atNormalized: p.x, p.y, radius: 1)
        switch c.kind {
        case .color:
            let sample = ColorSample(r: Double(rgb.x), g: Double(rgb.y), b: Double(rgb.z))
            updateComponent(c.id) { comp in
                if addToSelection && comp.samples.count < 4 { comp.samples.append(sample) } else { comp.samples = [sample] }
            }
        case .luminance:
            let y = Double(Ok.encode(0.22897 * rgb.x * Float(exp2(settings.exposure))
                                     + 0.69174 * rgb.y * Float(exp2(settings.exposure))
                                     + 0.07929 * rgb.z * Float(exp2(settings.exposure))))
            updateComponent(c.id) { comp in
                comp.lumLow = max(0, y - 0.12)
                comp.lumHigh = min(1, y + 0.12)
                comp.lumLowFeather = 0.12
                comp.lumHighFeather = 0.12
            }
        default: break
        }
    }

    /// Display colour of a stored sample (for swatches).
    static func swatch(_ s: ColorSample) -> Color {
        Color(.displayP3, red: Double(Ok.encode(Float(s.r))), green: Double(Ok.encode(Float(s.g))), blue: Double(Ok.encode(Float(s.b))))
    }

    // MARK: Export

    func export(_ o: ExportOptions) {
        guard let session, !isExporting else { return }
        isExporting = true
        let s = settings
        let name = item.displayName
        workQueue.async {
            let data = session.renderData(s, format: o.format, quality: o.quality / 100, maxEdge: o.maxEdge, includeHDR: o.hdr)
            var url: URL?
            if let data {
                let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-lumen.\(o.format.ext)")
                if (try? data.write(to: u, options: .atomic)) != nil { url = u }
                if DemoMode.isOn { DemoMode.log("exported \(o.format.rawValue) q \(Int(o.quality)) edge \(o.longEdge) bytes \(data.count)") }
            }
            Task { @MainActor [weak self] in
                self?.isExporting = false
                if let url { self?.exported = ExportResult(url: url) } else { self?.message = "Export failed." }
            }
        }
    }

    func saveToPhotos(_ url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "Photos access was denied. Enable it in Settings, or use Share → Save to Files."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
            }
            message = "Saved to Photos."
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
