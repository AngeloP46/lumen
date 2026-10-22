import Foundation

/// One place that decides when memory-heavy work may run (21 Oct; the owner's 48 MP ProRAW crashes and the review that
/// followed: the 100 % copy, AI masks, a heal, Remove people, AI Denoise and exports each started on their own queue,
/// and together they went past iOS's ~3.3 GB per-app limit).
///
/// Every heavy job says roughly how much memory it needs for the photo's size. It starts at once when nothing else
/// heavy runs, or alongside others only while that still leaves a safe margin; otherwise it waits its turn. When a
/// job would start short of room, copies and models that can be made again are let go of first. Optional jobs (the
/// 100 % copy, the original copy) are skipped rather than wait or squeeze in. Waits, skips and tight starts are logged
/// for ⋯ → Send diagnostics. Light work (the preview, thumbnails, the histogram) doesn't come through here.
final class HeavyWork: @unchecked Sendable {
    static let shared = HeavyWork()

    /// What a job is, for its memory estimate.
    enum Kind: String {
        case fullSizeCopy = "100 % copy"
        case aiMasks = "AI masks"
        case heal = "heal"
        case findPeople = "finding people"
        case denoise = "AI Denoise"
        case export = "export"
        case original = "original copy"
    }

    /// Roughly what a job needs on an iPhone (MB), from the owner's diagnostics and the CI memory test: the RAW engine's
    /// full-size decode is ~50 MB per megapixel whatever is asked of it.
    static func needMB(_ kind: Kind, megapixels mp: Double) -> Int {
        switch kind {
        case .fullSizeCopy: return Int(50 * mp) + 700
        case .aiMasks: return 900
        case .heal: return Int(50 * mp) + 800
        case .findPeople: return Int(20 * mp) + 700
        case .denoise: return 1400            // the model and one strip; it reads the photo whole only with room to spare
        // owner's phone, 22 Oct: batch exports of 24 and 48 MP photos peaked at ~1.1 GB; 60 MB/MP + 800 asked for more than
        // the whole limit at 48 MP, so every photo first let go of the mask models (loaded again for the next one)
        case .export: return Int(30 * mp) + 700
        // The preview is small, but the RAW engine's full-size decode still costs ~50 MB per source megapixel (the
        // same as the 100 % copy, without its buffer). A flat 450 MB underestimated a 48 MP photo ~5x, so the
        // original copy started when it really couldn't fit (checklist A8; phone 0.1.465: 892-1001 MB between
        // photos after a clean).
        case .original: return Int(50 * mp) + 100
        }
    }

    /// The memory never left free while jobs share the phone (MB).
    static let marginMB = 700

    private struct Running { let id: Int; let kind: Kind; let need: Int; let long: Bool }
    private let condition = NSCondition()
    private var running: [Running] = []
    private var nextID = 0
    /// Let go of what can be made again (GPU caches, models not in use). Set by the app; any thread.
    nonisolated(unsafe) static var release: ((Kind) -> Void)?
    /// Logging (the app points it at Diagnostics).
    nonisolated(unsafe) static var note: ((String) -> Void)?
    /// Memory Lumen may still use (MB); the app points it at os_proc_available_memory.
    nonisolated(unsafe) static var availableMB: () -> Int = { 1 << 20 }

    private func admits(_ need: Int, long: Bool) -> Bool {
        if running.isEmpty { return true }
        if long && running.contains(where: \.long) { return false }
        return Self.availableMB() - need >= Self.marginMB
    }

    /// Runs `work` on the calling (background) thread when there is room for it, and returns its result. `long` = a
    /// job of a minute or more (AI Denoise): only one at a time, and others may still start beside it when there is
    /// room. `optional`: returns nil at once instead of waiting or starting short of memory.
    func run<T>(_ kind: Kind, megapixels: Double, long: Bool = false, optional: Bool = false, _ work: () -> T) -> T? {
        let need = Self.needMB(kind, megapixels: megapixels)
        condition.lock()
        var waited = false
        while !admits(need, long: long) {
            if optional {
                condition.unlock()
                Self.note?("\(kind.rawValue): skipped, \(Self.availableMB()) MB free, ~\(need) MB needed beside \(runningNames)")
                return nil
            }
            if !waited { Self.note?("\(kind.rawValue): waiting for \(runningNames)"); waited = true }
            condition.wait(until: Date().addingTimeInterval(0.5))
        }
        let alone = running.isEmpty
        nextID += 1
        let me = Running(id: nextID, kind: kind, need: need, long: long)
        running.append(me)
        condition.unlock()
        // short of room even alone: what can be made again goes first
        if alone, Self.availableMB() < need + Self.marginMB {
            if optional {
                // an optional job (the 100 % copy, the original copy) is not worth letting go of models for, or
                // sleeping on the shared work queue for (it stalled the next photo's decode by 3 s): it starts if there
                // is room, else it is skipped at once
                let free = Self.availableMB()
                if free < need {
                    finish(me)
                    Self.note?("\(kind.rawValue): skipped, only \(free) MB free (~\(need) MB needed)")
                    return nil
                }
            } else {
                Self.release?(kind)
                // what the app just let go of (the 100 % copy, GPU caches) can take a moment to come back
                for _ in 0..<6 where Self.availableMB() < need { Thread.sleep(forTimeInterval: 0.5) }
                let free = Self.availableMB()
                if free < need { Self.note?("\(kind.rawValue): starting with only \(free) MB free (~\(need) MB needed)") }
            }
        }
        defer { finish(me) }
        return work()
    }

    private var runningNames: String {
        running.isEmpty ? "nothing" : running.map(\.kind.rawValue).joined(separator: ", ")
    }

    private func finish(_ job: Running) {
        condition.lock()
        running.removeAll { $0.id == job.id }
        condition.broadcast()
        condition.unlock()
    }
}
