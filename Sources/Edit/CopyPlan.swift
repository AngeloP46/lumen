import Foundation

/// When the zoomed-in (100 %) copy may be built, and how often to try (quality checklist A21, 23 Oct 2026).
/// Owner's phone, 0.1.521: after Remove person on a 24 MP photo, zooming in tried to build the copy 13 times in a
/// minute (every pinch step asked again, and so did every memory warning that dropped it). Each build added about
/// 2.1 GB, and iOS closed Lumen twice in four minutes.
enum DetailCopy {
    /// What a build adds at its peak (MB), from the owner's phone: 24 MP +2150 MB (23 Oct), 48 MP +2640 MB (21 Oct).
    /// Mostly the RAW engine's decode, so it grows slowly with the photo's size.
    static func needMB(megapixels mp: Double) -> Int { max(Int(50 * mp) + 700, Int(20 * mp) + 1700) }

    /// The long edge to build, 0 = don't. The room for the build must be free with the safety margin beside it: before
    /// 23 Oct a 4096 px copy was started with 2477 MB free for a build that needs ~2150, and iOS closed Lumen.
    static func edge(freeMB: Int, megapixels mp: Double, native: Double, highTier: Bool, marginMB: Int) -> Double {
        guard freeMB >= needMB(megapixels: mp) + marginMB else { return 0 }
        // the increased memory limit (about 6 GB): the full-size photo, up to 6000 px, when there is plenty left
        if highTier, Double(freeMB) > 3500 * max(1, mp / 24) { return min(native, 6000) }
        return min(native, 4096)
    }
}

/// "Not before": a try that failed (no room, dropped on a memory warning) is not repeated for a while, so a gesture
/// that fires many times a second can't turn into a loop of heavy attempts.
struct RetryGate {
    private(set) var notBefore = Date.distantPast
    func allows(_ now: Date = Date()) -> Bool { now >= notBefore }
    mutating func hold(for seconds: TimeInterval, from now: Date = Date()) {
        notBefore = max(notBefore, now.addingTimeInterval(seconds))
    }
}

/// "Careful mode" (23 Oct 2026): after iOS has closed Lumen for memory twice within a day, Lumen asks less of the phone for
/// the rest of that day - a smaller preview, no zoomed-in copy, no Heal warm-up, an earlier let-go - and says so. It
/// goes back to normal by itself after 24 hours without a closure. A phone that keeps closing the app should get a
/// smaller app, not the same crash again.
enum CarefulMode {
    static let window: TimeInterval = 24 * 3600
    static let closuresNeeded = 2

    static func active(closures: [Date], now: Date = Date()) -> Bool {
        closures.filter { $0 <= now && now.timeIntervalSince($0) < window }.count >= closuresNeeded
    }

    /// Only the closures that still count (a list that never grows).
    static func pruned(_ closures: [Date], now: Date = Date()) -> [Date] {
        Array(closures.filter { $0 <= now && now.timeIntervalSince($0) < window }.suffix(20))
    }
}
