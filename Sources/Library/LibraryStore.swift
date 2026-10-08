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
        }
    }

    func fileURL(_ item: LibraryItem) -> URL { filesDir.appendingPathComponent(item.fileName) }
    func thumbURL(_ item: LibraryItem) -> URL { thumbsDir.appendingPathComponent("\(item.id.uuidString).jpg") }
    private func editURL(_ item: LibraryItem) -> URL { editsDir.appendingPathComponent("\(item.id.uuidString).json") }

    func item(_ id: UUID) -> LibraryItem? { items.first { $0.id == id } }

    // MARK: Edits

    func settings(for item: LibraryItem) -> EditSettings {
        guard let data = try? Data(contentsOf: editURL(item)),
              let s = try? JSONDecoder().decode(EditSettings.self, from: data) else { return EditSettings() }
        return s
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
        s.cropZoom = 1
        s.cropX = 0
        s.cropY = 0
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
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        let canFetch = status == .authorized || status == .limited
        for p in picked {
            if canFetch, let id = p.itemIdentifier, await importAsset(identifier: id) { continue }
            // Fallback: whatever version the picker hands us (may not be the RAW original).
            if let data = try? await p.loadTransferable(type: Data.self) {
                let ext = p.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let tmp = fm.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString).\(ext)")
                do {
                    try data.write(to: tmp)
                    try add(copying: tmp, name: "Photo")
                    try? fm.removeItem(at: tmp)
                } catch { lastError = error.localizedDescription }
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
            lastError = error.localizedDescription
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
        var settings = settings(for: item)
        settings.masks = settings.masks.filter { $0.kind != .subject && $0.kind != .background } // avoid Vision per thumbnail
        thumbQueue.async {
            guard let session = EditSession(url: src),
                  let cg = session.render(settings, maxEdge: 600),
                  let jpg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) else { return }
            try? jpg.write(to: dst, options: .atomic)
            Task { @MainActor [weak self] in self?.thumbVersion += 1 }
        }
    }
}
