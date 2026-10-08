import SwiftUI
import Photos

private let renderQueue = DispatchQueue(label: "lumen.render", qos: .userInitiated)

/// Lets a queued render notice it has been superseded by a newer slider value.
private final class Generation: @unchecked Sendable {
    private var v = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; v += 1; return v }
    var value: Int { lock.lock(); defer { lock.unlock() }; return v }
}

struct ExportResult: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class EditorViewModel: ObservableObject {
    let item: LibraryItem

    @Published var settings = EditSettings() {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    @Published var showOriginal = false { didSet { requestRender() } }
    @Published private(set) var preview: UIImage?
    @Published private(set) var histogram: HistogramData?
    @Published private(set) var maskOverlay: UIImage?
    @Published private(set) var isLoading = true
    @Published private(set) var loadFailed = false
    @Published var isExporting = false
    @Published var exported: ExportResult?
    @Published var message: String?
    @Published private(set) var presetThumbs: [String: UIImage] = [:]

    // Mask editing
    @Published var maskEditing = false { didSet { requestRender() } }
    @Published var selectedMaskID: UUID? { didSet { requestRender() } }
    @Published var brushSize = 0.05
    @Published var brushErase = false

    private var session: EditSession?
    private weak var store: LibraryStore?
    private let generation = Generation()
    private var started = false

    // Undo / redo
    private var undoStack: [EditSettings] = []
    private var redoStack: [EditSettings] = []
    private var applyingHistory = false
    private var lastChange = Date.distantPast
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(item: LibraryItem) { self.item = item }

    var selectedMask: Mask? { settings.masks.first { $0.id == selectedMaskID } }

    func start(store: LibraryStore) {
        guard !started else { return }
        started = true
        self.store = store
        applyingHistory = true
        settings = store.settings(for: item)
        applyingHistory = false
        let url = store.fileURL(item)
        renderQueue.async {
            let s = EditSession(url: url)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.session = s
                self.isLoading = false
                self.loadFailed = (s == nil)
                self.requestRender()
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
        store?.save(settings, for: item)
        requestRender()
    }

    private func requestRender() {
        guard let session else { return }
        let gen = generation.next()
        let editing = showOriginal ? EditSettings() : settings
        let skipGeometry = maskEditing && !showOriginal
        let overlayMask = (maskEditing && !showOriginal) ? selectedMask : nil
        let generation = generation
        renderQueue.async {
            if generation.value != gen { return }
            guard let cg = session.render(editing, maxEdge: 2200, skipGeometry: skipGeometry) else { return }
            if generation.value != gen { return }
            let img = UIImage(cgImage: cg)
            let hist = Histogram.compute(cg)
            var overlay: UIImage?
            if let overlayMask, let o = session.renderMaskOverlay(editing, mask: overlayMask, maxEdge: 2200) {
                overlay = UIImage(cgImage: o)
            }
            Task { @MainActor [weak self] in
                guard generation.value == gen else { return }
                self?.preview = img
                self?.histogram = hist
                self?.maskOverlay = overlay
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

    // MARK: Presets

    func apply(preset edits: EditSettings, keepsWhiteBalance: Bool = true) {
        var s = edits
        if keepsWhiteBalance && s.temperature == 0 && s.tint == 0 {
            s.temperature = settings.temperature
            s.tint = settings.tint
        }
        s.masks = settings.masks
        s.straighten = settings.straighten
        s.quarterTurns = settings.quarterTurns
        s.cropAspect = settings.cropAspect
        s.cropZoom = settings.cropZoom
        s.cropX = settings.cropX
        s.cropY = settings.cropY
        settings = s
    }

    func apply(_ p: Preset) {
        var s = EditSettings()
        p.apply(&s)
        apply(preset: s)
    }

    func loadPresetThumbs(user: [UserPreset]) {
        guard let session else { return }
        var jobs: [(String, EditSettings)] = Preset.all.map { p in
            var s = EditSettings()
            p.apply(&s)
            return (p.name, s)
        }
        jobs += user.map { ($0.id.uuidString, $0.settings) }
        let turns = settings.quarterTurns
        renderQueue.async {
            for (key, var s) in jobs {
                s.masks = []
                s.quarterTurns = turns
                guard let cg = session.render(s, maxEdge: 180) else { continue }
                let img = UIImage(cgImage: cg)
                Task { @MainActor [weak self] in self?.presetThumbs[key] = img }
            }
        }
    }

    // MARK: Masks

    func addMask(_ kind: MaskKind) {
        let m = Mask.make(kind)
        settings.masks.append(m)
        selectedMaskID = m.id
    }

    func updateMask(_ id: UUID, _ change: (inout Mask) -> Void) {
        guard let i = settings.masks.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.masks[i])
    }

    func deleteMask(_ id: UUID) {
        settings.masks.removeAll { $0.id == id }
        if selectedMaskID == id { selectedMaskID = settings.masks.last?.id }
    }

    func beginStroke(_ p: Pt) {
        guard let id = selectedMaskID else { return }
        let stroke = BrushStroke(points: [p], size: brushSize, erase: brushErase)
        updateMask(id) { $0.strokes.append(stroke) }
    }

    func extendStroke(_ p: Pt) {
        guard let id = selectedMaskID else { return }
        updateMask(id) { m in
            guard var last = m.strokes.popLast() else { return }
            if let prev = last.points.last, hypot(prev.x - p.x, prev.y - p.y) < 0.002 {
                m.strokes.append(last)
                return
            }
            last.points.append(p)
            m.strokes.append(last)
        }
    }

    func pickColor(at p: Pt) {
        guard let id = selectedMaskID, let c = preview?.rgb(atNormalized: CGPoint(x: p.x, y: p.y)) else { return }
        updateMask(id) { $0.colorR = c.0; $0.colorG = c.1; $0.colorB = c.2 }
    }

    // MARK: Export

    func export(_ format: ExportFormat) {
        guard let session, !isExporting else { return }
        isExporting = true
        let s = settings
        let name = item.displayName
        renderQueue.async {
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

extension UIImage {
    /// Average colour of a small window around a normalised point (0...1, top-left origin).
    func rgb(atNormalized p: CGPoint) -> (Double, Double, Double)? {
        guard let cg = cgImage else { return nil }
        let half = 4
        let x = Int(min(max(p.x, 0), 1) * CGFloat(cg.width - 1))
        let y = Int(min(max(p.y, 0), 1) * CGFloat(cg.height - 1))
        let rect = CGRect(x: max(0, x - half), y: max(0, y - half), width: half * 2 + 1, height: half * 2 + 1)
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let crop = cg.cropping(to: rect), let cs = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ok: Bool = px.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { return nil }
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }
}
