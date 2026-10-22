import SwiftUI
import Photos
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

struct LibraryItem: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var fileName: String
    var added: Date
    var rating: Int = 0     // 0...5
    var flag: Int = 0       // 1 = pick, -1 = reject
    /// When the photo was taken (EXIF), nil if the file doesn't say. Older libraries fill it in on first launch.
    var taken: Date? = nil
}

/// Photos exported together, for the "save all / share" sheet.
struct BatchResult: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private let thumbQueue = DispatchQueue(label: "lumen.thumbs", qos: .utility)
private let exportQueue = DispatchQueue(label: "lumen.batch-export", qos: .userInitiated)
/// Serial: undo-history writes for every photo, in order (see `LibraryStore.save`).
private let historyQueue = DispatchQueue(label: "lumen.history", qos: .utility)
/// History waiting to be written, by file (only touched on `historyQueue`): a burst of saves writes the newest once,
/// 0.2 s later, and at once when the photo closes, is deleted or the app leaves the screen. (2 s lost the undo
/// history when the app was closed right after an edit: UI test testOctoberEditorFixes, 19 Oct.)
nonisolated(unsafe) private var pendingHistory: [URL: LibraryStore.EditHistory] = [:]

/// Imported originals live in Documents/Library/files; edits are JSON sidecars in Documents/Library/edits.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var thumbVersion = 0
    /// Decoded thumbnails, by photo and version: every finished thumbnail redraws the grid, and each cell used to read
    /// and decode its JPEG from disk again on the main thread (code review, 19 Oct).
    private let thumbCache = NSCache<NSString, UIImage>()
    private var thumbVersions: [UUID: Int] = [:]

    /// The photo's thumbnail, decoded once per version.
    func thumbnail(_ item: LibraryItem) -> UIImage? {
        let key = "\(item.id.uuidString)-\(thumbVersions[item.id] ?? 0)" as NSString
        if let img = thumbCache.object(forKey: key) { return img }
        guard let img = UIImage(contentsOfFile: thumbURL(item).path)?.preparingForDisplay() else { return nil }
        thumbCache.setObject(img, forKey: key)
        return img
    }
    @Published private(set) var userPresets: [UserPreset] = []
    @Published var clipboard: EditSettings?
    @Published var lastError: String?
    @Published var importing = false
    @Published var importTotal = 0
    @Published var importDone = 0
    /// AI Denoise for photos edits were pasted onto (owner, 21 Oct: asked for, at most 5 at a time, with progress):
    /// cleaned one after another in the background of the library; pauses when Lumen leaves the screen.
    struct DenoiseBatch: Equatable { var done: Int; var count: Int; var fraction: Double; var name: String; var paused: Bool }
    @Published private(set) var denoiseBatch: DenoiseBatch?
    static let denoiseBatchCap = 5
    private var batchQueue: [UUID] = []
    private var batchTotal = 0
    private var batchStrength: Double = 100
    private var batchRunning = false
    nonisolated(unsafe) private var batchPausing = false
    nonisolated(unsafe) private var batchCancel = false
    private let batchDenoiseQueue = DispatchQueue(label: "lumen.denoise.batch", qos: .userInitiated)
    private var batchObservers: [NSObjectProtocol] = []
    /// Cleans that paused in the editor (Lumen left the screen or was swiped away): photo and how far it got.
    @Published private(set) var pausedCleans: [(item: LibraryItem, fraction: Double)] = []

    /// Batch export in progress (done, total), and its result.
    @Published var batchProgress: (done: Int, total: Int)?
    @Published var batchResult: BatchResult?
    /// The order the library shows (date sorted); the editor's swipe / next / previous follow it.
    @Published var browseOrder: [UUID] = []
    /// Photos whose file can't be decoded: their thumbnail says so instead of spinning forever.
    @Published private(set) var unreadable: Set<UUID> = []
    private var activeImports = 0

    private let fm = FileManager.default
    private let root: URL
    private let filesDir: URL
    private let thumbsDir: URL
    private let editsDir: URL

    init(testRoot: URL? = nil) {
        if testRoot == nil, DemoMode.isOn, DemoMode.value("-lumenDemoHealDeletion") == "1" { Self.checkHealDeletion() }
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = testRoot ?? docs.appendingPathComponent("Library", isDirectory: true)
        filesDir = root.appendingPathComponent("files", isDirectory: true)
        thumbsDir = root.appendingPathComponent("thumbs", isDirectory: true)
        editsDir = root.appendingPathComponent("edits", isDirectory: true)
        for d in [filesDir, thumbsDir, editsDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        // exported files from earlier runs (shared or saved already) only take up space
        if testRoot == nil {
            thumbQueue.async {
                let tmp = FileManager.default.temporaryDirectory
                for u in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
                where u.lastPathComponent.hasPrefix("lumen-export-") || u.deletingPathExtension().lastPathComponent.hasSuffix("-lumen") {
                    try? FileManager.default.removeItem(at: u)
                }
            }
        }
        // leaving the screen may be the last chance to write: iOS can close the app from the background
        resignObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                object: nil, queue: nil) { _ in
            historyQueue.async { LibraryStore.writePendingHistory() }
        }
        // healed patches (Heal tool) live with the library so they survive app updates
        HealStore.directory = root.appendingPathComponent("heals", isDirectory: true)
        // AI Denoise's cleaned copies (one per photo and HDR mode), removed with the photo
        // (Application Support, out of the Files app; moved there from the library folder on 21 Oct)
        let oldDenoise = root.appendingPathComponent("denoise", isDirectory: true)
        if testRoot == nil, let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            DenoiseStore.directory = support.appendingPathComponent("denoise", isDirectory: true)
            try? fm.createDirectory(at: support, withIntermediateDirectories: true)
            if fm.fileExists(atPath: oldDenoise.path), !fm.fileExists(atPath: DenoiseStore.directory.path) {
                try? fm.moveItem(at: oldDenoise, to: DenoiseStore.directory)
            }
        } else {
            DenoiseStore.directory = oldDenoise
        }
        DispatchQueue.global(qos: .utility).async { DenoiseStore.sweep() }
        Task { @MainActor [weak self] in self?.restoreDenoiseWork() }
        try? fm.createDirectory(at: HealStore.directory, withIntermediateDirectories: true)
        // Smart fill (beta, 0.1.154) was taken out again: free the ~950 MB it may have downloaded
        if testRoot == nil {
            let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            try? fm.removeItem(at: lib.appendingPathComponent("SmartFill-cyberrealistic-v8-inpaint-6bit", isDirectory: true))
        }
        loadIndex()
        fillInDatesTaken()
        // thumbnails that never got made (or were lost) are made again
        for it in items where !fm.fileExists(atPath: thumbURL(it).path) { refreshThumbnail(it) }
        if let data = try? Data(contentsOf: root.appendingPathComponent("presets.json")),
           let decoded = try? JSONDecoder().decode([UserPreset].self, from: data) {
            userPresets = decoded
        } else if let data = try? Data(contentsOf: root.appendingPathComponent("presets.json")),
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            // Presets saved by an older version: migrate their settings like old sidecars.
            userPresets = list.compactMap { p -> UserPreset? in
                guard let name = p["name"] as? String, let s = p["settings"] as? [String: Any],
                      let d = try? JSONSerialization.data(withJSONObject: s) else { return nil }
                let id = (p["id"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID()
                return UserPreset(id: id, name: name, settings: Self.decodeSettings(d))
            }
        }
    }


    /// Deterministic CI fixture: exercises real deletion/storage without a Heal model or user data.
    private static func checkHealDeletion() {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("heal-privacy-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: folder) }
        let files = folder.appendingPathComponent("files"), thumbs = folder.appendingPathComponent("thumbs")
        try? fm.createDirectory(at: files, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbs, withIntermediateDirectories: true)
        let removed = LibraryItem(id: UUID(), displayName: "Removed", fileName: "removed.jpg", added: Date(), taken: Date())
        let kept = LibraryItem(id: UUID(), displayName: "Kept", fileName: "kept.jpg", added: Date(), taken: Date())
        for item in [removed, kept] {
            try? Data([1]).write(to: files.appendingPathComponent(item.fileName))
            try? Data([1]).write(to: thumbs.appendingPathComponent("\(item.id.uuidString).jpg"))
        }
        try? JSONEncoder().encode([removed, kept]).write(to: folder.appendingPathComponent("index.json"))
        let library = LibraryStore(testRoot: folder)
        func spot() -> HealSpot { HealSpot(strokes: [], x: 0, y: 0, w: 0.1, h: 0.1) }
        let current = spot(), undo = spot(), redo = spot(), shared = spot(), copied = spot(), preset = spot(), active = spot(), dropped = spot()
        let all = [current, undo, redo, shared, copied, preset, active, dropped]
        func exists(_ s: HealSpot) -> Bool {
            fm.fileExists(atPath: HealStore.patchURL(s.id).path) || fm.fileExists(atPath: HealStore.maskURL(s.id).path)
        }
        func check(_ yes: Bool, _ message: String) { DemoMode.log("heal deletion \(yes ? "PASS" : "FAIL") \(message)") }
        for s in all {
            _ = try? HealStore.write(s.id, owner: library.fileURL(removed), body: {
                try Data([1]).write(to: HealStore.patchURL(s.id))
                try Data([2]).write(to: HealStore.maskURL(s.id))
            })
        }
        var edits = EditSettings(); edits.heals = [current, shared, copied, preset, active]
        var previous = EditSettings(); previous.heals = [undo]
        var next = EditSettings(); next.heals = [redo]
        library.save(edits, for: removed, history: EditHistory(current: edits, undo: [previous], redo: [next]))
        var otherHistory = EditSettings(); otherHistory.heals = [shared]
        library.save(EditSettings(), for: kept, history: EditHistory(current: EditSettings(), undo: [], redo: [otherHistory]))
        historyQueue.sync { LibraryStore.writePendingHistory() }
        let sidecar = (try? Data(contentsOf: library.editURL(removed))).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let saved = library.history(for: removed, current: edits)
        check(sidecar != nil && sidecar?["_undoHistory"] == nil && fm.fileExists(atPath: library.historyURL(removed).path)
              && saved.undo == [previous] && saved.redo == [next], "undo history kept in its own file")
        var clipboard = EditSettings(); clipboard.heals = [copied]; library.clipboard = clipboard
        var recipe = EditSettings(); recipe.heals = [preset]
        library.userPresets = [UserPreset(name: "Legacy", settings: recipe)]
        let lease = HealStore.retain([active.id])
        library.delete(removed)
        check([current, undo, redo, dropped].allSatisfy { !exists($0) }, "current undo redo and trimmed owner patches removed")
        check([shared, copied, preset].allSatisfy(exists), "retained history clipboard and preset preserved")
        check(exists(active), "in-flight render retains patch")
        lease.close()
        check(!exists(active), "last render release cleans pending patch")
        library.save(edits, for: removed)
        check(!fm.fileExists(atPath: library.editURL(removed).path), "delayed save cannot recreate deleted edits")
        let late = spot()
        let written = try? HealStore.write(late.id, owner: library.fileURL(removed), body: {
            try Data([1]).write(to: HealStore.patchURL(late.id))
        })
        check(written == false && !exists(late), "late Heal result cannot recreate deleted pixels")
        library.clipboard = nil; library.userPresets = []
        library.delete(kept)
        check(!exists(shared), "shared patch removed after last photo deleted")
        // Retained legacy references are intentionally preserved; this is not a global garbage sweep.
        check(!fm.fileExists(atPath: library.fileURL(removed).path) && !fm.fileExists(atPath: library.thumbURL(removed).path), "photo and thumbnail removed")
    }

    // MARK: Photo list

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var backupURL: URL { root.appendingPathComponent("index.backup.json") }

    /// Reads the photo list. If it is damaged, the last good copy is used; if that is damaged too, the list is rebuilt
    /// from the photo files (their edits are keyed by the same id, so they come back as well). Either way the user
    /// is told, and nothing is lost silently.
    private func loadIndex() {
        if let v = DemoMode.value("-lumenDemoCorruptIndex") {   // CI: damage the list to test the recovery
            try? Data("{ not a photo list".utf8).write(to: indexURL)
            if v == "both" { try? Data("garbage".utf8).write(to: backupURL) }
        }
        if let list = Self.readIndex(indexURL) {
            items = list
            // keep the last good list, in case this one is ever damaged
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: indexURL, to: backupURL)
            return
        }
        let files = (try? fm.contentsOfDirectory(at: filesDir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        var from: String?
        if let list = Self.readIndex(backupURL) {
            items = list
            from = "its last good copy"
        }
        // photos the list doesn't know about (imported after the copy was made, or the copy is gone too)
        let known = Set(items.map(\.fileName))
        let orphans = Self.rebuild(from: files.filter { !known.contains($0.lastPathComponent) })
        if !orphans.isEmpty {
            items = (items + orphans).sorted { $0.added > $1.added }
            from = from.map { $0 + " and the photo files" } ?? "the photo files"
        }
        guard let from else { return }   // a new, empty library
        saveIndex()
        lastError = "Lumen's photo list was damaged. It has been rebuilt from \(from) (\(items.count) photos, edits kept)."
        DemoMode.log("index recovered from \(from)")
    }

    /// The photo list, skipping single entries that can't be read rather than losing the whole list.
    nonisolated static func readIndex(_ url: URL) -> [LibraryItem]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let all = try? JSONDecoder().decode([LibraryItem].self, from: data) { return all }
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        let items = list.compactMap { entry -> LibraryItem? in
            guard let d = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? JSONDecoder().decode(LibraryItem.self, from: d)
        }
        return items.isEmpty && !list.isEmpty ? nil : items
    }

    /// Library entries for photo files (named by their id), newest first. Original names are not known any more.
    nonisolated static func rebuild(from files: [URL]) -> [LibraryItem] {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return files.compactMap { u -> LibraryItem? in
            guard let id = UUID(uuidString: u.deletingPathExtension().lastPathComponent) else { return nil }
            let created = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let taken = dateTaken(u)
            return LibraryItem(id: id, displayName: "Photo \(f.string(from: taken ?? created))", fileName: u.lastPathComponent,
                               added: created, taken: taken)
        }
        .sorted { $0.added > $1.added }
    }

    func fileURL(_ item: LibraryItem) -> URL { filesDir.appendingPathComponent(item.fileName) }
    func thumbURL(_ item: LibraryItem) -> URL { thumbsDir.appendingPathComponent("\(item.id.uuidString).jpg") }
    private func editURL(_ item: LibraryItem) -> URL { editsDir.appendingPathComponent("\(item.id.uuidString).json") }

    func item(_ id: UUID) -> LibraryItem? { items.first { $0.id == id } }

    // MARK: Edits

    func settings(for item: LibraryItem) -> EditSettings {
        guard let data = try? Data(contentsOf: editURL(item)) else { return EditSettings() }
        // a damaged file would be replaced by defaults on the next save: keep a copy first
        if (try? JSONSerialization.jsonObject(with: data)) == nil {
            let copy = editsDir.appendingPathComponent("\(item.id.uuidString).damaged.json")
            if !fm.fileExists(atPath: copy.path) { try? data.write(to: copy) }
        }
        return Self.decodeSettings(data)
    }

    /// What the editor opens a photo with: its saved edits, or for a photo never edited, today's defaults, with HDR on
    /// for RAW files (they hold highlight detail above white; owner's call 2026-10-11). Edited photos keep their own HDR.
    func editorSettings(for item: LibraryItem) -> EditSettings {
        var s = settings(for: item)
        // CI keeps the old start (the UI tests switch HDR themselves) unless a test asks for this
        let demoOff = DemoMode.isOn && DemoMode.value("-lumenDemoRawHDR") == nil
        if !demoOff, !FileManager.default.fileExists(atPath: editURL(item).path),
           UTType(filenameExtension: (item.fileName as NSString).pathExtension.lowercased())?.conforms(to: .rawImage) == true {
            s.hdr = true
        }
        return s
    }

    private static func decodeSettings(_ data: Data) -> EditSettings { EditsFile.decodeSettings(data) }

    /// CI only: as if the photo had never been opened.
    func forgetEdits(_ item: LibraryItem) {
        historyQueue.sync { Self.writePendingHistory() }
        for u in [editURL(item), historyURL(item)] { try? FileManager.default.removeItem(at: u) }
    }

    typealias EditHistory = EditsFile.History

    /// Undo/redo lives in its own file next to the edits (`<id>.history.json`), written on `historyQueue`.
    /// The edits sidecar stays small, so the save that runs twice a second while editing is cheap and never
    /// has to encode up to 200 snapshots on the main thread. Sidecars from 0.1.197–0.1.210 kept the history
    /// inside the edits file under `_undoHistory`; it is still read from there until the next save moves it.
    private func historyURL(_ item: LibraryItem) -> URL { editsDir.appendingPathComponent("\(item.id.uuidString).history.json") }

    nonisolated private static func readHistory(file: URL, legacy: Data?) -> EditHistory? {
        EditsFile.readHistory(file: file, legacy: legacy)
    }

    func history(for item: LibraryItem, current: EditSettings) -> EditHistory {
        let file = historyURL(item), legacy = try? Data(contentsOf: editURL(item))
        // wait for any history write still queued for this photo, so reopening at once never loses steps
        guard var history = historyQueue.sync(execute: { pendingHistory[file] ?? Self.readHistory(file: file, legacy: legacy) }),
              history.current == current else { return EditHistory(current: current, undo: [], redo: []) }
        history.undo = Array(history.undo.suffix(100))
        history.redo = Array(history.redo.suffix(100))
        return history
    }

    /// The same, read off the main thread (up to 200 snapshots to decode, and the queue may first be finishing another
    /// photo's write): `done` runs on the main thread.
    func loadHistory(for item: LibraryItem, current: EditSettings, done: @escaping @MainActor (EditHistory) -> Void) {
        let file = historyURL(item), url = editURL(item)
        historyQueue.async {
            let legacy = try? Data(contentsOf: url)
            var history = pendingHistory[file] ?? Self.readHistory(file: file, legacy: legacy)
            if history?.current != current { history = nil }
            let result = history.map { EditHistory(current: $0.current, undo: Array($0.undo.suffix(100)), redo: Array($0.redo.suffix(100))) }
                ?? EditHistory(current: current, undo: [], redo: [])
            Task { @MainActor in done(result) }
        }
    }

    func save(_ s: EditSettings, for item: LibraryItem, history supplied: EditHistory? = nil) {
        // A debounced editor save may arrive after library deletion; never recreate its sidecar.
        guard items.contains(where: { $0.id == item.id }) else { return }
        let url = editURL(item), file = historyURL(item)
        // the old sidecar is read before it is overwritten: it may still hold a pre-move `_undoHistory`
        let oldData = supplied == nil ? try? Data(contentsOf: url) : nil
        let previous = supplied == nil ? oldData.map(Self.decodeSettings) ?? EditSettings() : nil
        // small, fast and synchronous: what the photo looks like is never lost
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
        historyQueue.async {
            var history: EditHistory
            if let supplied { history = supplied } else {
                // Library paste/batch changes are undoable too; editor saves already carry their history.
                history = (pendingHistory[file] ?? Self.readHistory(file: file, legacy: oldData)).flatMap { $0.current == previous ? $0 : nil }
                    ?? EditHistory(current: previous ?? s, undo: [], redo: [])
                if let previous, s != previous { history.undo.append(previous); history.redo.removeAll() }
            }
            history.current = s
            history.undo = Array(history.undo.suffix(100))
            history.redo = Array(history.redo.suffix(100))
            let scheduled = pendingHistory[file] != nil
            pendingHistory[file] = history
            if !scheduled {
                historyQueue.asyncAfter(deadline: .now() + 0.2) { Self.writePendingHistory(file) }
            }
        }
    }

    /// Writes waiting history now (one file, or all). On `historyQueue` only.
    nonisolated private static func writePendingHistory(_ only: URL? = nil) {
        let files = only.map { [$0] } ?? Array(pendingHistory.keys)
        for file in files {
            guard let history = pendingHistory.removeValue(forKey: file) else { continue }
            if let data = try? JSONEncoder().encode(history) { try? data.write(to: file, options: .atomic) }
        }
    }

    /// The editor is closing: write its history now instead of in up to 2 s.
    func flushHistory() {
        historyQueue.async { Self.writePendingHistory() }
    }

    private var resignObserver: NSObjectProtocol?

    func delete(_ list: [LibraryItem]) {
        for item in list { delete(item) }
    }

    /// Puts `edits` on every photo in `list`. `keepOwn` keeps each photo's own crop, straighten, rotation and masks
    /// (those belong to one picture), so only the look is copied; `masks` then copies the masks too (worked out again
    /// on each photo) while still keeping each photo's crop.
    func apply(_ edits: EditSettings, to list: [LibraryItem], keepOwn: Bool, masks pasteMasks: Bool = false) {
        for item in list {
            var s = edits
            let own = settings(for: item)
            s.lensBlur = own.lensBlur  // focus belongs to this photo
            s.setOn(.lensBlur, own.isOn(.lensBlur))
            if !keepOwn, let id = own.lensBlur.maskID, let focus = own.masks.first(where: { $0.id == id }) {
                s.masks.removeAll { $0.id == id }; s.masks.append(focus)
            }
            s.heals = own.heals   // heals are made for one photo's pixels: always keep each photo's own
            s.aiDenoise = own.aiDenoise   // so is AI Denoise (a clean each): pasting never starts or drops one
            s.setOn(.heal, own.isOn(.heal))   // Heal's on/off belongs with the photo's own heals
            if keepOwn && pasteMasks {
                // the clipboard's masks, adapted to this photo, plus this photo's own Lens Blur focus mask
                let focus = own.lensBlur.maskID.flatMap { id in own.masks.first { $0.id == id } }
                s.masks = edits.masks.filter { $0.id != edits.lensBlur.maskID }.forAnotherPhoto + (focus.map { [$0] } ?? [])
            } else if !keepOwn {
                s.masks = s.masks.forAnotherPhoto
            }
            if keepOwn {
                if !pasteMasks { s.masks = own.masks }
                // crop, straighten, turns, flips and perspective all belong to one picture (21 Oct review: flips and
                // the Transform sliders used to be pasted over)
                s.take(.crop, from: own)
            }
            save(s, for: item)
            refreshThumbnail(item)
        }
    }

    /// "Choose…": pastes only the ticked tools of `edits` onto every photo in `list`; everything else stays each
    /// photo's own (heals, Lens Blur and its focus mask, AI Denoise's clean), like the editor's Paste some edits.
    func apply(_ sections: Set<EditSection>, from edits: EditSettings, to list: [LibraryItem]) {
        for item in list {
            let own = settings(for: item)
            var s = own
            for sec in EditSection.allCases where sections.contains(sec) && sec.canPaste { s.take(sec, from: edits) }
            if sections.contains(.masks) {
                let focus = own.lensBlur.maskID.flatMap { id in own.masks.first { $0.id == id } }
                s.masks = edits.masks.filter { $0.id != edits.lensBlur.maskID }.forAnotherPhoto + (focus.map { [$0] } ?? [])
            }
            s.aiDenoise = own.aiDenoise
            save(s, for: item)
            refreshThumbnail(item)
        }
    }

    // MARK: AI Denoise for many photos

    /// Cleans the first `denoiseBatchCap` of `list` with AI Denoise, one after another, then sets it to `strength` on
    /// each. Photos already cleaned only get the strength.
    func cleanWithAIDenoise(_ list: [LibraryItem], strength: Double) {
        guard EditSession.hasDenoiseModel, !list.isEmpty else { return }
        batchQueue = list.prefix(Self.denoiseBatchCap).map(\.id)
        batchTotal = batchQueue.count
        batchStrength = strength
        batchCancel = false
        saveBatch()
        runBatch()
    }

    /// A batch that paused (Lumen left the screen, or was swiped away and opened again) carries on.
    func continueDenoiseBatch() {
        batchCancel = false
        batchPausing = false
        runBatch()
    }

    func cancelDenoiseBatch() {
        batchCancel = true
        batchQueue = []
        saveBatch()
        if !batchRunning { denoiseBatch = nil }
    }

    private func saveBatch() {
        let d = UserDefaults.standard
        d.set(batchQueue.map(\.uuidString), forKey: "denoiseBatchQueue")
        d.set(batchTotal, forKey: "denoiseBatchTotal")
        d.set(batchStrength, forKey: "denoiseBatchStrength")
    }

    /// At launch: a batch left from before shows as paused (it carries on when asked, so a closure by iOS doesn't loop),
    /// and cleans paused in the editor are listed for the library's "Continue".
    func restoreDenoiseWork() {
        let d = UserDefaults.standard
        batchQueue = (d.stringArray(forKey: "denoiseBatchQueue") ?? []).compactMap(UUID.init).filter { id in items.contains { $0.id == id } }
        batchTotal = max(batchQueue.count, d.integer(forKey: "denoiseBatchTotal"))
        batchStrength = d.object(forKey: "denoiseBatchStrength") as? Double ?? 100
        if let first = batchQueue.first, let item = self.item(first) {
            denoiseBatch = DenoiseBatch(done: batchTotal - batchQueue.count, count: batchTotal, fraction: 0, name: item.displayName, paused: true)
        }
        refreshPausedCleans()
        guard batchObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        batchObservers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.batchPausing = true
        })
        batchObservers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPausedCleans()
                // a batch the background paused carries on by itself
                if self.denoiseBatch?.paused == true, !self.batchRunning, !self.batchQueue.isEmpty, self.batchPausedByBackground {
                    self.continueDenoiseBatch()
                }
            }
        })
    }
    private var batchPausedByBackground = false

    func refreshPausedCleans() {
        let paused = DenoiseStore.pausedCleans()
        pausedCleans = paused.compactMap { p in
            guard let item = items.first(where: { $0.fileName == p.photo }), !batchQueue.contains(item.id) else { return nil }
            return (item, p.fraction)
        }
    }

    private func runBatch() {
        guard !batchRunning else { return }
        guard let id = batchQueue.first, let item = self.item(id) else {
            if denoiseBatch != nil, !batchQueue.isEmpty { batchQueue.removeFirst(); saveBatch(); runBatch(); return }
            denoiseBatch = nil
            UIApplication.shared.isIdleTimerDisabled = false
            batchDenoiseQueue.async { EditSession.releaseDenoiseModel() }
            return
        }
        batchRunning = true
        batchPausing = false
        batchPausedByBackground = false
        let done = batchTotal - batchQueue.count, total = batchTotal, strength = batchStrength
        denoiseBatch = DenoiseBatch(done: done, count: total, fraction: 0, name: item.displayName, paused: false)
        UIApplication.shared.isIdleTimerDisabled = true
        let url = fileURL(item)
        let hdr = settings(for: item).hdr
        Diagnostics.shared.note("denoise batch: \(done + 1) of \(total)")
        batchDenoiseQueue.async { [weak self] in
            // the model stays loaded from one photo to the next (released when the batch ends)
            let session = EditSession(url: url, expandHDR: hdr)
            let mp = session.map { Double($0.nativeSize.width * $0.nativeSize.height) / 1_000_000 } ?? 24
            let result: DenoiseOutcome?? = HeavyWork.shared.run(.denoise, megapixels: mp, long: true) { () -> DenoiseOutcome? in
                session?.makeDenoised(progress: { p in
                    Task { @MainActor [weak self] in self?.denoiseBatch?.fraction = p }
                }, pause: { [weak self] in self?.batchPausing ?? true },
                   cancelled: { [weak self] in self?.batchCancel ?? true },
                   log: { Diagnostics.shared.note($0) })
            }
            let outcome: DenoiseOutcome = (result ?? nil) ?? .failed
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.batchRunning = false
                switch outcome {
                case .done:
                    var s = self.settings(for: item)   // as it is now (it may have been edited meanwhile)
                    s.aiDenoise = strength
                    self.save(s, for: item)
                    self.refreshThumbnail(item)
                    if self.batchQueue.first == id { self.batchQueue.removeFirst() }
                    self.saveBatch()
                    self.runBatch()
                case .paused:
                    self.batchPausedByBackground = true
                    self.denoiseBatch?.paused = true
                    UIApplication.shared.isIdleTimerDisabled = false
                case .cancelled:
                    self.denoiseBatch = nil
                    UIApplication.shared.isIdleTimerDisabled = false
                    self.batchDenoiseQueue.async { EditSession.releaseDenoiseModel() }
                case .failed:
                    Diagnostics.shared.note("denoise batch: \(item.displayName) failed, going on")
                    if self.batchQueue.first == id { self.batchQueue.removeFirst() }
                    self.saveBatch()
                    self.lastError = "AI Denoise couldn't clean \(item.displayName)."
                    self.runBatch()
                }
            }
        }
    }

    // MARK: Batch export

    /// Exports every photo in `list` one after another in the background, then offers them in `batchResult`.
    func export(_ list: [LibraryItem], options o: ExportOptions) {
        guard batchProgress == nil, !list.isEmpty else { return }
        batchProgress = (0, list.count)
        // editorSettings: a RAW never opened exports as the editor would show it (HDR on)
        let jobs = list.map { (url: fileURL($0), edits: editorSettings(for: $0), name: $0.displayName) }
        UIApplication.shared.isIdleTimerDisabled = true   // a long batch must not stop when the screen locks
        let patches = HealStore.retain(Set(jobs.flatMap { $0.edits.heals.map(\.id) }))
        let dir = fm.temporaryDirectory.appendingPathComponent("lumen-export-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        exportQueue.async {
            defer { patches.close() }
            var urls: [URL] = []
            var used = Set<String>()
            for (n, job) in jobs.enumerated() {
                autoreleasepool {
                    guard let session = EditSession(url: job.url, expandHDR: job.edits.hdr && o.hdr) else { return }
                    let mp = Double(session.nativeSize.width * session.nativeSize.height) / 1_000_000
                    let started = Date()
                    let made = HeavyWork.shared.run(.export, megapixels: mp, {
                        session.renderData(job.edits, format: o.format, quality: o.quality / 100, maxEdge: o.maxEdge, includeHDR: o.hdr)
                    }) ?? nil
                    Diagnostics.shared.note(String(format: "batch export %d of %d %@ in %.1f s (%.0f MP)", n + 1, jobs.count,
                                                   made == nil ? "failed" : "done", Date().timeIntervalSince(started), mp))
                    guard let data = made else { return }
                    var name = job.name + "-lumen", k = 2
                    // the file system ignores case: IMG_1 and img_1 would overwrite each other
                    while used.contains(name.lowercased()) { name = "\(job.name)-lumen-\(k)"; k += 1 }
                    used.insert(name.lowercased())
                    let u = dir.appendingPathComponent("\(name).\(o.format.ext)")
                    if (try? data.write(to: u, options: .atomic)) != nil { urls.append(u) }
                }
                // each 24-48 MP photo leaves large GPU buffers in the shared context: let them go before the next
                LumenGPU.context.clearCaches()
                Task { @MainActor [weak self] in self?.batchProgress = (n + 1, jobs.count) }
            }
            let done = urls
            Task { @MainActor [weak self] in
                UIApplication.shared.isIdleTimerDisabled = false
                guard let self else { return }
                self.batchProgress = nil
                if DemoMode.isOn { DemoMode.log("batch exported \(done.count) of \(jobs.count)") }
                if done.count < jobs.count { self.lastError = "\(jobs.count - done.count) of \(jobs.count) photos could not be exported." }
                if !done.isEmpty { self.batchResult = BatchResult(urls: done) }
            }
        }
    }

    /// Saves exported files to the Photos library. Returns a message for the user.
    func saveToPhotos(_ urls: [URL]) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return "Photos access was denied. Enable it in Settings, or use Share → Save to Files."
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for u in urls { PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: u, options: nil) }
            }
            return "Saved \(urls.count) photo\(urls.count == 1 ? "" : "s") to Photos."
        } catch {
            return "Couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: Dates

    /// When the photo was taken, from its EXIF (RAW files included); nil if the file doesn't say.
    nonisolated static func dateTaken(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let text = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
                ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: text)
    }

    /// Libraries from before dates were kept: read them from the files once, in the background.
    private func fillInDatesTaken() {
        let missing = items.filter { $0.taken == nil }.map { (id: $0.id, url: fileURL($0)) }
        guard !missing.isEmpty else { return }
        thumbQueue.async {
            let found = missing.compactMap { m in Self.dateTaken(m.url).map { (m.id, $0) } }
            guard !found.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (id, d) in found { if let i = self.items.firstIndex(where: { $0.id == id }) { self.items[i].taken = d } }
                self.saveIndex()
            }
        }
    }

    /// Keep references in other photos, presets and the clipboard. Fail closed when a retained
    /// sidecar is unreadable, rather than deleting pixels still needed by another photo.
    private func retainedHealIDs(excluding item: LibraryItem) -> Set<UUID>? {
        var ids = Set(userPresets.flatMap { $0.settings.heals.map(\.id) })
        ids.formUnion(clipboard?.heals.map(\.id) ?? [])
        for other in items where other.id != item.id {
            for url in [editURL(other), historyURL(other)] {
                guard fm.fileExists(atPath: url.path) else { continue }
                guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
                ids.formUnion(HealStore.references(in: json))
            }
        }
        return ids
    }

    func delete(_ item: LibraryItem) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        // finish queued history writes first: they may name Heal patches, and must not recreate the file afterwards
        historyQueue.sync { Self.writePendingHistory() }
        var patches = HealStore.markDeleted(owner: fileURL(item))
        for url in [editURL(item), historyURL(item)] {
            if let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) {
                patches.formUnion(HealStore.references(in: json))
            }
        }
        // reading every other photo's edits is only needed when this one has Heal patches to clean up
        let retained = patches.isEmpty ? Set<UUID>() : retainedHealIDs(excluding: item)
        DenoiseStore.remove(fileURL(item))
        for u in [fileURL(item), thumbURL(item), editURL(item), historyURL(item)] { try? fm.removeItem(at: u) }
        // The thumbnail queue is serial: this runs after any render already in flight for this photo.
        let thumb = thumbURL(item)
        thumbQueue.async { try? FileManager.default.removeItem(at: thumb) }
        items.removeAll { $0.id == item.id }
        saveIndex()
        if let retained { HealStore.remove(patches.subtracting(retained)) }
        else { lastError = "Photo removed, but its Heal patches could not safely be cleaned up because another photo's edits are unreadable." }
    }

    // MARK: Rating / flags

    func setRating(_ item: LibraryItem, _ rating: Int) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].rating = items[i].rating == rating ? 0 : rating
        saveIndex()
    }

    func setFlag(_ item: LibraryItem, _ flag: Int) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].flag = items[i].flag == flag ? 0 : flag
        saveIndex()
    }

    // MARK: User presets

    func addUserPreset(name: String, from edits: EditSettings) {
        var s = edits
        s.masks = []
        s.heals = []
        s.straighten = 0
        s.quarterTurns = 0
        s.cropAspect = 0
        s.cropL = 0; s.cropT = 0; s.cropR = 1; s.cropB = 1
        userPresets.append(UserPreset(name: name, settings: s))
        savePresets()
    }

    func deleteUserPreset(_ p: UserPreset) {
        userPresets.removeAll { $0.id == p.id }
        savePresets()
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(userPresets) {
            try? data.write(to: root.appendingPathComponent("presets.json"), options: .atomic)
        }
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) {
        // CI demo runs expect the photos at once
        if DemoMode.isOn {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { try add(copying: url, name: url.deletingPathExtension().lastPathComponent) }
                catch { lastError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)" }
            }
            return
        }
        // Copies happen off the main thread (50 RAWs from an SD card froze the app while they copied), through a file
        // coordinator so iCloud Drive files are downloaded first instead of failing, with the same progress bar as Photos.
        guard !urls.isEmpty else { return }
        if activeImports == 0 { importTotal = 0; importDone = 0 }
        activeImports += 1
        importing = true
        importTotal += urls.count
        let dir = filesDir
        Task.detached(priority: .userInitiated) { [weak self] in
            for url in urls {
                let result = Self.copyIn(url, to: dir)
                await MainActor.run {
                    guard let self else { return }
                    self.importDone += 1
                    switch result {
                    case .success(let (id, fileName, taken)):
                        let item = LibraryItem(id: id, displayName: url.deletingPathExtension().lastPathComponent,
                                               fileName: fileName, added: Date(), taken: taken)
                        self.items.insert(item, at: 0)
                        self.saveIndex()
                        self.refreshThumbnail(item)
                    case .failure(let error):
                        self.lastError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.activeImports -= 1
                if self.activeImports == 0 { self.importing = false }
            }
        }
    }

    /// Copies one picked file into the library (off the main thread). A copy that fails part-way is removed.
    nonisolated private static func copyIn(_ url: URL, to dir: URL) -> Result<(UUID, String, Date?), Error> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let ext = url.pathExtension.lowercased()
        let fileName = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let dst = dir.appendingPathComponent(fileName)
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readable in
            do { try FileManager.default.copyItem(at: readable, to: dst) } catch { failure = error }
        }
        if let error = failure ?? coordError {
            try? FileManager.default.removeItem(at: dst)
            return .failure(error)
        }
        return .success((id, fileName, dateTaken(dst)))
    }

    func importPicked(_ picked: [PhotosPickerItem]) async {
        guard !picked.isEmpty else { return }
        // A second import can start while one is running: add to the running counts instead of resetting them.
        if activeImports == 0 { importTotal = 0; importDone = 0 }
        activeImports += 1
        importing = true
        importTotal += picked.count
        defer {
            activeImports -= 1
            if activeImports == 0 { importing = false }
        }
        // Asking for read access lets us fetch the true RAW/ProRAW original; the picker works without it too.
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        let canFetch = status == .authorized || status == .limited
        for p in picked {
            defer { importDone += 1 }
            if canFetch, let id = p.itemIdentifier, await importAsset(identifier: id) { continue }
            // Fallback: whatever the picker hands us (RAW file when it has one, otherwise the rendered photo).
            if let file = try? await p.loadTransferable(type: PickedFile.self) {
                do { try add(copying: file.url, name: file.name) } catch { lastError = error.localizedDescription }
                try? fm.removeItem(at: file.url)
            } else {
                lastError = "Couldn't read that photo from your library."
            }
        }
    }

    /// Pulls the original resource (the DNG/ProRAW if there is one) out of the Photos library.
    private func importAsset(identifier: String) async -> Bool {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return false }
        let resources = PHAssetResource.assetResources(for: asset)
        let raw = resources.first { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }
        guard let res = raw ?? resources.first(where: { $0.type == .photo }) ?? resources.first else { return false }

        let tmp = fm.temporaryDirectory.appendingPathComponent(res.originalFilename)
        try? fm.removeItem(at: tmp)
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        defer { try? fm.removeItem(at: tmp) }
        do {
            try await PHAssetResourceManager.default().writeData(for: res, toFile: tmp, options: opts)
            try add(copying: tmp, name: URL(fileURLWithPath: res.originalFilename).deletingPathExtension().lastPathComponent)
            return true
        } catch {
            // No alert here: the caller falls back to the picker's copy and reports if that fails too.
            return false
        }
    }

    private func add(copying src: URL, name: String) throws {
        let id = UUID()
        let ext = src.pathExtension.lowercased()
        let fileName = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let dst = filesDir.appendingPathComponent(fileName)
        try fm.copyItem(at: src, to: dst)
        let item = LibraryItem(id: id, displayName: name, fileName: fileName, added: Date(), taken: Self.dateTaken(dst))
        items.insert(item, at: 0)
        saveIndex()
        refreshThumbnail(item)
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    // MARK: Thumbnails

    func refreshThumbnail(_ item: LibraryItem) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        let src = fileURL(item), dst = thumbURL(item), id = item.id
        let settings = settings(for: item)
        let patches = HealStore.retain(Set(settings.heals.map(\.id)))
        thumbQueue.async {
            defer { patches.close() }
            guard let session = EditSession(url: src),
                  let cg = session.renderCGImage(settings, maxEdge: 640),
                  let jpg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) else {
                // the file can't be decoded: say so on the thumbnail instead of spinning forever
                if FileManager.default.fileExists(atPath: src.path) {
                    Task { @MainActor [weak self] in self?.unreadable.insert(id) }
                }
                return
            }
            guard FileManager.default.fileExists(atPath: src.path) else { return }
            try? jpg.write(to: dst, options: .atomic)
            Task { @MainActor [weak self] in
                self?.unreadable.remove(id)
                self?.thumbVersions[id, default: 0] += 1
                self?.thumbVersion += 1
            }
        }
    }
}

/// A photo handed over by the Photos picker, copied somewhere we can keep it.
struct PickedFile: Transferable {
    let url: URL
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .rawImage) { received in try Self.copy(received.file) }
        FileRepresentation(importedContentType: .image) { received in try Self.copy(received.file) }
    }

    private static func copy(_ src: URL) throws -> PickedFile {
        let ext = src.pathExtension.isEmpty ? "jpg" : src.pathExtension
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: src, to: dst)
        return PickedFile(url: dst, name: src.deletingPathExtension().lastPathComponent)
    }
}
