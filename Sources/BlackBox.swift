import Foundation
import UIKit

/// A flight recorder for memory closures (23 Oct 2026). iOS closes Lumen for memory without a crash report, and the
/// diagnostics log samples memory every 2 s, so a spike that lasts a second (the owner's phone went from 0.3 to 3 GB
/// while the Heal model loaded, or a Lens Blur photo was redrawn) left nothing between "320 MB" and the closure.
///
/// Every 0.1 s this reads Lumen's memory. While it is high and moving it writes a line (with the last few things the
/// app said it was doing) to a small file of its own, so the lines survive the closure; the next launch copies the last
/// ones into the diagnostics log. It also acts: past `shedFromMB` it makes Lumen let go of what can be made again (the
/// same as when iOS sends a memory warning, which comes late), at most once every 3 s.
final class BlackBox: @unchecked Sendable {
    static let shared = BlackBox()

    /// Memory (MB) from which lines are recorded, and from which Lumen sheds by itself.
    static let recordFromMB = 1400
    static let shedFromMB = 2400

    private let queue = DispatchQueue(label: "lumen.blackbox", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var crumbs: [String] = []
    private var url: URL?
    private var lastMB = 0
    private var lastWrite = Date.distantPast
    private var lastShed = Date.distantPast
    /// When Lumen last made its own memory warning (so the diagnostics log can say whose it was).
    private var ownWarningAt = Date.distantPast
    private let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_GB_POSIX"); return f
    }()
    private let tenths: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.S"; f.locale = Locale(identifier: "en_GB_POSIX"); return f
    }()

    /// The last lines the previous run wrote (newest last), for the diagnostics log.
    func previousLines(in dir: URL, limit: Int = 14) -> [String] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("blackbox.log"), encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit)).map(String.init)
    }

    private static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()

    func start(in dir: URL) {
        // the simulator's memory says nothing about the phone (checklist B1), and CI must never shed by itself
        guard timer == nil, !Self.isSimulator else { return }
        let file = dir.appendingPathComponent("blackbox.log")
        try? Data().write(to: file)   // this run starts a new one
        url = file
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: .milliseconds(100), leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// What the app is doing now, in a few words (the last three go on each line). Cheap; any thread.
    func crumb(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        if crumbs.last == text { return }
        crumbs.append(text)
        if crumbs.count > 6 { crumbs.removeFirst() }
    }

    private var counts: [String: Int] = [:]
    /// Counts something that happens often (a frame drawn, a render asked for); the next line says how many since the last.
    func count(_ name: String) {
        lock.lock(); counts[name, default: 0] += 1; lock.unlock()
    }

    /// Whether a memory warning in the last second was Lumen's own.
    var warningIsOwn: Bool { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(ownWarningAt) < 1 }

    private func tick() {
        let mb = Diagnostics.footprintMB
        defer { lastMB = mb }
        guard mb >= Self.recordFromMB else { return }
        let now = Date()
        if abs(mb - lastMB) >= 100 || now.timeIntervalSince(lastWrite) >= 2 {
            lock.lock()
            let recent = crumbs.suffix(3).joined(separator: " > ")
            let busy = counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
            counts = [:]
            lock.unlock()
            // in the diagnostics log's own format, so the next launch can copy the lines in as they are; they read as
            // routine memory samples ("memory ..."), and carry the time to a tenth of a second
            append("\(stamp.string(from: now))  memory \(mb) MB used, \(Diagnostics.availableMB) MB left · at \(tenths.string(from: now)) · \(busy.isEmpty ? "" : busy + " · ")\(recent)")
            lastWrite = now
        }
        if mb >= Self.shedFromMB, now.timeIntervalSince(lastShed) > 3 {
            lastShed = now
            lock.lock(); ownWarningAt = now; lock.unlock()
            // the same let-go as a warning from iOS, which comes late; the editor's observer does the work
            DispatchQueue.main.async { NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil) }
        }
    }

    private func append(_ line: String) {
        guard let url, let data = (line + "\n").data(using: .utf8), let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.write(contentsOf: data)
        if size > 30_000, let all = try? Data(contentsOf: url) {
            var tail = all.suffix(12_000)
            if let nl = tail.firstIndex(of: 10) { tail = tail[(nl + 1)...] }
            try? Data(tail).write(to: url, options: .atomic)
        }
    }
}
