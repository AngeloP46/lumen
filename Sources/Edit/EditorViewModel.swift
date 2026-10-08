import SwiftUI
import Photos
import CoreImage

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

    @Published var settings = EditSettings() {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    @Published var showOriginal = false { didSet { requestRender() } }
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
    @Published private(set) var autoMaskBusy = false
    @Published private(set) var autoMaskMissing: Set<String> = []

    private var session: EditSession?
    private var source: ImageSource?
    private weak var store: LibraryStore?
    private var started = false
    private var histPending = false
    private var histImage: CIImage?
    private var saveWork: DispatchWorkItem?

    // Undo / redo
    private var undoStack: [EditSettings] = []
    private var redoStack: [EditSettings] = []
    private var applyingHistory = false
    private var lastChange = Date.distantPast
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(item: LibraryItem) { self.item = item }

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
        workQueue.async {
            let s = EditSession(url: url)
            let src = s?.makeSource(maxEdge: 2560, materialize: true)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.session = s
                self.source = src
                self.isLoading = false
                self.loadFailed = (src == nil)
                if let src { self.imageSize = src.size }
                self.requestRender()
                self.prepareAutoMasksIfNeeded()
            }
        }
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
        var img = session.develop(s, source: source, geometry: !skipGeometry)
        let base = img
        if overlayVisible, let m = selectedMask {
            img = session.overlay(img, mask: m, source: source, gain: exp2(s.exposure))
        }
        if img.extent.size != imageSize { imageSize = img.extent.size }
        canvas.update(img)
        scheduleHistogram(base)
    }

    private func scheduleHistogram(_ img: CIImage) {
        histImage = img
        guard !histPending else { return }
        histPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let img = self.histImage else { return }
            self.histPending = false
            histQueue.async {
                let e = img.extent
                let k = 160 / max(e.width, e.height)
                let small = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
                guard let cg = LumenGPU.context.createCGImage(small, from: small.extent, format: .RGBA8,
                                                              colorSpace: LumenGPU.displaySpace) else { return }
                let h = Histogram.compute(cg)
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
                self.requestRender()
                self.prepareAutoMasksIfNeeded()   // masks may have changed while we were busy
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
        s.cropZoom = settings.cropZoom
        s.cropX = settings.cropX
        s.cropY = settings.cropY
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
        let n = settings.masks.filter { $0.name.hasPrefix(base) }.count
        return n == 0 ? base : "\(base) \(n + 1)"
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
        updateComponent(c.id) { $0.strokes.append(stroke) }
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

    func export(_ format: ExportFormat) {
        guard let session, !isExporting else { return }
        isExporting = true
        let s = settings
        let name = item.displayName
        workQueue.async {
            let data = session.renderData(s, format: format, quality: 0.92)
            var url: URL?
            if let data {
                let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-lumen.\(format.ext)")
                if (try? data.write(to: u, options: .atomic)) != nil { url = u }
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
