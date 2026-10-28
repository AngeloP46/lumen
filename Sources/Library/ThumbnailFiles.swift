import Foundation

/// A completed thumbnail carries its renderer revision in its filename. Progress survives an interrupted batch;
/// old JPEGs remain available for display until their replacements have been written atomically.
enum ThumbnailFiles {
    static let rendererRevision = 4
    enum Quality: String { case basic, refined }
    static func current(in directory: URL, id: UUID, quality: Quality = .refined) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-engine-\(rendererRevision)-\(quality.rawValue).jpg")
    }
    static func previousCurrent(in directory: URL, id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-engine-\(EditSettings.currentFormat).jpg")
    }
    static func legacy(in directory: URL, id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }
    static func all(in directory: URL, id: UUID) -> [URL] {
        [current(in: directory, id: id), current(in: directory, id: id, quality: .basic),
         previousCurrent(in: directory, id: id), legacy(in: directory, id: id)]
    }
    static func date(_ file: URL) -> Date? {
        guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return nil }
        return values.contentModificationDate
    }
    /// The newest completed rendition wins; equal timestamps prefer refined. A crash between atomic
    /// installation and old-file cleanup cannot promote an older refined image over a new basic one.
    static func completed(in directory: URL, id: UUID) -> (url: URL, quality: Quality, date: Date)? {
        let candidates: [(URL, Quality)] = [(current(in: directory, id: id), .refined),
            (current(in: directory, id: id, quality: .basic), .basic)]
        var result: (URL, Quality, Date)?
        for (url, quality) in candidates {
            guard let stamp = date(url) else { continue }
            if result == nil || stamp > result!.2 { result = (url, quality, stamp) }
        }
        return result
    }
    static func display(in directory: URL, id: UUID) -> URL {
        if let done = completed(in: directory, id: id) { return done.url }
        let old = previousCurrent(in: directory, id: id)
        return date(old) == nil ? legacy(in: directory, id: id) : old
    }
    static func needsRefresh(in directory: URL, id: UUID, recipe: URL? = nil) -> Bool {
        guard let done = completed(in: directory, id: id) else { return true }
        return recipe.flatMap(date).map { $0 > done.date } ?? false
    }
    static func needsRefinement(in directory: URL, id: UUID, recipe: URL? = nil) -> Bool {
        needsRefresh(in: directory, id: id, recipe: recipe) || completed(in: directory, id: id)?.quality != .refined
    }
    static func requiresRefinement(_ edits: EditSettings) -> Bool {
        let s = edits.effective
        return s.lensBlur.amount > 0 || s.masks.contains { m in
            m.amount > 0 && !m.adjust.isNeutral && m.components.contains { $0.amount > 0 && $0.kind.needsAnalysis }
        }
    }
    static func hasRequiredDenoise(_ edits: EditSettings, denoiseAvailable: Bool) -> Bool {
        edits.effective.aiDenoise <= 0 || denoiseAvailable
    }
    static func backgroundQuality(_ edits: EditSettings, denoiseAvailable: Bool) -> Quality {
        requiresRefinement(edits) || !hasRequiredDenoise(edits, denoiseAvailable: denoiseAvailable) ? .basic : .refined
    }
    static func basicRecipe(_ edits: EditSettings) -> EditSettings {
        var s = edits.effective
        s.lensBlur.amount = 0
        // Omit the whole dependent mask, including inverse/intersection semantics, until analysis is ready.
        s.masks.removeAll { $0.components.contains { $0.amount > 0 && $0.kind.needsAnalysis } }
        return s
    }
    static func install(_ data: Data, in directory: URL, id: UUID, quality: Quality) throws {
        let target = current(in: directory, id: id, quality: quality)
        try data.write(to: target, options: .atomic)
        for old in all(in: directory, id: id) where old != target { try? FileManager.default.removeItem(at: old) }
    }
}

/// Only IDs are queued. A replacement requested during an active render is one deferred job, never a second active job.
struct ThumbnailWorkQueue {
    private var pending: [UUID] = []
    private var queued = Set<UUID>()
    private(set) var active: UUID?
    private var completed = 0
    var pendingCount: Int { pending.count }
    mutating func enqueue(_ id: UUID, priority: Bool = false, replaceActive: Bool = false) {
        guard active != id || replaceActive else { return }
        if queued.contains(id) {
            if priority { pending.removeAll { $0 == id }; pending.insert(id, at: 0) }
            return
        }
        queued.insert(id)
        if priority { pending.insert(id, at: 0) } else { pending.append(id) }
    }
    mutating func next() -> UUID? {
        guard active == nil, !pending.isEmpty else { return nil }
        let id = pending.removeFirst(); queued.remove(id); active = id
        return id
    }
    mutating func finish(_ id: UUID, pressure: Bool = false) -> Double {
        guard active == id else { return 0 }
        active = nil; completed += 1
        return pressure ? 2 : completed % 4 == 0 ? 0.15 : 0
    }
    mutating func remove(_ id: UUID) { pending.removeAll { $0 == id }; queued.remove(id) }
}

/// Install checks and generation changes share a lock: an old basic render cannot replace an editor refinement.
final class ThumbnailGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [UUID: UInt64] = [:]
    private var deleted = Set<UUID>()
    private var enabled = false
    func setEnabled(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
    var canRender: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    func token(_ id: UUID) -> UInt64 { lock.lock(); defer { lock.unlock() }; return generations[id, default: 0] }
    @discardableResult func advance(_ id: UUID) -> UInt64 {
        lock.lock(); defer { lock.unlock() }; generations[id, default: 0] &+= 1
        return generations[id]!
    }
    func remove(_ id: UUID) { lock.lock(); deleted.insert(id); generations[id, default: 0] &+= 1; lock.unlock() }
    func isCurrent(_ id: UUID, _ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return !deleted.contains(id) && generations[id, default: 0] == token
    }
    func install(_ data: Data, in directory: URL, id: UUID, token: UInt64, quality: ThumbnailFiles.Quality) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !deleted.contains(id), generations[id, default: 0] == token else { return false }
        try ThumbnailFiles.install(data, in: directory, id: id, quality: quality)
        return true
    }
}
