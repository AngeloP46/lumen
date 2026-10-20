import SwiftUI
import MetricKit
import os

/// Crash and memory recording, so a problem on the phone can be sent as one file instead of hunting through
/// Settings → Privacy → Analytics. Two sources:
/// - a small memory log (Library/Diagnostics/memory-log.txt): what Lumen was doing and how much memory it used,
///   written at key moments and whenever the footprint moves a lot. Its last lines show what led up to iOS closing
///   the app, which iOS itself never reports to the app.
/// - MetricKit's crash / hang / disk-write diagnostics, saved as JSON when iOS delivers them (usually on a later launch).
/// Nothing leaves the phone unless the owner shares the report from the ⋯ menu.
final class Diagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = Diagnostics()

    private let queue = DispatchQueue(label: "lumen.diagnostics", qos: .utility)
    private let dir: URL
    private var logURL: URL { dir.appendingPathComponent("memory-log.txt") }
    private var stateURL: URL { dir.appendingPathComponent("state.txt") }
    private var lastLoggedMB = 0
    private var peakMB = 0
    private var sampler: Timer?
    private var started = false

    private override init() {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        dir = lib.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        super.init()
    }

    /// Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        // the previous run never reached the background: iOS (or a crash) closed it while it was on screen
        if let state = try? String(contentsOf: stateURL, encoding: .utf8), state.hasPrefix("open") {
            note("previous run ended while Lumen was open (closed by iOS for memory, or a crash)")
        }
        let info = Bundle.main.infoDictionary
        note("launch \(info?["CFBundleShortVersionString"] as? String ?? "?") on \(Self.device) iOS \(UIDevice.current.systemVersion)")
        setState("open")
        MXMetricManager.shared.add(self)
        save(MXMetricManager.shared.pastDiagnosticPayloads)

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.note("background"); self?.setState("background")
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.note("foreground"); self?.setState("open")
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.note("iOS memory warning")
        }
        // Cheap: one system call every 2 s, a line only when memory moved by 150 MB or is running low.
        sampler = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
    }

    // MARK: Memory

    /// Memory Lumen is using now, as iOS counts it against the app's limit (MB).
    static var footprintMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    /// How much more Lumen may use before iOS closes it (MB).
    static var availableMB: Int { Int(os_proc_available_memory() / 1_048_576) }

    private func sample() {
        let used = Self.footprintMB, left = Self.availableMB
        queue.async { [self] in
            peakMB = max(peakMB, used)
            if abs(used - lastLoggedMB) >= 150 || (left < 600 && abs(used - lastLoggedMB) >= 40) {
                write("memory \(used) MB used, \(left) MB left")
            }
        }
    }

    // MARK: Log

    /// Records what Lumen is doing, with its memory at that moment.
    func note(_ event: String) {
        let used = Self.footprintMB, left = Self.availableMB
        queue.async { [self] in
            peakMB = max(peakMB, used)
            write("\(event) · \(used) MB used, \(left) MB left")
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_GB_POSIX"); return f
    }()

    /// On `queue` only.
    private func write(_ line: String) {
        lastLoggedMB = Self.footprintMB
        let text = "\(Self.stamp.string(from: Date()))  \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.write(contentsOf: data)
            if size > 400_000 { trimLog() }
        } else {
            try? data.write(to: logURL)
        }
    }

    /// Keeps the newest half once the log passes 400 KB.
    private func trimLog() {
        guard let data = try? Data(contentsOf: logURL) else { return }
        var tail = data.suffix(200_000)
        if let nl = tail.firstIndex(of: 10) { tail = tail[(nl + 1)...] }
        try? Data(tail).write(to: logURL, options: .atomic)
    }

    private func setState(_ s: String) {
        queue.async { [self] in try? s.write(to: stateURL, atomically: true, encoding: .utf8) }
    }

    // MARK: MetricKit

    func didReceive(_ payloads: [MXDiagnosticPayload]) { save(payloads) }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        queue.async { [self] in
            for p in payloads {
                let name = "diagnostic-\(Int(p.timeStampEnd.timeIntervalSince1970)).json"
                let url = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { continue }
                try? p.jsonRepresentation().write(to: url)
                var kinds: [String] = []
                if let n = p.crashDiagnostics?.count, n > 0 { kinds.append("\(n) crash") }
                if let n = p.hangDiagnostics?.count, n > 0 { kinds.append("\(n) hang") }
                if let n = p.diskWriteExceptionDiagnostics?.count, n > 0 { kinds.append("\(n) disk-write") }
                if let n = p.cpuExceptionDiagnostics?.count, n > 0 { kinds.append("\(n) CPU") }
                write("iOS report saved: \(kinds.isEmpty ? "diagnostic" : kinds.joined(separator: ", ")) (\(name))")
            }
            // keep the 20 newest
            let reports = savedReports().sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in reports.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
        }
    }

    private func savedReports() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("diagnostic-") }
    }

    // MARK: Report

    struct Summary { var usedMB: Int; var leftMB: Int; var peakMB: Int; var reports: Int }

    var summary: Summary {
        queue.sync { Summary(usedMB: Self.footprintMB, leftMB: Self.availableMB, peakMB: peakMB, reports: savedReports().count) }
    }

    /// One text file with everything, ready to share.
    func makeReport() -> URL? {
        queue.sync {
            let info = Bundle.main.infoDictionary
            var out = "Lumen diagnostics\n"
            out += "Version \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))\n"
            out += "\(Self.device), iOS \(UIDevice.current.systemVersion)\n"
            out += "Memory now: \(Self.footprintMB) MB used, \(Self.availableMB) MB left, peak this run \(peakMB) MB\n\n"
            // Only what's recent and only what matters (owner, 21 Oct: the report was mostly routine memory samples and
            // runs of identical warnings): a summary line per launch for the last three, then their log with the
            // routine samples left out (except new highs and the last lines before iOS closed Lumen) and repeated
            // memory warnings folded into one line; iOS reports only when they hold more than their time stamps.
            if let log = try? String(contentsOf: logURL, encoding: .utf8) {
                let lines = log.split(separator: "\n", omittingEmptySubsequences: true)
                let launches = lines.indices.filter { lines[$0].contains("  launch ") }
                let from = launches.count >= 3 ? launches[launches.count - 3] : lines.startIndex
                out += Self.compact(Array(lines[from...]))
            }
            let cutoff = Date().addingTimeInterval(-3 * 86_400).timeIntervalSince1970
            let recent = savedReports()
                .filter { (Double($0.deletingPathExtension().lastPathComponent.dropFirst("diagnostic-".count)) ?? 0) >= cutoff }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .prefix(3)
            for url in recent {
                guard let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
                if let d = obj as? [String: Any], Set(d.keys).isSubset(of: ["timeStampBegin", "timeStampEnd"]) { continue }
                guard let compact = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
                      let text = String(data: compact, encoding: .utf8) else { continue }
                out += "\n\n== iOS report \(url.lastPathComponent) ==\n" + text
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Lumen-diagnostics.txt")
            do { try out.write(to: file, atomically: true, encoding: .utf8); return file } catch { return nil }
        }
    }

    /// The log of a few launches, shortened for sharing (see makeReport).
    static func compact(_ lines: [Substring]) -> String {
        func number(before marker: String, in l: Substring) -> Int? {
            guard let r = l.range(of: marker) else { return nil }
            let digits = l[..<r.lowerBound].reversed().prefix { $0.isNumber }
            return Int(String(digits.reversed()))
        }
        func used(_ l: Substring) -> Int? { number(before: " MB used", in: l) }
        func left(_ l: Substring) -> Int? { number(before: " MB left", in: l) }
        func event(_ l: Substring) -> Substring { l.count > 21 ? l.dropFirst(21) : l }
        func time(_ l: Substring) -> Substring { l.prefix(19).dropFirst(11) }

        // one run per launch; "previous run ended while open" is written at the next launch, so it closes the run before
        var runs: [[Substring]] = []
        for l in lines {
            if event(l).hasPrefix("launch ") || runs.isEmpty { runs.append([l]) } else { runs[runs.count - 1].append(l) }
        }
        var summary = "== Summary, last \(runs.count) launch\(runs.count == 1 ? "" : "es") (newest last) ==\n"
        var body = "\n== Log (routine memory samples left out) ==\n"
        for (n, run) in runs.enumerated() {
            let closed = run.last.map { event($0).hasPrefix("previous run ended") } ?? false
            let version = run.first.flatMap { event($0).split(separator: " ").dropFirst().first } ?? "?"
            let peak = run.compactMap(used).max() ?? 0, low = run.compactMap(left).min() ?? 0
            let ending = closed ? "closed by iOS (memory) or crashed"
                : n == runs.count - 1 ? "open now" : (run.last.map { event($0).hasPrefix("background") } ?? false) ? "went to the background" : "ended"
            var denoise: [String] = []
            for l in run {
                let e = event(l)
                if e.hasPrefix("denoise done in "), let secs = e.dropFirst(16).split(separator: " ").first {
                    let tiles = e.range(of: " tiles,").map { r in String(e[..<r.lowerBound].reversed().prefix { $0.isNumber }.reversed()) }
                    denoise.append("\(secs) s" + (tiles.map { " (\($0) tiles)" } ?? ""))
                } else if e.hasPrefix("denoise stopped") { denoise.append("stopped") }
                else if e.hasPrefix("denoise failed") { denoise.append("failed") }
            }
            let heals = run.filter { event($0).hasPrefix("heal done") }.count
            summary += "• \(version) · \(run.first.map(time) ?? "")–\(run.last.map(time) ?? "") · \(ending) · peak \(peak) MB, lowest \(low) MB left"
            if !denoise.isEmpty { summary += " · AI Denoise: " + denoise.joined(separator: ", ") }
            if heals > 0 { summary += " · \(heals) heal\(heals == 1 ? "" : "s")" }
            summary += "\n"

            let keepAllFrom = closed ? max(0, run.count - 8) : run.count
            var high = 0, i = 0
            while i < run.count {
                let l = run[i]
                if event(l).hasPrefix("iOS memory warning") {
                    var j = i, lowest = Int.max
                    while j < run.count, event(run[j]).hasPrefix("iOS memory warning") { lowest = min(lowest, left(run[j]) ?? lowest); j += 1 }
                    body += (j - i == 1 ? String(l) : "\(l.prefix(19))  iOS memory warning ×\(j - i), lowest \(lowest) MB left") + "\n"
                    i = j
                    continue
                }
                if event(l).hasPrefix("memory "), i < keepAllFrom {
                    // a routine sample: kept only when memory climbed well past what the log has shown so far
                    if let u = used(l), u > high + 300 { high = u; body += String(l) + "\n" }
                    i += 1
                    continue
                }
                if let u = used(l) { high = max(high, u) }
                body += String(l) + "\n"
                i += 1
            }
        }
        return summary + body
    }

    static var device: String {
        var u = utsname(); uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
}

/// ⋯ → Send diagnostics: memory now, how many iOS reports are saved, and a share button for the report file.
struct DiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report: URL?
    @State private var summary: Diagnostics.Summary?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("A text file with what Lumen was doing, how much memory it used, and any crash reports iOS has given it. Nothing is sent unless you share it.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let s = summary {
                    Text("Memory now: \(s.usedMB) MB used, \(s.leftMB) MB left")
                    Text("Highest this time: \(s.peakMB) MB")
                    Text(s.reports == 0 ? "No crash reports from iOS yet" : "\(s.reports) crash/hang report\(s.reports == 1 ? "" : "s") saved")
                        .accessibilityIdentifier("diagnostics-reports")
                }
                if let report {
                    ShareLink(item: report) {
                        Label("Share report", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("diagnostics-share")
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .task {
            let (s, r) = await Task.detached { (Diagnostics.shared.summary, Diagnostics.shared.makeReport()) }.value
            summary = s; report = r
        }
    }
}
