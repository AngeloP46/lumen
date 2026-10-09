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

/// Imported originals live in Documents/Library/files; edits are JSON sidecars in Documents/Library/edits.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var thumbVersion = 0
    @Published private(set) var userPresets: [UserPreset] = []
    @Published var clipboard: EditSettings?
    @Published var lastError: String?
    @Published var importing = false
    @Published var importTotal = 0
    @Published var importDone = 0
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

    init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Library", isDirectory: true)
        filesDir = root.appendingPathComponent("files", isDirectory: true)
        thumbsDir = root.appendingPathComponent("thumbs", isDirectory: true)
        editsDir = root.appendingPathComponent("edits", isDirectory: true)
        for d in [filesDir, thumbsDir, editsDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
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
        return Self.decodeSettings(data)
    }

    private static func decodeSettings(_ data: Data) -> EditSettings {
        let decoder = JSONDecoder()
        if let s = try? decoder.decode(EditSettings.self, from: data) { return s }
        // Older sidecar: lay its values over today's defaults, dropping anything that no longer fits.
        // The template has one mask so masks, components and their adjustments get today's defaults too.
        var template = EditSettings()
        template.masks = [Mask.make(.brush)]
        guard var old = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(template))) as? [String: Any]
        else { return EditSettings() }
        old = old.filter { defaults[$0.key] != nil }
        let maskTemplate = defaults["masks"] ?? [Any]()
        defaults["masks"] = [Any]()
        for dropping in [[], ["masks"]] as [[String]] {
            var merged = defaults
            for (k, v) in old where !dropping.contains(k) {
                merged[k] = Self.overlay(v, on: k == "masks" ? maskTemplate : defaults[k] ?? v)
            }
            if let d = try? JSONSerialization.data(withJSONObject: merged),
               let s = try? decoder.decode(EditSettings.self, from: d) { return s }
        }
        return EditSettings()
    }

    /// Lays old JSON values over a template: objects are merged key by key (keys the template lacks are dropped),
    /// array elements are each merged over the template's first element.
    private static func overlay(_ value: Any, on template: Any) -> Any {
        if let v = value as? [String: Any], let t = template as? [String: Any] {
            var out = t
            for (k, x) in v { if let tx = t[k] { out[k] = overlay(x, on: tx) } }
            return out
        }
        if let v = value as? [Any], let t = (template as? [Any])?.first, t is [String: Any] {
            return v.map { overlay($0, on: t) }
        }
        return value
    }

    func save(_ s: EditSettings, for item: LibraryItem) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: editURL(item), options: .atomic) }
    }

    func delete(_ list: [LibraryItem]) {
        for item in list { delete(item) }
    }

    /// Puts `edits` on every photo in `list`. `keepOwn` keeps each photo's own crop, straighten, rotation and masks
    /// (those belong to one picture), so only the look is copied.
    func apply(_ edits: EditSettings, to list: [LibraryItem], keepOwn: Bool) {
        for item in list {
            var s = edits
            if keepOwn {
                let own = settings(for: item)
                s.masks = own.masks
                s.straighten = own.straighten
                s.quarterTurns = own.quarterTurns
                s.cropAspect = own.cropAspect
                s.cropL = own.cropL; s.cropT = own.cropT; s.cropR = own.cropR; s.cropB = own.cropB
            }
            save(s, for: item)
            refreshThumbnail(item)
        }
    }

    // MARK: Batch export

    /// Exports every photo in `list` one after another in the background, then offers them in `batchResult`.
    func export(_ list: [LibraryItem], options o: ExportOptions) {
        guard batchProgress == nil, !list.isEmpty else { return }
        batchProgress = (0, list.count)
        let jobs = list.map { (url: fileURL($0), edits: settings(for: $0), name: $0.displayName) }
        let dir = fm.temporaryDirectory.appendingPathComponent("lumen-export-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        exportQueue.async {
            var urls: [URL] = []
            var used = Set<String>()
            for (n, job) in jobs.enumerated() {
                autoreleasepool {
                    guard let session = EditSession(url: job.url, expandHDR: job.edits.hdr && o.hdr),
                          let data = session.renderData(job.edits, format: o.format, quality: o.quality / 100,
                                                        maxEdge: o.maxEdge, includeHDR: o.hdr) else { return }
                    var name = job.name + "-lumen", k = 2
                    while used.contains(name) { name = "\(job.name)-lumen-\(k)"; k += 1 }
                    used.insert(name)
                    let u = dir.appendingPathComponent("\(name).\(o.format.ext)")
                    if (try? data.write(to: u, options: .atomic)) != nil { urls.append(u) }
                }
                Task { @MainActor [weak self] in self?.batchProgress = (n + 1, jobs.count) }
            }
            let done = urls
            Task { @MainActor [weak self] in
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

    func delete(_ item: LibraryItem) {
        for u in [fileURL(item), thumbURL(item), editURL(item)] { try? fm.removeItem(at: u) }
        // The thumbnail queue is serial: this runs after any render already in flight for this photo.
        let thumb = thumbURL(item)
        thumbQueue.async { try? FileManager.default.removeItem(at: thumb) }
        items.removeAll { $0.id == item.id }
        saveIndex()
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
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try add(copying: url, name: url.deletingPathExtension().lastPathComponent) }
            catch { lastError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)" }
        }
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
        let src = fileURL(item), dst = thumbURL(item), id = item.id
        let settings = settings(for: item)
        thumbQueue.async {
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
