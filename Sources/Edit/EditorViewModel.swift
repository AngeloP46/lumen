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
    /// Size of the preview source (the uncropped, unturned photo masks are stored against).
    @Published private(set) var sourceSize: CGSize = .zero
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
    /// Two fingers are on the photo: mask handles ignore the drag (the fingers are zooming, not moving the mask).
    var pinching = false
    @Published var panMode = false          // single finger pans the zoomed photo instead of painting / dragging handles
    private var strokeStart: Date?
    private var strokeOpen = false
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
    /// The preview without heals, for the before view (press and hold) and the split compare. Only kept while the
    /// photo has heals.
    private var unhealedSource: ImageSource?
    private var unhealedHDR = false
    /// Estimated depth of the open photo (once a Depth mask asked for it).
    var depthField: DepthField? { source?.depthField }
    /// What the scene model found in the open photo (Landscape mask parts).
    var sceneField: SceneField? { source?.sceneField }
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
        var loaded = store.editorSettings(for: item)
        let history = store.history(for: item, current: loaded)
        undoStack = history.undo
        redoStack = history.redo
        // brush strokes painted before strokes kept their own softness: fix them at the softness they show now,
        // so moving the Feather slider never changes strokes already on the photo
        for mi in loaded.masks.indices {
            for ci in loaded.masks[mi].components.indices where loaded.masks[mi].components[ci].kind == .brush {
                let f = loaded.masks[mi].components[ci].feather
                for si in loaded.masks[mi].components[ci].strokes.indices
                where loaded.masks[mi].components[ci].strokes[si].feather == nil {
                    loaded.masks[mi].components[ci].strokes[si].feather = f
                }
            }
        }
        settings = loaded
        applyingHistory = false
        let url = store.fileURL(item)
        let wantsHDR = settings.hdr
        let heals = settings.effective.heals
        let asked = Date()
        workQueue.async {
            let began = Date()
            let s = EditSession(url: url, expandHDR: wantsHDR)
            s?.heals = heals
            let src = s?.makeSource(maxEdge: 2560, materialize: true)
            // Simulator interaction fixture only; real builds always use estimated camera-photo depth.
            if DemoMode.isOn, DemoMode.value("-lumenDemoLensDepth") != nil, let src {
                let values = (0..<4096).map { Float($0 % 64) / 63 }
                let field = DepthField(width: 64, height: 64, values: values, histogram: Array(repeating: 1, count: 64))
                src.storeDepth(field)
                src.storeMask(EditSession.aiDepth, EditSession.depthImage(field, extent: src.extent))
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if DemoMode.isOn {
                    DemoMode.log(String(format: "loaded %@ queued %.1fs decoded %.1fs", url.lastPathComponent,
                                        began.timeIntervalSince(asked), Date().timeIntervalSince(began)))
                }
                self.session = s
                self.source = src
                self.unhealedSource = nil   // belonged to the previous photo
                self.isLoading = false
                self.loadFailed = (src == nil)
                if let src { self.imageSize = src.size; self.sourceSize = src.size }
                self.requestRender()
                self.prepareAutoMasksIfNeeded()
                self.refreshUnhealed()
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
        let heals = settings.effective.heals
        let previous = source
        workQueue.async {
            let s = EditSession(url: url, expandHDR: wantsHDR)
            s?.heals = heals
            let src = s?.makeSource(maxEdge: 2560, materialize: true)
            Task { @MainActor [weak self] in
                guard let self, generation == self.loadGeneration, let s, let src else { return }
                if let previous, previous.size == src.size {
                    let (masks, tried) = previous.snapshotMasks()
                    for key in tried { src.storeMask(key, masks[key]) }
                    src.storeDepth(previous.depthField)
                    src.storeScene(previous.sceneField)
                }
                self.session = s
                self.source = src
                self.sourceSize = src.size
                self.detailSource = nil
                if DemoMode.isOn { DemoMode.log("reloaded hdr \(wantsHDR)") }
                self.requestRender()
                self.prepareAutoMasksIfNeeded()
                self.refreshUnhealed()
                // a new heal shows once the photo has been decoded with it
                if self.healBusy && self.healWaitingForReload { self.healBusy = false; self.healStroke = []; self.healWaitingForReload = false }
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
            }
            redoStack.removeAll()
            lastChange = Date()
        }
        scheduleSave()
        requestRender()
        if settings.masks != old.masks || settings.lensBlur != old.lensBlur { prepareAutoMasksIfNeeded() }
        // HDR changes how the file is decoded; heals are painted in while decoding
        if settings.hdr != old.hdr || settings.effective.heals != old.effective.heals { reloadSource() }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let s = settings, item = item
        let history = LibraryStore.EditHistory(current: s, undo: undoStack, redo: redoStack)
        let work = DispatchWorkItem { [weak store] in
            Task { @MainActor in store?.save(s, for: item, history: history) }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flushSave() {
        saveWork?.cancel()
        store?.save(settings, for: item, history: LibraryStore.EditHistory(current: settings, undo: undoStack, redo: redoStack))
    }

    // MARK: Rendering

    /// Rebuilds the (lazy) graph and hands it to the Metal view. Cheap enough to call on every slider tick.
    func requestRender() {
        guard let session, let source else { return }
        let s = showOriginal ? EditSettings() : settings
        // Masks show the photo cropped and turned like every other tool; the mask overlay and handles map through
        // `SourceGeometry` (before 2026-10-10 the Masks tool showed the uncropped, unturned photo instead)
        let skipGeometry = false
        let applyCrop = !(cropEditing && !showOriginal)
        let useDetail = zoomLevel > 1.4 && detailSource != nil
        var active = (useDetail ? detailSource : nil) ?? source
        // the original is the photo as shot: without heals too (the preview copy, sharp enough for a quick look)
        if showOriginal, let u = unhealedSource { active = u }
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
            let shown = img.extent
            img = session.overlay(img, mask: m, source: active, gain: exp2(s.exposure), settings: s, applyCrop: applyCrop)
                .cropped(to: shown)
        }
        // Remove people: red = will be removed, a faint white = stays
        if let people = peopleFound, !showOriginal {
            let shown = img.extent
            let kept = people.filter { !peopleChosen.contains($0.id) }, chosen = people.filter { peopleChosen.contains($0.id) }
            img = session.tintPeople(img, kept, source: active, settings: s, applyCrop: applyCrop,
                                     colour: CIVector(x: 1, y: 1, z: 1, w: 0.22))
            img = session.tintPeople(img, chosen, source: active, settings: s, applyCrop: applyCrop,
                                     colour: CIVector(x: 1.0, y: 0.1, z: 0.12, w: 0.55)).cropped(to: shown)
        }
        if splitCompare && !showOriginal {
            // the original with the same crop, flip and transform, so the two halves line up
            var o = EditSettings()
            o.take(.crop, from: settings)
            // without heals as well, when the halves are the same size (not in the 100 % view)
            let beforeSource = (!useDetail ? unhealedSource : nil) ?? active
            let before = session.develop(o, source: beforeSource, geometry: !skipGeometry, applyCrop: applyCrop)
            let e = img.extent
            let cut = e.minX + e.width * min(max(splitPos, 0), 1)
            img = img.cropped(to: CGRect(x: cut, y: e.minY, width: e.maxX - cut, height: e.height))
                .composited(over: before.cropped(to: e))
        }
        if clipWarning && !showOriginal, let clip = LumenKernels.shared?.clip {
            let white = s.hdr && hdrScreenStops > 0 ? exp2(hdrScreenStops) * 0.995 : 0.999
            img = (clip.apply(extent: img.extent, arguments: [img, CIVector(x: white, y: 0.0007, z: 0, w: 0)]) ?? img).cropped(to: img.extent)
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
        detail.storeDepth(source.depthField)
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
                let k = 320 / max(e.width, e.height)   // enough real pixels for 128 smooth bins
                let small = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
                guard let cg = LumenGPU.context.createCGImage(small, from: small.extent, format: .RGBA8,
                                                              colorSpace: LumenGPU.displaySpace) else { return }
                var h = Histogram.compute(cg)
                if let hdrImg, h != nil { Histogram.addHDR(&h!, hdrImg, stops: stops, screenStops: screenStops) }
                Task { @MainActor [weak self] in self?.histogram = h }
            }
        }
    }

    @Published var lensBlurPicking = false
    private var lensBlurEditing = false

    func setLensBlurEditing(_ editing: Bool) {
        lensBlurEditing = editing
        if editing { prepareAutoMasksIfNeeded() }
    }

    func pickLensFocus(at p: Pt) {
        guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1,
              let distance = source?.depthField?.value(atNormalized: p.x, p.y) else { return }
        lastChange = .distantPast
        var s = settings
        s.lensBlur.focusDistance = Double(distance)
        // A focus change starts a fresh automatic range; existing brush refinements remain available in Masks.
        s.lensBlur.maskID = nil
        settings = s
        lensBlurPicking = false
        if DemoMode.isOn { DemoMode.log("lens focus picked") }
    }

    func refineLensBlur() {
        if let id = settings.lensBlur.maskID, settings.masks.contains(where: { $0.id == id }) {
            selectMask(id); maskTab = .shape; return
        }
        var m = Mask.make(.depth)
        m.name = "Lens Blur background"
        m.components[0].lumLow = min(settings.lensBlur.focusDistance + settings.lensBlur.focusWidth, 1)
        m.components[0].lumHigh = 1
        m.components[0].lumLowFeather = settings.lensBlur.focusWidth
        m.components[0].lumHighFeather = 0
        lastChange = .distantPast
        var s = settings
        s.masks.append(m)
        s.lensBlur.maskID = m.id
        settings = s
        selectMask(m.id); maskTab = .shape
    }

    private func prepareAutoMasksIfNeeded() {
        guard let session, let source, !autoMaskBusy else { return }
        let needs = lensBlurEditing || settings.lensBlur.amount > 0 || settings.masks.contains { m in m.components.contains { $0.kind.needsAnalysis } }
        guard needs else { return }
        let askedBlur = settings.lensBlur
        var snapshot = settings
        if lensBlurEditing { snapshot.lensBlur.amount = max(snapshot.lensBlur.amount, 1) }
        let analysisSettings = snapshot
        autoMaskBusy = true
        let slow = DemoMode.value("-lumenDemoSlowAI") != nil   // CI: time to see the busy notice
        workQueue.async {
            if slow { Thread.sleep(forTimeInterval: 4) }
            session.prepareAutoMasks(analysisSettings, source: source)
            let missing: Set<String> = Set([EditSession.aiSubject, EditSession.aiSky, EditSession.aiPeople, EditSession.aiDepth, EditSession.aiScene].filter { source.hasTried($0) && source.cachedMask($0) == nil })
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.autoMaskBusy = false
                self.autoMaskMissing = missing
                self.syncDetailMasks()
                self.requestRender()
                // masks may have changed while we were busy
                if self.settings.masks != analysisSettings.masks || self.settings.lensBlur != askedBlur { self.prepareAutoMasksIfNeeded() }
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

    func reset() { lastChange = .distantPast; settings = EditSettings() }

    func auto() {
        guard let session, let source else { return }
        settings = session.autoSettings(source: source, current: settings)
    }

    /// What Auto changed, so the Auto button can show it is on and a second tap can take it back.
    struct AutoRecord { var before: EditSettings; var after: EditSettings }
    @Published private(set) var autoRecord: AutoRecord?

    private static func autoFields(_ s: EditSettings) -> [Double] {
        [s.exposure, s.contrast, s.highlights, s.shadows, s.whites, s.blacks, s.vibrance, s.clarity]
    }

    /// On while the values Auto set are untouched; moving any of them yourself turns it off.
    var autoActive: Bool {
        guard let r = autoRecord else { return false }
        return Self.autoFields(settings) == Self.autoFields(r.after)
    }

    /// Auto button: apply Auto, or (when it is on) put back the values from before it.
    func toggleAuto() {
        lastChange = .distantPast
        if autoActive, let r = autoRecord {
            var s = settings
            let b = r.before
            s.exposure = b.exposure; s.contrast = b.contrast; s.highlights = b.highlights; s.shadows = b.shadows
            s.whites = b.whites; s.blacks = b.blacks; s.vibrance = b.vibrance; s.clarity = b.clarity
            autoRecord = nil
            settings = s
        } else {
            let before = settings
            auto()
            autoRecord = AutoRecord(before: before, after: settings)
        }
    }

    // MARK: White balance picker

    /// Color tool: while on, a tap on the photo sets Temp and Tint so that spot becomes neutral grey.
    @Published var wbPicking = false

    func pickWhiteBalance(at p: Pt) {
        guard let source else { return }
        let rgb = source.stats.average(atNormalized: p.x, p.y, radius: 2)
        let r = Double(max(rgb.x, 1e-5)), g = Double(max(rgb.y, 1e-5)), b = Double(max(rgb.z, 1e-5))
        // the develop kernel multiplies by (2^(0.6t), 2^(-0.4n), 2^(-0.6t)) with t = temp/100, n = tint/100:
        // solve for the t and n that make this spot's red, green and blue equal
        let t = log2(b / r) / 1.2
        let n = -log2(r * exp2(0.6 * t) / g) / 0.4
        var s = settings
        s.temperature = (min(max(t * 100, -100), 100)).rounded()
        s.tint = (min(max(n * 100, -100), 100)).rounded()
        settings = s
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if DemoMode.isOn { DemoMode.log("wb picked temp \(Int(s.temperature)) tint \(Int(s.tint))") }
    }

    // MARK: Presets

    func apply(preset edits: EditSettings) {
        lastChange = .distantPast
        var s = edits
        s.masks = settings.masks
        s.heals = settings.heals
        s.lensBlur = settings.lensBlur
        s.take(.crop, from: settings)
        s.hdr = settings.hdr; s.hdrStops = settings.hdrStops
        s.disabled = settings.disabled
        if s.temperature == 0 && s.tint == 0 {
            s.temperature = settings.temperature
            s.tint = settings.tint
        }
        let before = settings
        settings = s
        presetRecord = PresetRecord(before: before, after: s)
        presetAmount = 100
    }

    // MARK: Preset strength

    /// The last preset applied: the Strength slider mixes between the edits before it and the preset's.
    struct PresetRecord { var before: EditSettings; var after: EditSettings }
    @Published private(set) var presetRecord: PresetRecord?
    @Published private(set) var presetAmount: Double = 100

    /// The Strength slider shows while the photo still holds the preset at the current strength.
    var presetStrengthAvailable: Bool {
        guard let r = presetRecord else { return false }
        return settings == EditSettings.blend(r.before, r.after, presetAmount / 100)
    }

    func setPresetAmount(_ v: Double) {
        guard let r = presetRecord else { return }
        presetAmount = min(max(v, 0), 100)
        settings = EditSettings.blend(r.before, r.after, presetAmount / 100)
    }

    // MARK: Heal

    /// The stroke being painted with Heal (photo-normalised points), shown on the photo until the AI is done.
    @Published var healStroke: [Pt] = []
    /// Heal brush diameter, a fraction of the photo's long edge.
    @Published var healSize = 0.03
    @Published private(set) var healBusy = false
    @Published var healMessage: String?
    @Published var selectedHealID: UUID?
    /// What the busy badge on the photo says.
    @Published private(set) var healBusyText = "Removing…"
    fileprivate var healWaitingForReload = false

    func healBegin(_ p: Pt) { guard !healBusy else { return }; selectedHealID = nil; healMessage = nil; healStroke = [p] }
    func healExtend(_ p: Pt) {
        guard !healBusy, !healStroke.isEmpty else { return }
        if let last = healStroke.last, hypot(last.x - p.x, last.y - p.y) < 0.002 { return }
        healStroke.append(p)
    }
    /// A pinch started: the first finger was not a stroke.
    func healCancel() { if !healBusy { healStroke = [] } }

    /// Finger lifted: rebuild what was painted over.
    func healEnd() {
        guard !healBusy, !healStroke.isEmpty, let session else { if !healBusy { healStroke = [] }; return }
        guard EditSession.hasHealModel else {
            healStroke = []
            healMessage = "Heal isn't available in this build."
            return
        }
        let stroke = BrushStroke(points: healStroke, size: healSize, erase: false, feather: nil)
        let earlier = settings.effective.heals
        healBusy = true
        healBusyText = "Removing…"
        workQueue.async {
            let spot = session.makeHeal(strokes: [stroke], earlier: earlier)
            let why = EditSession.healFailure ?? .failed
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let spot else {
                    self.healBusy = false
                    self.healStroke = []
                    self.healMessage = why.message
                    return
                }
                // keep the painted stroke up until the photo is decoded again with the fix
                self.healWaitingForReload = true
                if !self.settings.isOn(.heal) { self.settings.setOn(.heal, true) }
                self.settings.heals.append(spot)
            }
        }
    }

    /// Keeps a heal-free preview while the photo has heals (built in the background, dropped when there are none).
    func refreshUnhealed() {
        let heals = settings.effective.heals
        guard !heals.isEmpty, let session else { unhealedSource = nil; return }
        // the photo without heals doesn't change when heals do, only when HDR changes how it is decoded
        if unhealedSource != nil && unhealedHDR == settings.hdr { return }
        unhealedSource = nil
        let hdr = settings.hdr
        let generation = loadGeneration
        workQueue.async {
            let src = session.makeSource(maxEdge: 2560, materialize: true, heals: [])
            Task { @MainActor [weak self] in
                guard let self, generation == self.loadGeneration, let src, src.size == self.source?.size else { return }
                guard hdr == self.settings.hdr else { return }
                self.unhealedSource = src
                self.unhealedHDR = hdr
                if self.showOriginal || self.splitCompare { self.requestRender() }
            }
        }
    }

    // MARK: Remove people

    /// The people found by Remove people. While set, the photo shows them (red = will be removed) and a tap on one
    /// picks or keeps them.
    @Published private(set) var peopleFound: [FoundPerson]?
    @Published private(set) var peopleChosen: Set<Int> = []
    /// Bumped by Cancel (or leaving Heal) so a search still running is ignored when it finishes.
    private var peopleSearch = 0

    func findPeople() {
        guard !healBusy, let session else { return }
        selectedHealID = nil
        healMessage = nil
        // CI: `-lumenDemoPeople` = three made-up people (the simulator has no Vision speed and no heal model)
        let demo = DemoMode.value("-lumenDemoPeople") != nil ? Self.demoPeople() : nil
        guard demo != nil || EditSession.hasHealModel else { healMessage = HealFailure.notAvailable.message; return }
        let earlier = settings.effective.heals
        healBusy = true
        healBusyText = "Finding people…"
        peopleSearch += 1
        let search = peopleSearch
        workQueue.async {
            let people = demo ?? session.findPeople(earlier: earlier)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.healBusy = false
                guard search == self.peopleSearch else { return }
                guard !people.isEmpty else { self.healMessage = "No people found in this photo."; return }
                self.peopleFound = people
                // everyone but who the photo is of
                self.peopleChosen = Set(people.filter { !$0.main }.map(\.id))
                self.requestRender()
            }
        }
    }

    /// Three made-up people for CI: one big (who the photo is of) and two small ones.
    private static func demoPeople() -> [FoundPerson] {
        let w = 300, h = 400
        var px = [UInt8](repeating: 0, count: w * h)
        for (x0, y0, x1, y1) in [(100, 120, 180, 380), (225, 250, 250, 310), (30, 260, 48, 305)] {
            for y in y0..<y1 { for x in x0..<x1 { px[y * w + x] = 255 } }
        }
        return EditSession.splitPeople(px, width: w, height: h)
    }

    /// A tap on the photo while picking: the smallest person whose box (a little wider) holds the point.
    func togglePerson(at p: Pt) {
        guard !healBusy, let people = peopleFound else { return }
        let pad = 0.015
        let hit = people.filter { $0.box.insetBy(dx: -pad, dy: -pad).contains(CGPoint(x: p.x, y: p.y)) }
            .min { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
        if let hit { togglePerson(hit.id) }
    }

    func togglePerson(_ id: Int) {
        guard !healBusy else { return }
        if peopleChosen.contains(id) { peopleChosen.remove(id) } else { peopleChosen.insert(id) }
        requestRender()
    }

    func chooseAllPeople(_ all: Bool) {
        guard !healBusy, let people = peopleFound else { return }
        peopleChosen = all ? Set(people.map(\.id)) : []
        requestRender()
    }

    func cancelPeople() {
        peopleSearch += 1
        guard peopleFound != nil else { return }
        peopleFound = nil
        peopleChosen = []
        requestRender()
    }

    /// Removes the people picked, one heal each (each built on the ones before), all added as one undo step.
    func removeChosenPeople() {
        guard !healBusy, let session, let people = peopleFound else { return }
        let chosen = people.filter { peopleChosen.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let earlier = settings.effective.heals
        healBusy = true
        healBusyText = chosen.count == 1 ? "Removing…" : "Removing 1 of \(chosen.count)…"
        workQueue.async {
            var made: [HealSpot] = []
            var failures: [HealFailure] = []
            for (i, person) in chosen.enumerated() {
                if i > 0 {
                    let text = "Removing \(i + 1) of \(chosen.count)…"
                    Task { @MainActor [weak self] in self?.healBusyText = text }
                }
                if let spot = session.makeHeal(person: person, earlier: earlier + made) {
                    made.append(spot)
                } else {
                    failures.append(EditSession.healFailure ?? .failed)
                }
            }
            let done = made, failed = failures
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.peopleFound = nil
                self.peopleChosen = []
                if let first = failed.first {
                    self.healMessage = done.isEmpty ? first.message
                        : "\(failed.count) of \(chosen.count) couldn't be removed. Paint over what's left to try again."
                }
                guard !done.isEmpty else { self.healBusy = false; self.requestRender(); return }
                // the busy badge stays until the photo is decoded again with the fixes
                self.healWaitingForReload = true
                if !self.settings.isOn(.heal) { self.settings.setOn(.heal, true) }
                self.settings.heals.append(contentsOf: done)
            }
        }
    }

    func deleteHeal(_ id: UUID) {
        settings.heals.removeAll { $0.id == id }
        if selectedHealID == id { selectedHealID = nil }
    }

    // MARK: Paste some edits

    /// Pastes only the chosen tools from the copied edits.
    func paste(_ sections: Set<EditSection>, from c: EditSettings) {
        lastChange = .distantPast
        var s = settings
        for sec in EditSection.allCases where sections.contains(sec) && sec.canPaste { s.take(sec, from: c) }
        settings = s
    }

    // MARK: Auto-level

    @Published private(set) var levelling = false

    /// Straightens the photo along the horizon Apple's on-phone detection finds.
    func autoLevel() {
        guard let session, let source, !levelling else { return }
        levelling = true
        let turns = settings.quarterTurns
        workQueue.async {
            let a = session.levelAngle(source, quarterTurns: turns)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.levelling = false
                if let a {
                    self.settings.straighten = a
                    if DemoMode.isOn { DemoMode.log("auto level \(a)") }
                } else {
                    self.message = "Couldn't find a horizon to level in this photo."
                    if DemoMode.isOn { DemoMode.log("auto level none") }
                }
            }
        }
    }

    // MARK: Clipping warning and before / after

    /// Blown highlights show red and crushed shadows blue.
    @Published var clipWarning = false { didSet { requestRender() } }
    /// Before / after split: the original left of the line, the edit right of it.
    @Published var splitCompare = false { didSet { requestRender() } }
    /// Where the split line is, as a fraction of the photo's width.
    @Published var splitPos: CGFloat = 0.5 { didSet { requestRender() } }

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

    /// Why an AI mask part selects nothing on this photo (nil = it found something, is still looking, or isn't AI).
    func emptyReason(_ c: MaskComponent) -> String? {
        guard !autoMaskBusy else { return nil }
        let missing = autoMaskMissing
        switch c.kind {
        case .subject: return missing.contains(EditSession.aiSubject) ? "No subject found in this photo" : nil
        case .sky: return missing.contains(EditSession.aiSky) ? "No sky found in this photo" : nil
        case .people: return missing.contains(EditSession.aiPeople) ? "No people found in this photo" : nil
        case .depth:
            if !EditSession.hasDepthModel { return "Depth isn't available in this build" }
            return missing.contains(EditSession.aiDepth) ? "Couldn't measure depth in this photo" : nil
        case .landscape:
            if !EditSession.hasSceneModel { return "Landscape isn't available in this build" }
            guard let field = sceneField else {
                return missing.contains(EditSession.aiScene) ? "Couldn't read the scene in this photo" : nil
            }
            let parts = c.scene.compactMap(ScenePart.init(rawValue:))
            guard !parts.isEmpty, parts.allSatisfy({ !field.found.contains($0) }) else { return nil }
            let names = parts.map { $0.title.lowercased() }
            return "No \(ListFormatter.localizedString(byJoining: names)) found in this photo"
        default: return nil
        }
    }

    /// What the AI is still working out for `m`, shown on the photo so a tap on an automatic mask type never looks
    /// ignored (owner, 2026-10-12: Depth took a few seconds with nothing to see). nil when nothing is pending.
    func aiPending(_ m: Mask?) -> String? {
        guard autoMaskBusy, let m, let source else { return nil }
        for c in m.components {
            switch c.kind {
            case .subject, .background:
                if !source.hasTried(EditSession.aiSubject) { return "Finding the subject…" }
            case .sky:
                if !source.hasTried(EditSession.aiSky) { return "Finding the sky…" }
            case .people:
                if !source.hasTried(EditSession.aiPeople) { return "Finding people…" }
            case .depth:
                if EditSession.hasDepthModel, !source.hasTried(EditSession.aiDepth) { return "Measuring depth…" }
            case .landscape:
                if EditSession.hasSceneModel,
                   !source.hasTried(EditSession.aiScene) || (!c.scene.isEmpty && !source.hasTried(EditSession.sceneKey(c.scene))) {
                    return "Looking at the scene…"
                }
            default: break
            }
        }
        return nil
    }

    /// A whole mask selects nothing when every part it adds is empty (subtract / intersect parts can't add anything).
    func emptyReason(_ m: Mask) -> String? {
        let adds = m.components.filter { $0.op == .add }
        let reasons = adds.map(emptyReason)
        guard !adds.isEmpty, reasons.allSatisfy({ $0 != nil }) else { return nil }
        return reasons.first ?? nil
    }

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
        // the new stroke keeps today's Feather; older strokes keep the one they were painted with
        let stroke = BrushStroke(points: [p], size: brushSize, erase: brushErase, feather: c.feather)
        strokeStart = Date()
        strokeOpen = true
        updateComponent(c.id) { comp in
            for i in comp.strokes.indices where comp.strokes[i].feather == nil { comp.strokes[i].feather = comp.feather }
            comp.strokes.append(stroke)
        }
    }

    /// The finger that was painting lifted.
    func endStroke() { strokeOpen = false }

    /// A pinch starts with one finger down, which paints a stray dab: take it back.
    func cancelRecentStroke() {
        guard let c = selectedComponent, c.kind == .brush, let t = strokeStart, Date().timeIntervalSince(t) < 0.8,
              let last = c.strokes.last, last.points.count <= 4 else { return }
        strokeStart = nil
        // the finger is still down: it must not go on to extend the stroke before this one
        strokeOpen = false
        updateComponent(c.id) { _ = $0.strokes.popLast() }
    }

    func extendStroke(_ p: Pt) {
        guard strokeOpen, let c = selectedComponent, c.kind == .brush else { return }
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
        case .depth:
            // tap = select things at about that distance
            guard let d = source.depthField?.value(atNormalized: p.x, p.y) else { return }
            let v = Double(d)
            updateComponent(c.id) { comp in
                comp.lumLow = max(0, v - 0.08)
                comp.lumHigh = min(1, v + 0.08)
                comp.lumLowFeather = 0.08
                comp.lumHighFeather = 0.08
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
