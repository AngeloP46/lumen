import SwiftUI
import Photos
import CoreImage
import UniformTypeIdentifiers

private let histQueue = DispatchQueue(label: "lumen.hist", qos: .utility)
private let workQueue = DispatchQueue(label: "lumen.work", qos: .userInitiated)
// AI masks get their own queue: they are seconds of work, and while the previous photo's masks were being
// worked out the next photo's decode waited behind them on the serial work queue (phone 0.1.465: 5 s to
// "photo ready"; checklist A7). Memory coordination stays with HeavyWork, so the queue only changes time,
// never how much runs at once.
private let aiMaskQueue = DispatchQueue(label: "lumen.aimask", qos: .userInitiated)

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
    /// AI steps that failed (as against ran and found nothing): the banner says so and offers "Try again" (A18).
    @Published private(set) var autoMaskFailed: Set<String> = []

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
    // Captured by the pending save: late heal results must survive the editor itself being released.
    private final class SaveState {
        var revision = 0
        var saved = 0
    }
    private let saveState = SaveState()

    // Undo / redo
    private var undoStack: [EditSettings] = []
    /// The saved undo history has been read (it loads in the background when the photo opens).
    private var historyLoaded = false
    private var redoStack: [EditSettings] = []
    private var applyingHistory = false
    private var lastChange = Date.distantPast
    var canUndo: Bool { !undoStack.isEmpty && !healBusy }
    var canRedo: Bool { !redoStack.isEmpty && !healBusy }

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
    /// The masks the Masks tool lists: Lens Blur's linked background mask belongs to Lens Blur, not here.
    var userMasks: [Mask] { settings.masks.filter { $0.id != settings.lensBlur.maskID } }
    var selectedComponent: MaskComponent? {
        guard let m = selectedMask else { return nil }
        return m.components.first { $0.id == selectedComponentID } ?? m.components.first
    }
    var overlayVisible: Bool {
        maskEditing && !showOriginal && selectedMask != nil && ((maskTab == .shape && overlayEnabled) || peekOverlay)
    }

    // MARK: Loading

    nonisolated(unsafe) private var memoryWarning: NSObjectProtocol?
    nonisolated(unsafe) private var lifecycleObservers: [NSObjectProtocol] = []
    /// True while the saved edits are being put on screen: that is not a change, so it isn't saved again (before
    /// 22 Oct opening a photo saved it 0.5 s later, writing back whatever this version could read: checklist A1).
    private var loadingSettings = false
    deinit {
        if let o = memoryWarning { NotificationCenter.default.removeObserver(o) }
        // every observer goes with the editor (two were left behind per photo opened: checklist A11)
        for o in denoiseObservers + lifecycleObservers { NotificationCenter.default.removeObserver(o) }
        // tells "the closed editor's copies are still held" apart from other memory that stays (checklist A8)
        Diagnostics.shared.note("editor freed")
    }
    /// "photo ready" for diagnostics: how long it took (waiting for the work queue, then decoding) and what it holds.
    private func notePhotoReady(asked: Date, began: Date, size: CGSize, heals: Int, denoise: Double, hdr: Bool) {
        let total = Date().timeIntervalSince(asked), waited = began.timeIntervalSince(asked), decoded = Date().timeIntervalSince(began)
        let times = String(format: "photo ready in %.1f s (waited %.1f s, decoded %.1f s; ", total, waited, decoded)
        let mp = Int(size.width * size.height / 1_000_000)
        let lens = Int(settings.effective.lensBlur.amount), masks = settings.masks.count
        Diagnostics.shared.note(times + "\(mp) MP, \(heals) heals, AI Denoise \(Int(denoise * 100)), Lens Blur \(lens), \(masks) masks, HDR \(hdr))")
    }

    /// When the photo was asked for (open → first frame, for diagnostics).
    private var openedAt: Date?
    /// On closing the photo: the library's thumbnail from the picture already decoded here (A13). It shows the AI masks that
    /// are worked out, and the photo is not decoded again (a 48 MP RAW decode for a thumbnail was ~2 GB at its peak).
    func updateLibraryThumbnail() {
        guard changedSinceOpen, let store else { return }
        guard let session, let source else { store.refreshThumbnail(item); return }
        let s = settings, item = item
        workQueue.async {
            guard let cg = session.renderThumbnail(s, source: source, maxEdge: 640) else {
                Task { @MainActor in store.refreshThumbnail(item) }
                return
            }
            Task { @MainActor in store.saveThumbnail(cg, for: item) }
        }
    }

    /// AI Denoise is on, but the cleaned copy is not on the phone (it is not in backups, an iOS update can retire it):
    /// say so once instead of quietly showing the photo without it (A16, B8).
    private var missingDenoiseNoted = false
    private func noteMissingDenoise() {
        guard !missingDenoiseNoted, settings.effective.aiDenoise > 0, let session, !session.hasDenoised,
              denoiseProgress == nil, !denoiseRequested, EditSession.hasDenoiseModel,
              DenoiseStore.pausedFraction(session.originalURL) == nil else { return }
        missingDenoiseNoted = true
        message = "AI Denoise is on, but this photo's cleaned copy is no longer on the phone. Tap AI Denoise in Detail to clean it again."
        Diagnostics.shared.note("AI Denoise is on but its cleaned copy is missing")
    }

    /// The edits the photo was opened with: the library's thumbnail is made again on closing only if they changed (a
    /// peek at a 48 MP photo used to decode it whole again, on top of everything else the editor had just freed).
    private var settingsAtOpen = EditSettings()
    var changedSinceOpen: Bool { settings != settingsAtOpen }

    /// The editor is closing: what this session's frames cost, and memory at that moment (checklist F, A8).
    func reportSession() {
        let f = canvas.frameStats()
        if f.count > 0 {
            let r = renderStats()
            Diagnostics.shared.note(String(format: "editor closed: %d frames, median %.0f ms, 95%% %.0f ms, slowest %.0f ms; building the picture median %.1f ms, 95%% %.1f ms",
                                           f.count, f.median, f.p95, f.max, r.median, r.p95))
        } else {
            Diagnostics.shared.note("editor closed")
        }
    }

    /// Time spent on the main thread building the picture in `requestRender` (milliseconds).
    private var renderTimes: [Double] = []
    private func renderStats() -> (median: Double, p95: Double) {
        let s = renderTimes.sorted()
        guard !s.isEmpty else { return (0, 0) }
        return (s[s.count / 2], s[min(s.count - 1, s.count * 95 / 100)])
    }

    func start(store: LibraryStore) {
        guard !started else { return }
        started = true
        self.store = store
        Diagnostics.shared.note("open photo \(item.displayName)")
        // iOS is short of memory: let go of everything that can be made again, before it closes the app
        memoryWarning = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            LumenGPU.context.clearCaches()
            EditSession.releaseMaskModels()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.maskMemo = [:]
                if self.denoiseProgress == nil { self.denoiseQueue.async { EditSession.releaseDenoiseModel() } }
                // The Heal model stays: it holds only ~150-300 MB once loaded, but loading it again is a 2-3 GB spike (owner's
                // phone, 23 Oct). Only when memory is truly critical does it go.
                if !self.healBusy && !self.healPreparing && Diagnostics.availableMB < 500 { EditSession.releaseHealModel() }
                // the 100 % copy goes even while zoomed in: a softer view is better than iOS closing Lumen
                if self.detailSource != nil { self.detailSource = nil; Diagnostics.shared.note("100% view: copy dropped (memory warning)") }
                // and no new try for a while: dropped, tried again at once, dropped again was how iOS closed Lumen (23 Oct)
                self.detailRetry.hold(for: 30)
                if !self.showOriginal { self.unhealedSource = nil }
                self.requestRender()
            }
        }
        applyingHistory = true
        var loaded = store.editorSettings(for: item)
        if DemoMode.isOn, DemoMode.value("-lumenDemoLegacyLens") != nil {
            loaded.lensBlur = LensBlurSettings(); loaded.lensBlur.activated = true
        }
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
        loadingSettings = true
        settings = loaded
        loadingSettings = false
        applyingHistory = false
        if let notice = store.takeLoadNotice(item) { message = notice }
        // a heal that finished after an earlier editor of this photo closed is added to the file by the store; this
        // editor read the file before that, so it takes the heals over (else its next save would overwrite them)
        lifecycleObservers.append(NotificationCenter.default.addObserver(forName: .lumenHealsAdded, object: nil, queue: .main) { [weak self] note in
            guard let self, note.userInfo?["photo"] as? UUID == self.item.id, let spots = note.userInfo?["spots"] as? [HealSpot] else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let known = Set(self.settings.heals.map(\.id))
                let fresh = spots.filter { !known.contains($0.id) }
                guard !fresh.isEmpty else { return }
                self.settings.heals.append(contentsOf: fresh)
                self.settings.setOn(.heal, true)
            }
        })
        // Lumen leaving the screen may be the last chance to write: the edit waiting its 0.5 s goes now (checklist A5)
        lifecycleObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.saveWork != nil else { return }
                self.flushSave()
            }
        })
        // undo history arrives a moment later (read in the background, not while the photo is opening); edits made
        // meanwhile go on top of it
        let opened = loaded
        settingsAtOpen = loaded
        store.loadHistory(for: item, current: opened) { [weak self] history in
            guard let self else { return }
            self.undoStack = Array((history.undo + self.undoStack).suffix(100))
            if self.settings == opened { self.redoStack = history.redo }
            self.historyLoaded = true
        }
        let url = store.fileURL(item)
        let wantsHDR = settings.hdr
        let heals = settings.effective.heals
        let denoise = settings.effective.aiDenoise / 100
        let asked = Date()
        openedAt = asked
        workQueue.async {
            let began = Date()
            // through the coordinator, like every other decode of the photo (it waits for a Heal model load)
            let made: (EditSession?, ImageSource?) = HeavyWork.shared.run(.preview, megapixels: 24) {
                let s = EditSession(url: url, expandHDR: wantsHDR)
                s?.heals = heals
                s?.denoiseAmount = denoise
                return (s, s?.makeSource(maxEdge: MemoryBudget.previewEdge, materialize: true))
            } ?? (nil, nil)
            let (s, src) = made
            // Simulator interaction fixture only; real builds always use estimated camera-photo depth.
            if DemoMode.isOn, DemoMode.value("-lumenDemoLensDepth") != nil, let src {
                let values = (0..<4096).map { Float($0 % 64) / 63 }
                let field = DepthField(width: 64, height: 64, values: values, histogram: Array(repeating: 1, count: 64))
                src.storeDepth(field)
                src.storeMask(EditSession.aiDepth, EditSession.depthImage(field, extent: src.extent))
                // Touch/layout checks use synthetic subject coverage too; they do not measure Vision quality.
                let e = src.extent
                let subject = EditSession.constant(1, CGRect(x: e.minX + e.width * 0.2, y: e.minY,
                                                            width: e.width * 0.2, height: e.height))
                    .composited(over: EditSession.constant(0, e))
                src.storeMask(EditSession.aiSubject, subject)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if DemoMode.isOn {
                    DemoMode.log(String(format: "loaded %@ queued %.1fs decoded %.1fs", url.lastPathComponent,
                                        began.timeIntervalSince(asked), Date().timeIntervalSince(began)))
                }
                self.session = s
                self.source = src
                self.maskMemo = [:]
                self.sourceHeals = heals.map(\.id)
                self.unhealedSource = nil   // belonged to the previous photo
                // what runs next is logged step by step (owner's phone, 21 Oct: a 48 MP ProRAW closed Lumen 2-4 s after
                // opening, with nothing in the log to say which step)
                self.notePhotoReady(asked: asked, began: began, size: s?.nativeSize ?? .zero, heals: heals.count, denoise: denoise, hdr: wantsHDR)
                self.isLoading = false
                self.loadFailed = (src == nil)
                if let src { self.imageSize = src.size; self.sourceSize = src.size }
                self.requestRender()
                self.prepareAutoMasksIfNeeded()
                if let s, let f = DenoiseStore.pausedFraction(s.originalURL), !s.hasDenoised {
                    if Diagnostics.shared.closedDuringLastRun {
                        self.message = String(format: "AI Denoise stopped at %.0f %% when iOS closed Lumen. Tap AI Denoise in Detail to carry on.", f * 100)
                    } else {
                        self.ensureDenoise(start: true)
                    }
                }
                self.ensureDenoise()
                self.noteMissingDenoise()
                self.warmDenoiseIfNeeded()
                self.refreshUnhealed()
                // HDR was switched while the photo was still loading: decode it again the other way
                if self.settings.hdr != wantsHDR { self.reloadSource() }
            }
        }
    }

    // MARK: AI Denoise

    /// 0...1 while the photo is being cleaned (Detail → AI Denoise), nil otherwise.
    @Published private(set) var denoiseProgress: Double?
    /// The cleaned copy for this photo (and HDR mode) exists: Detail shows the strength slider instead of the button.
    @Published private(set) var denoiseReady = false
    /// Seconds left, estimated from the tiles done so far (nil until there is enough to go on).
    @Published private(set) var denoiseSecondsLeft: Int?
    /// The button was tapped: the photo is cleaned now and AI Denoise set to 100 when done.
    private var denoiseRequested = false

    /// Detail → AI Denoise button: cleans the photo (locked screen with progress), then turns AI Denoise on.
    func startDenoise() {
        denoiseRequested = true
        ensureDenoise()
    }

    /// Cancel on the locked screen.
    func cancelDenoise() {
        denoiseRequested = false
        denoiseUserCancelled = true
        denoiseCancel = true
    }
    private var denoiseUserCancelled = false
    /// A clean was running when Lumen left the screen: it starts again on return.
    private var denoiseResume = false
    /// The strength AI Denoise had before the pill switched it off (the pill switches it back on at that strength).
    private var denoiseLastStrength: Double = 100

    private func refreshDenoiseReady() { denoiseReady = session?.hasDenoised ?? false }
    /// The photo's size in megapixels (the heavy-work coordinator's estimates scale with it).
    private var megapixels: Double { session.map { Double($0.nativeSize.width * $0.nativeSize.height) / 1_000_000 } ?? 24 }
    private var denoiseReload: DispatchWorkItem?
    private let denoiseQueue = DispatchQueue(label: "lumen.denoise", qos: .userInitiated)
    /// Set when the app leaves the screen: the running job stops at its next tile and starts again on return.
    nonisolated(unsafe) private var denoiseCancel = false
    /// Set when Lumen leaves the screen: the clean pauses at its next tile, keeping the rows so far.
    nonisolated(unsafe) private var denoisePausing = false
    /// The strength AI Denoise is set to when the clean it waits for finishes (pasted edits ask for theirs).
    private var denoiseTarget: Double?
    nonisolated(unsafe) private var denoiseObservers: [NSObjectProtocol] = []

    /// The slider moved: the first time the photo is cleaned (tens of seconds, with progress); after that only the mix
    /// changes, so the photo is decoded again once the slider rests.
    private func denoiseChanged() {
        guard let session else { return }
        if settings.effective.aiDenoise > 0, !session.hasDenoised { ensureDenoise(); return }
        denoiseReload?.cancel()
        let work = DispatchWorkItem { Task { @MainActor [weak self] in self?.reloadSource() } }
        denoiseReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Starts cleaning the photo when asked to (`start`, or the AI Denoise pill was tapped) and the cleaned copy for this
    /// HDR mode doesn't exist yet. Nothing else starts a clean (21 Oct review: switching HDR, undo, presets and pasted
    /// edits each started a locked one- to two-minute clean without warning); the pill shows unlit instead.
    func ensureDenoise(start: Bool = false) {
        if denoiseObservers.isEmpty {
            let nc = NotificationCenter.default
            denoiseObservers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.denoisePausing = true
                // nothing of AI Denoise stays loaded in the background; Detail makes it ready again on return. A clean
                // that was running starts again when Lumen is back on screen.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.denoiseProgress != nil { self.denoiseResume = true; return }
                    self.denoiseQueue.async { EditSession.releaseDenoiseModel() }
                }
            })
            denoiseObservers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.denoiseResume && self.denoiseProgress == nil { self.denoiseResume = false; self.ensureDenoise(start: true) }
                    if self.detailOpen { self.warmDenoiseIfNeeded() }
                }
            })
        }
        refreshDenoiseReady()
        guard denoiseProgress == nil, start || denoiseRequested, let session, !session.hasDenoised,
              EditSession.hasDenoiseModel, UIApplication.shared.applicationState != .background else { return }
        guard MemoryBudget.denoiseFits else {
            denoiseRequested = false
            message = "AI Denoise needs more memory than this iPhone gives an app (iPhones with 6 GB or more). Noise reduction in Detail still works."
            Diagnostics.shared.note("denoise not started: \(MemoryBudget.summary)")
            return
        }
        // the AI masks, the 100 % copy and the original copy are made one at a time with a clean, not together
        // (each is hundreds of MB on a 48 MP photo): a clean asked for while the masks are being worked out waits
        if autoMaskBusy { denoiseRequested = true; return }
        if let batch = store?.denoiseBatch {
            denoiseRequested = false
            message = "AI Denoise is busy with \(batch.count - batch.done) photo\(batch.count - batch.done == 1 ? "" : "s") from the library. Try again when they're done."
            return
        }
        denoiseResume = false
        denoisePausing = false
        denoiseProgress = 0
        denoiseSecondsLeft = nil
        denoiseCancel = false
        denoiseUserCancelled = false
        UIApplication.shared.isIdleTimerDisabled = true   // a long clean must not stop when the screen dims
        freeMemoryForHeal()
        // the mask models load again when needed (masks already worked out are kept)
        EditSession.releaseMaskModels()
        // draw from the preview now, so the screen lets go of the 100 % copy before the clean asks for room
        requestRender()
        let from = DenoiseStore.pausedFraction(session.originalURL) ?? 0
        Diagnostics.shared.note(from > 0 ? String(format: "denoise continues from %.0f %%", from * 100) : "denoise start")
        let began = Date()
        let mp = megapixels
        denoiseQueue.async {
            var noted = 0
            let outcome = HeavyWork.shared.run(.denoise, megapixels: mp, long: true) { session.makeDenoised(progress: { p in
                // the phone's real speed, for ⋯ → Send diagnostics
                let quarter = Int(p * 4)
                if quarter > noted, quarter < 4 {
                    noted = quarter
                    Diagnostics.shared.note("denoise \(quarter * 25)% after \(Int(Date().timeIntervalSince(began))) s")
                }
                // time left from this run's own pace (a continued clean starts part way)
                let elapsed = Date().timeIntervalSince(began)
                let left: Int? = p - from >= 0.05 ? Int((elapsed / (p - from) * (1 - p)).rounded()) : nil
                Task { @MainActor [weak self] in
                    guard let self, self.denoiseProgress != nil else { return }
                    self.denoiseProgress = p
                    self.denoiseSecondsLeft = left
                }
            }, pause: { [weak self] in self?.denoisePausing ?? true },
               cancelled: { [weak self] in self?.denoiseCancel ?? true }, log: { Diagnostics.shared.note($0) }) } ?? .failed
            let ok = outcome == .done, stopped = outcome == .paused || outcome == .cancelled
            LumenGPU.context.clearCaches()
            Diagnostics.shared.note(ok ? "denoise done in \(Int(Date().timeIntervalSince(began))) s: \(EditSession.denoiseTimings)"
                                    : outcome == .paused ? "denoise paused (Lumen left the screen): it carries on from here"
                                    : outcome == .cancelled ? "denoise cancelled" : "denoise failed")
            Task { @MainActor [weak self] in
                // the model is let go of straight after a clean (owner's phone, 0.1.394: keeping it while Detail was
                // open held ~600 MB, and iOS closed Lumen when it came back to the screen)
                EditSession.releaseDenoiseModel()
                UIApplication.shared.isIdleTimerDisabled = false   // even if the editor has gone
                // where memory settles after a clean (0.1.533: ~1 GB stayed in use with the model gone, then a Lens Blur
                // redraw or the Heal model on top went past the limit)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    Diagnostics.shared.note("4 s after AI Denoise ended: memory has settled")
                }
                guard let self else { return }
                self.denoiseProgress = nil
                self.denoiseSecondsLeft = nil
                self.refreshDenoiseReady()
                // back on screen before the stopped clean got to its next tile: start it again now
                if stopped && self.denoiseResume && UIApplication.shared.applicationState == .active {
                    self.denoiseResume = false
                    self.ensureDenoise(start: true)
                    return
                }
                // the photo was decoded again meanwhile (before the cleaned copy existed): decode it again with it
                guard self.session === session else { if ok { self.reloadSource() }; return }
                if !ok { self.prepareAutoMasksIfNeeded(); self.refreshUnhealed() }
                if ok {
                    let target = self.denoiseTarget ?? 100
                    self.denoiseTarget = nil
                    if self.denoiseRequested && self.settings.aiDenoise != target {
                        self.denoiseRequested = false
                        self.settings.aiDenoise = target   // an undo step; decoding again follows from the change
                    } else {
                        self.denoiseRequested = false
                        self.reloadSource()
                    }
                } else if !stopped {
                    self.denoiseRequested = false
                    self.message = "AI Denoise couldn't clean this photo."
                } else if self.denoiseUserCancelled {
                    self.denoiseRequested = false
                }
            }
        }
    }

    /// Detail is the open tool and the photo isn't cleaned yet: the model is made ready in the background (load + GPU
    /// setup, ~20 s the first time on the owner's phone), so tapping AI Denoise starts cleaning at once. Let go of 30 s
    /// after leaving Detail, straight after a clean, in the background and on a memory warning.
    private(set) var detailOpen = false
    private var denoiseRelease: Task<Void, Never>?
    private var denoiseWarming = false
    func detailToolChanged(open: Bool, now: Bool = false) {
        detailOpen = open
        denoiseRelease?.cancel(); denoiseRelease = nil
        if open { warmDenoiseIfNeeded(); return }
        denoiseRelease = Task { @MainActor [weak self] in
            if !now { try? await Task.sleep(nanoseconds: 30_000_000_000) }
            guard !Task.isCancelled, let self, !self.detailOpen, self.denoiseProgress == nil else { return }
            self.denoiseQueue.async { EditSession.releaseDenoiseModel() }
        }
    }

    private func warmDenoiseIfNeeded() {
        refreshDenoiseReady()
        guard MemoryBudget.denoiseFits, detailOpen, !denoiseReady, !denoiseWarming, denoiseProgress == nil, store?.denoiseBatch == nil, EditSession.hasDenoiseModel,
              Diagnostics.availableMB > 1500, UIApplication.shared.applicationState != .background else { return }
        denoiseWarming = true
        denoiseQueue.async {
            let s = EditSession.warmDenoise()
            if s > 0.5 { Diagnostics.shared.note(String(format: "denoise model made ready in %.1f s (Detail open)", s)) }
            Task { @MainActor [weak self] in self?.denoiseWarming = false }
        }
    }

    /// Detail's AI Denoise pill: cleans the photo the first time; afterwards switches AI Denoise between off and full
    /// (instant, the cleaned copy is kept), like Light's Auto.
    func toggleDenoise() {
        if !denoiseReady { startDenoise(); return }
        if settings.aiDenoise > 0 { denoiseLastStrength = settings.aiDenoise; settings.aiDenoise = 0 }
        else { settings.aiDenoise = denoiseLastStrength }
    }

    /// The heals the current preview source was decoded with.
    private var sourceHeals: [UUID] = []

    /// HDR on or off changes how the file is decoded (RAW: more highlight range; gain-map JPEG/HEIC: the HDR version),
    /// and heals are painted in while decoding, so decode it again. Automatic masks already found are kept only when
    /// the heals are the same: after a heal, depth, subject, sky and the rest are worked out again from the healed
    /// photo. (Before 19 Oct they were kept, so Lens Blur still saw a removed person as near and left a sharp,
    /// person-shaped hole in the blur: owner's screenshot.)
    /// One decode at a time, and only the newest settings (A23): see `SingleFlight`.
    private var reloadFlight = SingleFlight()

    private func reloadSource() {
        guard store != nil, session != nil else { return }
        loadGeneration += 1   // whatever is running now shows old settings
        if reloadFlight.request() { startReload() }
    }

    private func startReload() {
        guard let store, session != nil else { reloadFlight = SingleFlight(); return }
        let generation = loadGeneration
        let url = store.fileURL(item)
        let wantsHDR = settings.hdr
        let heals = settings.effective.heals
        let denoise = settings.effective.aiDenoise / 100
        let previous = source
        let sameHeals = heals.map(\.id) == sourceHeals || DemoMode.value("-lumenDemoLensDepth") != nil
        let mp = megapixels
        // every decode is in the log with the memory it ran at: 23 Oct, the 48 MP photo's memory went 1.4 → 2.8 → 3.1 GB in
        // the seconds after a clean and nothing said which step it was
        BlackBox.shared.crumb("preview decode")
        Diagnostics.shared.note("preview decode: start (HDR \(wantsHDR), heals \(heals.count), AI Denoise \(Int(denoise * 100)))")
        let reloadBegan = Date()
        workQueue.async {
            // through the coordinator: it waits for a Heal model load or another heavy job instead of piling on top of it
            let made: (EditSession?, ImageSource?) = HeavyWork.shared.run(.preview, megapixels: mp) {
                let s = EditSession(url: url, expandHDR: wantsHDR)
                s?.heals = heals
                s?.denoiseAmount = denoise
                return (s, s?.makeSource(maxEdge: MemoryBudget.previewEdge, materialize: true))
            } ?? (nil, nil)
            let (s, src) = made
            Diagnostics.shared.note(String(format: "preview decode: done in %.1f s", Date().timeIntervalSince(reloadBegan)))
            Task { @MainActor [weak self] in
                guard let self else { return }
                // asked again meanwhile (undo, redo, HDR, a heal): this one shows old settings and is dropped; the
                // decode that follows is of the settings as they are now
                let again = self.reloadFlight.finish()
                defer { if again { self.startReload() } }
                guard generation == self.loadGeneration else { return }
                guard let s, let src else {
                    // couldn't decode it again (short of memory): never leave Heal stuck on "Removing…"
                    if self.healBusy && self.healWaitingForReload {
                        self.healBusy = false; self.healStroke = []; self.healWaitingForReload = false
                        self.healMessage = "Couldn't show the fix. Close other apps and try again."
                    }
                    Diagnostics.shared.note("reload failed")
                    return
                }
                // AI masks for the heals the photo had before are kept, so undo / redo of a heal or a person removed
                // brings its masks back instead of working them all out again (diagnostics 22 Oct: eight full
                // subject + scene + depth runs in 12 s while undoing and redoing)
                if let previous { self.memoMasks(of: previous, heals: self.sourceHeals) }
                if let memo = self.maskMemo[heals.map(\.id)], memo.size == src.size {
                    for key in memo.tried { src.storeMask(key, memo.masks[key]) }
                    src.storeDepth(memo.depth)
                    src.storeScene(memo.scene)
                    if !sameHeals { Diagnostics.shared.note("AI masks: kept from before (undo/redo)") }
                }
                self.session = s
                self.source = src
                self.sourceHeals = heals.map(\.id)
                self.sourceSize = src.size
                self.detailSource = nil
                if DemoMode.isOn { DemoMode.log("reloaded hdr \(wantsHDR)") }
                self.requestRender()
                self.prepareAutoMasksIfNeeded()
                self.ensureDenoise()
                self.refreshUnhealed()
                if self.zoomLevel > 1.4 {
                    // not at once: a decode after every pause of the AI Denoise slider, each followed by a 2 GB copy, is what
                    // B5 describes; the copy is made once the changes have stopped
                    self.detailRetry.hold(for: 2)
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 2_100_000_000)
                        if let self, self.zoomLevel > 1.4, self.detailSource == nil { self.buildDetail() }
                    }
                }
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
        if !loadingSettings { scheduleSave() }
        requestRender()
        if settings.masks != old.masks || settings.lensBlur != old.lensBlur { prepareAutoMasksIfNeeded() }
        // HDR changes how the file is decoded; heals are painted in while decoding
        if settings.hdr != old.hdr || settings.effective.heals != old.effective.heals { reloadSource() }
        else if settings.effective.aiDenoise != old.effective.aiDenoise { denoiseChanged() }
    }

    private func scheduleSave() {
        saveState.revision += 1
        let revision = saveState.revision, state = saveState
        saveWork?.cancel()
        let s = settings, item = item
        // before the saved history has arrived, let the store add this step to the file's own history (writing ours
        // would drop the older steps)
        let history: LibraryStore.EditHistory? = historyLoaded ? LibraryStore.EditHistory(current: s, undo: undoStack, redo: redoStack) : nil
        let work = DispatchWorkItem { [weak store] in
            Task { @MainActor in
                guard let store, state.revision == revision, state.saved < revision else { return }
                store.save(s, for: item, history: history)
                state.saved = revision // the store owns retries after a failed write
            }
        }
        saveWork = work
        // CI: `-lumenDemoSaveDelay <s>` makes the wait long enough for a test to leave the app inside it
        let delay = DemoMode.value("-lumenDemoSaveDelay").flatMap(Double.init) ?? 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        if saveState.saved < saveState.revision {
            store?.save(settings, for: item, history: historyLoaded ? LibraryStore.EditHistory(current: settings, undo: undoStack, redo: redoStack) : nil)
            saveState.saved = saveState.revision
        }
        store?.flushHistory()
    }

    // MARK: Rendering

    /// Rebuilds the (lazy) graph and hands it to the Metal view. Cheap enough to call on every slider tick.
    func requestRender() {
        guard let session, let source else { return }
        BlackBox.shared.crumb("render")
        let buildStart = CACurrentMediaTime()
        defer { if renderTimes.count < 5000 { renderTimes.append((CACurrentMediaTime() - buildStart) * 1000) } }
        if let opened = openedAt {
            openedAt = nil
            canvas.onFirstFrame = { Diagnostics.shared.note(String(format: "first frame drawn %.1f s after opening", Date().timeIntervalSince(opened))) }
        }
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
        // Lens Blur is heavy: half resolution while its sliders move, full again on release (crash on fast drags, 15 Oct)
        let lensLive = lensSliderActive || lensDragging
        var img = session.develop(s, source: active, geometry: !skipGeometry, applyCrop: applyCrop, hdrWeight: hdrWeight,
                                  lens: lensLive ? .preview : .full)
        // the histogram always reads the small SDR preview, even while the 100% view is showing; without Lens Blur
        // (it barely moves the tones and would double or triple the GPU work on every change)
        let lensInPicture = s.effective.lensBlur.amount > 0
        let base = (useDetail || hdrWeight > 0 || lensInPicture)
            ? session.develop(s, source: source, geometry: !skipGeometry, applyCrop: applyCrop, lens: .off) : img
        // in HDR the histogram shows everything the photo holds above white, also what the screen can't show now
        let hdrImg: CIImage? = s.hdr ? session.develop(s, source: source, geometry: !skipGeometry, applyCrop: applyCrop, hdrWeight: 1, lens: .off) : nil
        if overlayVisible, let m = selectedMask {
            let shown = img.extent
            img = session.overlay(img, mask: m, source: active, gain: exp2(s.exposure), settings: s, applyCrop: applyCrop)
                .cropped(to: shown)
        }
        if lensBlurEditing && ((lensSliderActive && lensPreviewEnabled) || lensSelectionPreview) && !showOriginal {
            var preview = s
            preview.lensBlur.amount = max(preview.lensBlur.amount, 1)
            if let selection = session.lensBlurMask(preview, source: active), let kernel = LumenKernels.shared?.overlay {
                let shown = session.geometry(selection, s, applyCrop: applyCrop)
                img = kernel.apply(extent: img.extent, arguments: [img, shown, CIVector(x: 1, y: 0.1, z: 0.12, w: 0.55)]) ?? img
            }
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

    private var detailSkipNoted = false
    /// A try that found no room, or a copy dropped on a memory warning, is not repeated for a while: zooming asks on
    /// every pinch step, and 13 builds in a minute (about 2.1 GB each) is how iOS closed Lumen twice (23 Oct, A21).
    private var detailRetry = RetryGate()
    private var detailRechecking = false

    /// Zooming in asks for the 100 % view, so what can be made again goes first: the original copy, the mask and Heal
    /// models and the GPU caches (a few hundred MB to a gigabyte after a heal or the AI masks).
    fileprivate func freeMemoryForDetail() {
        unhealedSource = nil
        LumenGPU.context.clearCaches()
        EditSession.releaseMaskModels()
        if denoiseProgress == nil { denoiseQueue.async { EditSession.releaseDenoiseModel() } }
    }

    private func buildDetail(afterRelease: Bool = false) {
        // not while AI Denoise is cleaning the full-size photo: both together are too much memory (diagnostics 20 Oct)
        guard let session, let source, !detailBuilding, denoiseProgress == nil, detailRetry.allows() else { return }
        let native = max(session.nativeSize.width, session.nativeSize.height)
        // The copy needs ~2.1 GB at its peak on a 24 MP photo (owner's phone, 23 Oct; 48 MP: 2.6 GB, 21 Oct): mostly the
        // RAW engine's decode, whatever the copy's size. It is built only with that much free AND the safety margin
        // beside it; with less room the preview stays, a little softer, instead of iOS closing the app.
        let megapixels = session.nativeSize.width * session.nativeSize.height / 1_000_000
        var left = Diagnostics.availableMB
        let enough = DetailCopy.needMB(megapixels: Double(megapixels)) + HeavyWork.marginMB
        if left < enough, native > source.longEdge * 1.15 {
            freeMemoryForDetail()
            if !afterRelease {
                // what was let go of takes a moment to come back: look again, once
                if !detailRechecking {
                    detailRechecking = true
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard let self else { return }
                        self.detailRechecking = false
                        if self.zoomLevel > 1.4, self.detailSource == nil { self.buildDetail(afterRelease: true) }
                    }
                }
                return
            }
            left = Diagnostics.availableMB
        }
        let edge = CGFloat(DetailCopy.edge(freeMB: left, megapixels: Double(megapixels), native: Double(native),
                                           highTier: MemoryBudget.tier == .high, marginMB: HeavyWork.marginMB))
        guard edge > source.longEdge * 1.15 else {
            // zoom fires this on every pinch step: note it once, and don't ask again for a while
            if native > source.longEdge * 1.15 {
                detailRetry.hold(for: 12)
                if DemoMode.isOn { DemoMode.log("detail: no room (\(left) MB left, needs \(enough))") }
                if !detailSkipNoted {
                    detailSkipNoted = true
                    Diagnostics.shared.note("100% view: no full-size copy, only \(left) MB left (needs ~\(enough))")
                }
            }
            return
        }
        detailSkipNoted = false
        detailBuilding = true
        detailLoading = true
        BlackBox.shared.crumb("100% view copy")
        Diagnostics.shared.note("100% view: building \(Int(edge)) px copy")
        if DemoMode.isOn { DemoMode.log("detail: building \(Int(edge))") }
        let generation = loadGeneration
        let mp = megapixels
        workQueue.async {
            let src = HeavyWork.shared.run(.fullSizeCopy, megapixels: mp, optional: true) {
                session.makeSource(maxEdge: edge, materialize: true)
            } ?? nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.detailBuilding = false
                self.detailLoading = false
                if src == nil { self.detailRetry.hold(for: 12) }
                // the photo was decoded again meanwhile (HDR, a heal): this copy shows the old version
                guard generation == self.loadGeneration else {
                    if self.zoomLevel > 1.4 { self.buildDetail() }
                    return
                }
                // AI Denoise started while it was building: a 4096 px copy beside the model is what iOS closed Lumen
                // for (owner's diagnostics, 22 Oct: denoise started with 1072 MB free, killed at 480 MB)
                guard self.denoiseProgress == nil else {
                    if src != nil { Diagnostics.shared.note("100% view: copy dropped, AI Denoise is running") }
                    return
                }
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
    @Published var lensBlurRefining = false { didSet { maskEditing = lensBlurRefining; requestRender() } }
    @Published var lensSliderActive = false {
        didSet {
            if DemoMode.isOn { DemoMode.log("lens preview \(lensSliderActive && lensPreviewEnabled)") }
            requestRender()
        }
    }
    /// Blur amount being dragged (set by the panel's slider; the red preview uses `lensSliderActive`).
    var lensDragging = false { didSet { if !lensDragging { requestRender() } } }
    @Published var lensPreviewEnabled = UserDefaults.standard.object(forKey: "lensPreviewEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lensPreviewEnabled, forKey: "lensPreviewEnabled"); requestRender() }
    }
    @Published var lensFocusMessage: String?
    @Published var lensSelectionPreview = false { didSet { requestRender() } }
    private var lensPreviewWork: DispatchWorkItem?
    func showLensSelectionPreview() {
        lensPreviewWork?.cancel()
        lensSelectionPreview = true
        if DemoMode.isOn { DemoMode.log("lens selection confirmed") }
        let work = DispatchWorkItem { [weak self] in self?.lensSelectionPreview = false }
        lensPreviewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
    func toggleLensSelectionPreview() {
        lensPreviewWork?.cancel(); lensSelectionPreview.toggle()
    }
    func enableLensBlur() {
        var s = settings; s.lensBlur.amount = LensBlurSettings.startAmount; s.lensBlur.activated = true; s.lensBlur.controlsVersion = 1
        s.setOn(.lensBlur, true); settings = s
    }
    private var lensFocusPending = false
    private func finishLensFocus() {
        guard lensFocusPending, let source, let session else { return }
        lensFocusPending = false
        Diagnostics.shared.note("Lens Blur: finding the subject's distance")
        if let range = session.lensSubjectRange(source, point: settings.lensBlur.subjectPoint) {
            var s = settings
            s.lensBlur.focusDistance = (range.lowerBound + range.upperBound) / 2
            s.lensBlur.focusWidth = max(0.02, (range.upperBound - range.lowerBound) / 2 + 0.02)
            settings = s
            lensFocusMessage = "Subject selected. Red shows the background to blur."
        } else {
            lensFocusMessage = "Manual focus set. No subject detected here; refine edges with a brush."
        }
        showLensSelectionPreview()
    }
    private var lensBlurEditing = false

    func setLensBlurEditing(_ editing: Bool) {
        lensBlurEditing = editing
        if editing {
            if settings.isOn(.lensBlur) {
                var s = settings
                let first = s.lensBlur.beginEditing()
                if s != settings { settings = s }
                if first { lensFocusPending = true }
            }
            prepareAutoMasksIfNeeded()
        } else { lensBlurRefining = false; lensSliderActive = false; lensPreviewWork?.cancel(); lensSelectionPreview = false }
    }

    func pickLensFocus(at p: Pt) {
        guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1,
              let distance = source?.depthField?.value(atNormalized: p.x, p.y) else { return }
        lastChange = .distantPast
        var s = settings
        if s.lensBlur.amount == 0 { s.lensBlur.amount = LensBlurSettings.startAmount }
        s.lensBlur.activated = true; s.lensBlur.controlsVersion = 1; s.setOn(.lensBlur, true)
        s.lensBlur.focusDistance = Double(distance)
        s.lensBlur.subjectPoint = p
        if DemoMode.isOn, DemoMode.value("-lumenDemoLensDepth") != nil, let source {
            source.storeMask(EditSession.subjectKey(p), source.cachedMask(EditSession.aiSubject))
        }
        // A focus change starts a fresh automatic range; existing brush refinements remain available in Masks.
        s.lensBlur.maskID = nil
        settings = s
        lensFocusMessage = "Selecting subject…"
        lensFocusPending = true
        prepareAutoMasksIfNeeded()
        lensBlurPicking = false
        if DemoMode.isOn { DemoMode.log("lens focus picked") }
    }

    /// Near/Far on the main Lens Blur page: edits the linked background mask's depth band without selecting it
    /// (it is created the first time; Masks never lists it, it belongs to Lens Blur).
    func updateLensDepth(_ change: (inout MaskComponent) -> Void) {
        if settings.lensBlur.maskID.flatMap({ id in settings.masks.first { $0.id == id } }) == nil { refineLensBlur(select: false) }
        guard let id = settings.lensBlur.maskID else { return }
        updateMask(id) { m in
            guard let i = m.components.firstIndex(where: { $0.kind == .depth }) else { return }
            change(&m.components[i])
        }
    }

    func refineLensBlur(select: Bool = true) {
        if let id = settings.lensBlur.maskID, settings.masks.contains(where: { $0.id == id }) {
            if select { selectMask(id); maskTab = .shape }
            return
        }
        var m = Mask.make(.depth)
        m.name = "Lens Blur background"
        m.components[0].lumLow = settings.lensBlur.fullFrom
        m.components[0].lumHigh = 1
        m.components[0].lumLowFeather = settings.lensBlur.fullFrom - settings.lensBlur.rampStart
        m.components[0].lumHighFeather = 0
        if m.components[0].lumLow >= 0.999 { m.components[0].amount = 0 }
        var subject = MaskComponent.make(.subject, op: .subtract)
        subject.subjectPoint = settings.lensBlur.subjectPoint
        m.components.append(subject)
        lastChange = .distantPast
        var s = settings
        s.masks.append(m)
        s.lensBlur.maskID = m.id
        settings = s
        if select { selectMask(m.id); maskTab = .shape }
    }

    /// AI masks of the last few heal versions of this photo (keyed by their heal ids), for undo / redo. Only the masks
    /// (a few MB each at preview size), never the decoded photo.
    private struct MaskMemo { let size: CGSize; let masks: [String: CIImage]; let tried: Set<String>; let depth: DepthField?; let scene: SceneField?; let used: Date }
    private var maskMemo: [[UUID]: MaskMemo] = [:]

    private func memoMasks(of source: ImageSource, heals: [UUID]) {
        let (masks, tried) = source.snapshotMasks()
        guard !tried.isEmpty else { return }
        maskMemo[heals] = MaskMemo(size: source.size, masks: masks, tried: tried, depth: source.depthField, scene: source.sceneField, used: Date())
        while maskMemo.count > 4, let oldest = maskMemo.min(by: { $0.value.used < $1.value.used })?.key { maskMemo[oldest] = nil }
    }

    private func prepareAutoMasksIfNeeded() {
        guard let session, let source, !autoMaskBusy, denoiseProgress == nil else { return }
        let needs = ((lensBlurEditing || settings.effective.lensBlur.amount > 0) && (!source.hasTried(EditSession.aiDepth) || !source.hasTried(EditSession.aiSubject) || !source.hasTried(EditSession.subjectKey(settings.lensBlur.subjectPoint)))) || settings.masks.contains { m in
            m.components.contains { c in
                switch c.kind {
                case .subject: return !source.hasTried(EditSession.subjectKey(c.subjectPoint))
                case .background: return !source.hasTried(EditSession.aiSubject)
                case .sky: return !source.hasTried(EditSession.aiSky)
                case .people: return !source.hasTried(EditSession.aiPeople)
                case .depth: return !source.hasTried(EditSession.aiDepth)
                case .landscape:
                    return !source.hasTried(EditSession.aiScene) || (!c.scene.isEmpty && !source.hasTried(EditSession.sceneKey(c.scene.sorted())))
                default: return false
                }
            }
        }
        guard needs else { finishLensFocus(); return }
        let askedBlur = settings.lensBlur
        var snapshot = settings
        if lensBlurEditing { snapshot.lensBlur.amount = max(snapshot.lensBlur.amount, 1) }
        let analysisSettings = snapshot
        autoMaskBusy = true
        Diagnostics.shared.note("AI masks: working them out")
        let slow = DemoMode.value("-lumenDemoSlowAI") != nil   // CI: time to see the busy notice
        let mp = megapixels
        aiMaskQueue.async {
            if slow { Thread.sleep(forTimeInterval: 4) }
            _ = HeavyWork.shared.run(.aiMasks, megapixels: mp) { session.prepareAutoMasks(analysisSettings, source: source) }
            let missing: Set<String> = Set([EditSession.aiSubject, EditSession.aiSky, EditSession.aiPeople, EditSession.aiDepth, EditSession.aiScene].filter { source.hasTried($0) && source.cachedMask($0) == nil })
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.autoMaskBusy = false
                if self.denoiseRequested { self.ensureDenoise(start: true) }
                // the photo was decoded again meanwhile (HDR, a heal): these results belong to the old copy, so the
                // new one is analysed now (it was skipped while this job was busy)
                guard self.source === source else { self.prepareAutoMasksIfNeeded(); return }
                self.autoMaskMissing = missing
                self.autoMaskFailed = source.failures
                if self.lensFocusPending, self.settings.lensBlur == askedBlur { self.finishLensFocus() }
                self.syncDetailMasks()
                self.requestRender()
                // masks may have changed while we were busy
                if self.settings.masks != analysisSettings.masks || self.settings.lensBlur != askedBlur { self.prepareAutoMasksIfNeeded() }
            }
        }
    }

    // MARK: History

    func undo() {
        // a heal being made is built on the current heals: undoing under it would keep a fix built on a removed one
        guard !healBusy, let last = undoStack.popLast() else { return }
        redoStack.append(settings)
        applyingHistory = true
        settings = last
        applyingHistory = false
        lastChange = .distantPast
    }

    /// One step of the History list (newest first). `back` = how many undo steps away it is (0 = now).
    struct HistoryStep: Identifiable { let id: Int; let label: String; let back: Int }

    /// The edit steps since the photo's undo history began, newest first, ending with how it was opened.
    var historySteps: [HistoryStep] {
        let states = undoStack + [settings]
        var steps: [HistoryStep] = []
        for k in stride(from: states.count - 1, to: 0, by: -1) {
            steps.append(HistoryStep(id: k, label: states[k].historyLabel(from: states[k - 1]), back: states.count - 1 - k))
        }
        steps.append(HistoryStep(id: 0, label: undoStack.count >= 100 ? "Earlier" : "Opened", back: states.count - 1))
        return steps
    }

    /// Goes back `n` steps at once (History list); redo comes forward again.
    func goBack(_ n: Int) {
        guard !healBusy, n > 0, n <= undoStack.count else { return }
        var current = settings
        for _ in 0..<n {
            guard let last = undoStack.popLast() else { break }
            redoStack.append(current)
            current = last
        }
        applyingHistory = true
        settings = current
        applyingHistory = false
        lastChange = .distantPast
    }

    func redo() {
        guard !healBusy, let next = redoStack.popLast() else { return }
        undoStack.append(settings)
        applyingHistory = true
        settings = next
        applyingHistory = false
        lastChange = .distantPast
    }

    func reset() {
        lastChange = .distantPast
        var s = EditSettings()
        s.lensBlur.activated = settings.lensBlur.activated
        s.lensBlur.controlsVersion = settings.lensBlur.controlsVersion
        settings = s
    }

    /// Auto finds the subject first (Vision, a moment on the phone), so it runs off the main thread.
    @Published private(set) var autoBusy = false

    private func auto(done: @escaping (EditSettings) -> Void) {
        guard let session, let source, !autoBusy else { return }
        autoBusy = true
        let start = settings
        let skipSubject = DemoMode.isOn   // the simulator has no Vision subject; CI keeps Auto quick
        workQueue.async {
            if !skipSubject { session.ensureSubject(source) }
            let result = session.autoSettings(source: source, current: start)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.autoBusy = false
                // only Auto's own values: anything changed meanwhile (other tools, masks) is kept
                var s = self.settings
                for key in EditSession.autoKeys { s[keyPath: key] = result[keyPath: key] }
                done(s)
            }
        }
    }

    /// What Auto changed, so the Auto button can show it is on and a second tap can take it back.
    struct AutoRecord { var before: EditSettings; var after: EditSettings }
    @Published private(set) var autoRecord: AutoRecord?

    private static func autoFields(_ s: EditSettings) -> [Double] { EditSession.autoKeys.map { s[keyPath: $0] } }

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
            for key in EditSession.autoKeys { s[keyPath: key] = r.before[keyPath: key] }
            autoRecord = nil
            settings = s
        } else {
            auto { [weak self] s in
                guard let self else { return }
                let before = self.settings
                self.lastChange = .distantPast
                self.settings = s
                self.autoRecord = AutoRecord(before: before, after: s)
            }
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
        s.aiDenoise = settings.aiDenoise   // a preset never starts or drops a photo's AI Denoise
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
    /// The Heal model is loading in the background (shown in the Heal panel).
    @Published private(set) var healPreparing = false
    /// Loads the Heal model off the main thread the first time the Heal tool opens.
    func prepareHeal() {
        guard !healPreparing, !EditSession.healModelReady, EditSession.hasHealModel else { return }
        healPreparing = true
        BlackBox.shared.crumb("Heal tool opened")
        // Not at the very moment the tool opens, and not without room: the panel appearing redraws the photo, loading the
        // model is itself a spike of 2 GB or more, and on 23 Oct Lumen was closed three times in 20 s right at "heal
        // model loading". With less room than it needs the model loads when the first fix is made instead, inside the
        // heavy-work coordinator (which lets go of what it can first).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            let enough = HeavyWork.needMB(.healModel, megapixels: 0) + HeavyWork.marginMB(for: .healModel)
            if Diagnostics.availableMB < enough {
                self.freeMemoryForDetail()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                // through the coordinator: nothing else heavy starts while the model loads, and it isn't loaded at all
                // without room for the spike (it then loads with the first fix, which asks for room of its own)
                let loaded: Bool? = HeavyWork.shared.run(.healModel, megapixels: 0, optional: true) { () -> Bool in
                    BlackBox.shared.crumb("heal model load")
                    Diagnostics.shared.note("heal model loading")
                    EditSession.prepareHealModel()
                    Diagnostics.shared.note("heal model ready \(EditSession.healModelReady)")
                    return EditSession.healModelReady
                }
                if loaded == nil { Diagnostics.shared.note("heal model: not loaded yet, only \(Diagnostics.availableMB) MB left (it loads with the first fix)") }
                Task { @MainActor [weak self] in self?.healPreparing = false }
            }
        }
    }
    fileprivate var healWaitingForReload = false
    private var healRelease: Task<Void, Never>?
    /// The Heal model is kept once loaded, also after leaving the tool and the photo (it holds only ~150-300 MB; until
    /// 23 Oct it was let go of 30 s after leaving Heal, and every use then loaded it again: a 2-3 GB spike that closed
    /// Lumen on the owner's phone). It goes only when memory is critical (memory warning handler) or iOS closes Lumen.
    func healToolChanged(open: Bool, now: Bool = false) {
        healRelease?.cancel(); healRelease = nil
    }

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
        freeMemoryForHeal()   // it decodes the photo at 3072 px: the copies that can be made again go first
        healBusy = true
        healBusyText = EditSession.healModelReady ? "Removing…" : "Preparing Heal…"
        Diagnostics.shared.note("heal start (model ready \(EditSession.healModelReady))")
        let mp = megapixels
        let item = self.item
        workQueue.async { [weak store = self.store] in
            let spot = HeavyWork.shared.run(.heal, megapixels: mp) { session.makeHeal(strokes: [stroke], earlier: earlier) } ?? nil
            LumenGPU.context.clearCaches()
            Diagnostics.shared.note(spot == nil ? "heal failed" : "heal done")
            let why = EditSession.healFailure ?? .failed
            Task { @MainActor [weak self] in
                // the editor closed meanwhile: the fix still goes on the photo (checklist A4)
                guard let self else { if let spot { store?.addHeals([spot], to: item) }; return }
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

    /// A heal decodes the full-resolution photo and runs the large Heal model: let go of the copies that can be made
    /// again first (the 100 % view's full-resolution source, the heal-free "before" preview, GPU caches). With all of
    /// them alive iOS closed the app during big heals (owner, 18 Oct, Lumen at 3.3 GB in the JetsamEvent report).
    func freeMemoryForHeal() {
        detailSource = nil
        unhealedSource = nil
        LumenGPU.context.clearCaches()
        // short of room: the mask models go too (masks already worked out are kept; they load again when needed)
        if Diagnostics.availableMB < 1500 { EditSession.releaseMaskModels() }
    }

    /// Keeps a preview of the original (no heals, no AI Denoise) while the photo has either, for hold-to-compare and
    /// the split's before half (21 Oct review: with AI Denoise on they showed the cleaned photo). Built in the
    /// background, not while a clean or the AI masks are running, dropped when neither is on.
    func refreshUnhealed() {
        let heals = settings.effective.heals
        let denoised = settings.effective.aiDenoise > 0 && denoiseReady
        guard !heals.isEmpty || denoised, let session else { unhealedSource = nil; return }
        guard denoiseProgress == nil else { return }
        // the photo without heals doesn't change when heals do, only when HDR changes how it is decoded
        if unhealedSource != nil && unhealedHDR == settings.hdr { return }
        unhealedSource = nil
        let hdr = settings.hdr
        let generation = loadGeneration
        BlackBox.shared.crumb("original copy")
        Diagnostics.shared.note("original copy (no heals, no AI Denoise): making it")
        let mp = megapixels
        workQueue.async {
            // the estimate is the photo's size (checklist A8): megapixels 0 declared 450 MB for every photo
            let src = HeavyWork.shared.run(.original, megapixels: mp, optional: true) {
                session.makeSource(maxEdge: MemoryBudget.previewEdge, materialize: true, heals: [], denoise: false)
            } ?? nil
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
    /// A running multi-person removal can be stopped (A19: only AI Denoise could). What is removed so far is kept.
    nonisolated(unsafe) private var removePeopleCancel = false
    /// People are being removed one by one (the Stop button shows only then, not for a single painted heal).
    @Published private(set) var removingPeople = false

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
        let mp = megapixels
        workQueue.async {
            let people = demo ?? HeavyWork.shared.run(.findPeople, megapixels: mp) { session.findPeople(earlier: earlier) } ?? []
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

    /// Stops a running multi-person removal between people (A19); the people already removed stay removed.
    func cancelRemovingPeople() { removePeopleCancel = true }

    /// Removes the people picked, one heal each (each built on the ones before), all added as one undo step.
    func removeChosenPeople() {
        guard !healBusy, let session, let people = peopleFound else { return }
        let chosen = people.filter { peopleChosen.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let earlier = settings.effective.heals
        healBusy = true
        healBusyText = chosen.count == 1 ? "Removing…" : "Removing 1 of \(chosen.count)…"
        removePeopleCancel = false
        removingPeople = true
        freeMemoryForHeal()
        let mp = megapixels
        let item = self.item
        workQueue.async { [weak self, weak store = self.store] in
            var made: [HealSpot] = []
            var failures: [HealFailure] = []
            for (i, person) in chosen.enumerated() {
                if self?.removePeopleCancel == true { break }   // A19: stop between people; what's removed stays removed
                if i > 0 {
                    let text = "Removing \(i + 1) of \(chosen.count)…"
                    Task { @MainActor [weak self] in self?.healBusyText = text }
                }
                Diagnostics.shared.note("remove person \(i + 1) of \(chosen.count)")
                let spot = HeavyWork.shared.run(.heal, megapixels: mp) { session.makeHeal(person: person, earlier: earlier + made) } ?? nil
                LumenGPU.context.clearCaches()
                if let spot {
                    made.append(spot)
                } else {
                    failures.append(EditSession.healFailure ?? .failed)
                }
            }
            let done = made, failed = failures, stopped = self?.removePeopleCancel == true
            Task { @MainActor [weak self] in
                guard let self else { store?.addHeals(done, to: item); return }
                self.removingPeople = false
                self.peopleFound = nil
                self.peopleChosen = []
                if stopped { self.healMessage = "Stopped after \(done.count) of \(chosen.count)." }
                else if let first = failed.first {
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

    // MARK: Paste

    /// Paste edits: exactly what was chosen when copying (`Clipboard.pasted`, the same rule as the library's Paste).
    /// AI Denoise needs a clean of this photo (about a minute, a locked screen): only with `withDenoise`, which the
    /// menu asks the user for first; a clean that already exists just sets the strength.
    func paste(_ clip: Clipboard, withDenoise: Bool = false) {
        lastChange = .distantPast
        settings = clip.pasted(onto: settings, samePhoto: item.id == clip.sourceID)
        guard withDenoise, clip.bringsDenoise else { return }
        if session?.hasDenoised == true { settings.aiDenoise = clip.settings.aiDenoise; return }
        guard MemoryBudget.denoiseFits, EditSession.hasDenoiseModel else {
            message = "AI Denoise isn't available on this iPhone (it needs more memory than it gives an app). The other edits were pasted."
            return
        }
        denoiseTarget = clip.settings.aiDenoise
        DispatchQueue.main.async { [weak self] in self?.startDenoise() }
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
            guard let thumbSource = session.makeSource(maxEdge: 200, materialize: true) else { return }
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
        if let failed = failureReason(c) { return failed }
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

    /// This mask part's AI step failed (not "found nothing"): says so, so the user knows trying again can help.
    private func failureReason(_ c: MaskComponent) -> String? {
        let keys: [String]
        switch c.kind {
        case .subject, .background: keys = [EditSession.aiSubject, EditSession.subjectKey(c.subjectPoint)]
        case .sky: keys = [EditSession.aiSky, EditSession.aiScene]
        case .people: keys = [EditSession.aiPeople]
        case .depth: keys = [EditSession.aiDepth]
        case .landscape: keys = [EditSession.aiScene]
        default: return nil
        }
        guard keys.contains(where: { autoMaskFailed.contains($0) }) else { return nil }
        return "The AI couldn't run on this photo (usually not enough memory). That isn't the same as finding nothing: try again."
    }

    /// Banner's "Try again": everything that failed is attempted once more.
    func retryAI() {
        source?.clearFailures()
        autoMaskFailed = []
        autoMaskMissing = []
        Diagnostics.shared.note("AI masks: trying again after a failure")
        prepareAutoMasksIfNeeded()
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
            if let last = userMasks.last { selectMask(last.id) } else { selectedMaskID = nil; selectedComponentID = nil }
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

    /// The finger that was painting lifted: the stroke keeps its shape with far fewer points (quality checklist B4).
    func endStroke() {
        let wasOpen = strokeOpen
        strokeOpen = false
        guard wasOpen, let c = selectedComponent, c.kind == .brush, let last = c.strokes.last, last.points.count > 16 else { return }
        updateComponent(c.id) { comp in
            guard var l = comp.strokes.popLast() else { return }
            l = l.simplified()
            comp.strokes.append(l)
        }
    }

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
        // AI Denoise is on but its cleaned copy is gone: say so now, not after a hidden minute inside the export (A16)
        if settings.effective.aiDenoise > 0, !session.hasDenoised, EditSession.hasDenoiseModel {
            message = EditSession.ExportFailure.denoiseMissing.message
            return
        }
        isExporting = true
        let s = settings
        let name = item.displayName
        let patches = HealStore.retain(Set(s.heals.map(\.id)))
        // a full-size export decodes the whole photo again: let go of the copies that can be made again first
        unhealedSource = nil
        if Diagnostics.availableMB < 2000 { detailSource = nil; EditSession.releaseMaskModels() }
        LumenGPU.context.clearCaches()
        let mp = megapixels
        workQueue.async {
            defer { patches.close() }
            Diagnostics.shared.note("export \(o.format) edge \(o.longEdge)")
            let exportStart = Date()
            let outcome = HeavyWork.shared.run(.export, megapixels: mp) {
                session.renderDataOutcome(s, format: o.format, quality: o.quality / 100, maxEdge: o.maxEdge, includeHDR: o.hdr,
                                          allowClean: false)
            }
            var data: Data?
            var failMessage: String?
            switch outcome {
            case .data(let d): data = d
            case .failed(let f): failMessage = f.message
            case nil: failMessage = "There isn't enough free memory to export this photo right now. Close other apps and try again."
            }
            Diagnostics.shared.note(String(format: "export %@ in %.1f s (%@)", data == nil ? "failed" : "done",
                                           Date().timeIntervalSince(exportStart), data.map { "\($0.count / 1_048_576) MB" } ?? "no file"))
            var url: URL?
            if let data {
                let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-lumen.\(o.format.ext)")
                if (try? data.write(to: u, options: .atomic)) != nil { url = u }
                if DemoMode.isOn { DemoMode.log("exported \(o.format.rawValue) q \(Int(o.quality)) edge \(o.longEdge) bytes \(data.count)") }
            }
            Task { @MainActor [weak self] in
                self?.isExporting = false
                self?.refreshUnhealed()
                if let url { self?.exported = ExportResult(url: url) } else { self?.message = failMessage ?? "Export failed." }
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
