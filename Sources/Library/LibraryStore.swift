import SwiftUI
import Photos
import PhotosUI
import UniformTypeIdentifiers

struct LibraryItem: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var fileName: String
    var added: Date
    var rating: Int = 0     // 0...5
    var flag: Int = 0       // 1 = pick, -1 = reject
}

private let thumbQueue = DispatchQueue(label: "lumen.thumbs", qos: .utility)

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
        if let data = try? Data(contentsOf: root.appendingPathComponent("index.json")),
           let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data) {
            items = decoded
        }
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

    func delete(_ item: LibraryItem) {
        for u in [fileURL(item), thumbURL(item), editURL(item)] { try? fm.removeItem(at: u) }
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
        importing = true
        importTotal = picked.count
        importDone = 0
        defer { importing = false }
        // Asking for read access lets us fetch the true RAW/ProRAW original; the picker works without it too.
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        let canFetch = status == .authorized || status == .limited
        for p in picked {
            defer { importDone += 1 }
            if canFetch, let id = p.itemIdentifier, await importAsset(identifier: id) { continue }
            // Fallback: whatever the picker hands us (RAW file when it has one, otherwise the rendered photo).
            if let file = try? await p.loadTransferable(type: PickedFile.self) {
                do {
                    try add(copying: file.url, name: file.name)
                    try? fm.removeItem(at: file.url)
                } catch { lastError = error.localizedDescription }
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
        do {
            try await PHAssetResourceManager.default().writeData(for: res, toFile: tmp, options: opts)
            try add(copying: tmp, name: URL(fileURLWithPath: res.originalFilename).deletingPathExtension().lastPathComponent)
            try? fm.removeItem(at: tmp)
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
        try fm.copyItem(at: src, to: filesDir.appendingPathComponent(fileName))
        let item = LibraryItem(id: id, displayName: name, fileName: fileName, added: Date())
        items.insert(item, at: 0)
        saveIndex()
        refreshThumbnail(item)
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
        }
    }

    // MARK: Thumbnails

    func refreshThumbnail(_ item: LibraryItem) {
        let src = fileURL(item), dst = thumbURL(item)
        let settings = settings(for: item)
        thumbQueue.async {
            guard let session = EditSession(url: src),
                  let cg = session.renderCGImage(settings, maxEdge: 640),
                  let jpg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) else { return }
            try? jpg.write(to: dst, options: .atomic)
            Task { @MainActor [weak self] in self?.thumbVersion += 1 }
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
