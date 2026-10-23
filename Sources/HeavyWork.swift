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
        case preview = "preview decode"
        case healModel = "Heal model"
    }

    /// Roughly what a job needs on an iPhone (MB), from the owner's diagnostics and the CI memory test: the RAW engine's
    /// full-size decode is ~50 MB per megapixel whatever is asked of it.
    static func needMB(_ kind: Kind, megapixels mp: Double) -> Int {
        switch kind {
        case .fullSizeCopy: return DetailCopy.needMB(megapixels: mp)   // measured on the phone, see CopyPlan.swift
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
        // the editor decoding the photo again after undo, HDR or a heal: ~170-300 MB net on the owner's phone, more
        // while the old and the new copy exist together (23 Oct)
        case .preview: return Int(8 * mp) + 600
        // loading the Heal model: with the Neural Engine it went up ~2.2-2.8 GB for a second or two (owner's phone, 23 Oct:
        // 533 -> 2769 MB). On the GPU (0.1.581 on) it loads in about a second for ~150 MB (262 -> 413 MB); 2800 kept refusing
        // Heal with 2.76 GB free (0.1.608, three failed heals in a row). 1200 leaves the GPU load plenty of room.
        case .healModel: return 1200
        }
    }

    /// The memory never left free while jobs share the phone (MB).
    static let marginMB = 700
    /// The model's load is a short spike that is over before anything else can start (the others wait for it), so it
    /// asks for less to spare than a long job does.
    static func marginMB(for kind: Kind) -> Int { kind == .healModel ? 100 : marginMB }

    private struct Running { let id: Int; let kind: Kind; let need: Int; let long: Bool }
    private let condition = NSCondition()
    private var running: [Running] = []
    private var nextID = 0
    /// Let go of what can be made again (GPU caches, models not in use). Set by the app; any thread.
    nonisolated(unsafe) static var release: ((Kind) -> Void)?
    /// Whether Lumen is on screen (the app keeps it current). iOS refuses GPU work in the background and Core Image does not
    /// throw: a render started there comes out black or partial (quality checklist B2). Heavy jobs wait for the screen.
    nonisolated(unsafe) static var isForeground = true
    /// Logging (the app points it at Diagnostics).
    nonisolated(unsafe) static var note: ((String) -> Void)?
    /// Memory Lumen may still use (MB); the app points it at os_proc_available_memory.
    nonisolated(unsafe) static var availableMB: () -> Int = { 1 << 20 }

    private func admits(_ need: Int, long: Bool, margin: Int = HeavyWork.marginMB) -> Bool {
        if running.isEmpty { return true }
        if long && running.contains(where: \.long) { return false }
        return Self.availableMB() - need >= margin
    }

    /// Runs `work` on the calling (background) thread when there is room for it, and returns its result. `long` = a
    /// job of a minute or more (AI Denoise): only one at a time, and others may still start beside it when there is
    /// room. `optional`: returns nil at once instead of waiting or starting short of memory.
    func run<T>(_ kind: Kind, megapixels: Double, long: Bool = false, optional: Bool = false, _ work: () -> T) -> T? {
        let need = Self.needMB(kind, megapixels: megapixels)
        // the simulator reports no memory at all (checklist B1): there a preview decode is not held up
        if kind == .preview, Self.availableMB() <= 0 { return work() }
        condition.lock()
        // not while Lumen is in the background (AI Denoise has its own pause and is not held here)
        if kind != .denoise, !Self.isForeground {
            Self.note?("\(kind.rawValue): waiting for Lumen to be on screen")
            while !Self.isForeground { condition.wait(until: Date().addingTimeInterval(0.5)) }
        }
        var waited = false
        while !admits(need, long: long, margin: Self.marginMB(for: kind)) {
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
        if alone, Self.availableMB() < need + Self.marginMB(for: kind) {
            if optional {
                // an optional job (the 100 % copy, the original copy) is not worth sleeping on the shared work queue for
                // (it stalled the next photo's decode by 3 s): it starts if there is room for it AND the safety margin
                // (without the margin a 4096 px copy started with 2477 MB free for ~2150 MB and iOS closed Lumen,
                // 23 Oct), else it is skipped at once
                let free = Self.availableMB()
                if free < need + Self.marginMB(for: kind) {
                    finish(me)
                    Self.note?("\(kind.rawValue): skipped, only \(free) MB free (~\(need) MB needed, plus \(Self.marginMB(for: kind)) MB to spare)")
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

    /// Whether any job is running now.
    var isBusy: Bool {
        condition.lock(); defer { condition.unlock() }
        return !running.isEmpty
    }

    /// Whether a job of this kind is running now.
    func isRunning(_ kind: Kind) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return running.contains { $0.kind == kind }
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
