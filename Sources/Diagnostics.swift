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
    /// The last run ended while Lumen was on screen (closed by iOS, a crash, or the phone went off).
    private(set) var closedDuringLastRun = false

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
        // the flight recorder's lines from the previous run (read before this run starts its own)
        let blackBoxLines = BlackBox.shared.previousLines(in: dir)
        BlackBox.shared.start(in: dir)
        // the previous run never reached the background: iOS (or a crash) closed it while it was on screen
        if let state = try? String(contentsOf: stateURL, encoding: .utf8), state.hasPrefix("open") {
            // "open <time> <MB>": written every 2 s while on screen (21 Oct review: the ended time used to be the last
            // logged line, and a dead battery or the phone turning off reads the same way, hence "or the phone went off")
            closedDuringLastRun = true
            MemoryBudget.noteClosure()   // two in a day and Lumen asks less of the phone (CarefulMode)
            let parts = state.split(separator: " ")
            let seen = parts.count >= 3 ? " (last seen \(parts[1]) using \(parts[2]) MB)" : ""
            // what memory did in its last seconds (every 0.1 s while it was high): the 2 s samples miss a spike
            if !blackBoxLines.isEmpty { queue.async { [self] in for l in blackBoxLines { writeRaw(l) } } }
            note("previous run ended while Lumen was open\(seen): closed by iOS for memory, a crash, or the phone went off")
        }
        let info = Bundle.main.infoDictionary
        note("launch \(info?["CFBundleShortVersionString"] as? String ?? "?") on \(Self.device) iOS \(UIDevice.current.systemVersion), memory \(MemoryBudget.summary)")
        setState("open")
        // CI: what the simulator reports, so tests know which memory tier they ran in (checklist B1)
        if DemoMode.isOn { DemoMode.log("memory budget \(MemoryBudget.summary), os available \(Int(os_proc_available_memory() / 1_048_576)) MB") }
        MXMetricManager.shared.add(self)
        save(MXMetricManager.shared.pastDiagnosticPayloads)

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            // written at once (the app can be suspended straight after this)
            self?.note("background"); self?.setState("background", now: true)
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.note("foreground"); self?.setState("open")
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            // Lumen makes one itself when memory passes 2.4 GB (BlackBox): iOS' own comes later, often too late
            self?.note(BlackBox.shared.warningIsOwn ? "Lumen's own memory check" : "iOS memory warning")
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
    static var availableMB: Int {
        if let fake = MemoryBudget.fakeMB { return max(0, fake - footprintMB) }
        return Int(os_proc_available_memory() / 1_048_576)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.locale = Locale(identifier: "en_GB_POSIX"); return f
    }()

    private func sample() {
        let used = Self.footprintMB, left = Self.availableMB
        let onScreen = UIApplication.shared.applicationState != .background
        queue.async { [self] in
            if onScreen { try? "open \(Self.clock.string(from: Date())) \(used)".write(to: stateURL, atomically: true, encoding: .utf8) }
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
        writeRaw("\(Self.stamp.string(from: Date()))  \(line)")
    }

    /// On `queue` only: a line that already carries its time stamp.
    private func writeRaw(_ line: String) {
        let text = line + "\n"
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

    private func setState(_ s: String, now: Bool = false) {
        if now { queue.sync { [self] in try? s.write(to: stateURL, atomically: true, encoding: .utf8) }; return }
        queue.async { [self] in try? s.write(to: stateURL, atomically: true, encoding: .utf8) }
    }

    // MARK: MetricKit

    func didReceive(_ payloads: [MXDiagnosticPayload]) { save(payloads) }

    /// iOS's daily summary: how often Lumen was closed for memory or crashed, on screen and in the background (iOS
    /// never sends a memory-limit closure as a crash report; 21 Oct review).
    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            guard let exits = p.applicationExitMetrics else { continue }
            let fg = exits.foregroundExitData, bg = exits.backgroundExitData
            let line = "iOS day summary: on screen \(fg.cumulativeMemoryResourceLimitExitCount) memory closures, " +
                "\(fg.cumulativeAbnormalExitCount) crashes, \(fg.cumulativeAppWatchdogExitCount) hangs; in the background " +
                "\(bg.cumulativeMemoryResourceLimitExitCount + bg.cumulativeMemoryPressureExitCount) memory closures, \(bg.cumulativeAbnormalExitCount) crashes"
            note(line)
        }
    }

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

    /// The Findings of the last three launches, one line each (shown on the Diagnostics screen).
    var findingLines: [String] {
        queue.sync {
            guard let log = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
            let lines = log.split(separator: "\n", omittingEmptySubsequences: true)
            let launches = lines.indices.filter { lines[$0].contains("  launch ") }
            let from = launches.count >= 3 ? launches[launches.count - 3] : lines.startIndex
            return Self.findings(Array(lines[from...])).split(separator: "\n").filter { $0.hasPrefix("• ") }.map { String($0.dropFirst(2)) }
        }
    }

    /// Closures by iOS (or crashes) in the log, newest last: (the run's lines, what it was doing last).
    var crashCount: Int {
        queue.sync {
            guard let log = try? String(contentsOf: logURL, encoding: .utf8) else { return 0 }
            return Self.runs(log.split(separator: "\n", omittingEmptySubsequences: true)).filter(Self.endedBadly).count
        }
    }

    /// One text file ready to share. `crashOnly`: just the last 3 times iOS closed Lumen, each with the step it was on
    /// and the lines leading up to it (owner, 21 Oct: show what caused the crash, not everything else).
    func makeReport(crashOnly: Bool = false) -> URL? {
        queue.sync {
            let info = Bundle.main.infoDictionary
            var out = "Lumen diagnostics\n"
            out += "Version \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))\n"
            out += "\(Self.device), iOS \(UIDevice.current.systemVersion)\n"
            out += "Memory \(MemoryBudget.summary)\n"
            out += "Memory now: \(Self.footprintMB) MB used, \(Self.availableMB) MB left, peak this run \(peakMB) MB\n\n"
            // Only what's recent and only what matters (owner, 21 Oct: the report was mostly routine memory samples and
            // runs of identical warnings): a summary line per launch for the last three, then their log with the
            // routine samples left out (except new highs and the last lines before iOS closed Lumen) and repeated
            // memory warnings folded into one line; iOS reports only when they hold more than their time stamps.
            if let log = try? String(contentsOf: logURL, encoding: .utf8) {
                let lines = log.split(separator: "\n", omittingEmptySubsequences: true)
                if crashOnly {
                    out += Self.crashes(Array(lines))
                } else {
                    let launches = lines.indices.filter { lines[$0].contains("  launch ") }
                    let from = launches.count >= 3 ? launches[launches.count - 3] : lines.startIndex
                    out += Self.findings(Array(lines[from...])) + "\n"
                    out += Self.compact(Array(lines[from...]))
                }
            }
            let cutoff = Date().addingTimeInterval(-3 * 86_400).timeIntervalSince1970
            let recent = savedReports()
                .filter { (Double($0.deletingPathExtension().lastPathComponent.dropFirst("diagnostic-".count)) ?? 0) >= cutoff }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .prefix(3)
            for url in crashOnly ? [] : recent {
                guard let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
                if let d = obj as? [String: Any], Set(d.keys).isSubset(of: ["timeStampBegin", "timeStampEnd"]) { continue }
                guard let compact = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
                      let text = String(data: compact, encoding: .utf8) else { continue }
                out += "\n\n== iOS report \(url.lastPathComponent) ==\n" + (text.count > 20_000 ? String(text.prefix(20_000)) + " … (cut)" : text)
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(crashOnly ? "Lumen-crashes.txt" : "Lumen-diagnostics.txt")
            do { try out.write(to: file, atomically: true, encoding: .utf8); return file } catch { return nil }
        }
    }

    /// The log split into runs, one per launch; "previous run ended while open" is written at the next launch, so it
    /// is the last line of the run it describes.
    static func runs(_ lines: [Substring]) -> [[Substring]] {
        var runs: [[Substring]] = []
        for l in lines {
            let e = l.count > 21 ? l.dropFirst(21) : l
            if e.hasPrefix("launch ") || runs.isEmpty { runs.append([l]) } else { runs[runs.count - 1].append(l) }
        }
        return runs
    }
    static func endedBadly(_ run: [Substring]) -> Bool {
        run.last.map { ($0.count > 21 ? $0.dropFirst(21) : $0).hasPrefix("previous run ended") } ?? false
    }

    /// The last 3 closures: for each, the step Lumen was on, how memory climbed, and the lines just before.
    static func crashes(_ lines: [Substring]) -> String {
        func event(_ l: Substring) -> Substring { l.count > 21 ? l.dropFirst(21) : l }
        func used(_ l: Substring) -> Int? {
            guard let r = l.range(of: " MB used") else { return nil }
            return Int(String(l[..<r.lowerBound].reversed().prefix { $0.isNumber }.reversed()))
        }
        func routine(_ l: Substring) -> Bool {
            let e = event(l)
            return e.hasPrefix("memory ") || e.hasPrefix("iOS memory warning") || e.hasPrefix("previous run ended")
        }
        let bad = runs(lines).filter(endedBadly).suffix(3)
        guard !bad.isEmpty else { return "No crashes or closures by iOS in the log.\n" }
        var out = "== Last \(bad.count) time\(bad.count == 1 ? "" : "s") iOS closed Lumen (newest last) ==\n"
        for run in bad {
            let version = run.first.flatMap { event($0).split(separator: " ").dropFirst().first } ?? "?"
            let body = Array(run.dropLast())                      // without the "previous run ended" line
            let lastStep = body.lastIndex { !routine($0) }
            let stepLine = lastStep.map { body[$0] }
            let after = lastStep.map { Array(body[($0 + 1)...]) } ?? body
            let start = stepLine.flatMap(used) ?? body.compactMap(used).first ?? 0
            let peak = after.compactMap(used).max() ?? start
            let ended = body.last.map { String($0.prefix(19)) } ?? "?"
            out += "\n• \(ended) (\(version)): "
            if let stepLine {
                out += "last step \"\(event(stepLine).split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")\""
                out += " at \(stepLine.dropFirst(11).prefix(8)); memory \(start) → \(peak) MB"
            } else {
                out += "no step logged; memory peaked at \(peak) MB"
            }
            out += "\n"
            // the lines leading up to it, repeated warnings folded into one
            var tail: [String] = []
            for l in body.suffix(12) {
                if event(l).hasPrefix("iOS memory warning"), let last = tail.last, last.contains("iOS memory warning") {
                    if let r = last.range(of: " ×") {
                        let n = (Int(last[r.upperBound...].prefix { $0.isNumber }) ?? 1) + 1
                        tail[tail.count - 1] = String(last[..<r.lowerBound]) + " ×\(n)"
                    } else {
                        tail[tail.count - 1] = "\(last.prefix(19))  iOS memory warning ×2"
                    }
                    continue
                }
                tail.append(String(l))
            }
            out += tail.map { "    " + $0 }.joined(separator: "\n") + "\n"
        }
        return out
    }

    /// Problems spotted in the log, worst first, so the top of a report says what to look at (22 Oct: undo / redo of a
    /// heal re-ran every AI mask eight times in 12 s and nobody noticed until the log was read line by line).
    static func findings(_ lines: [Substring]) -> String {
        func event(_ l: Substring) -> Substring { l.count > 21 ? l.dropFirst(21) : l }
        func time(_ l: Substring) -> Substring { l.prefix(19).dropFirst(11) }
        func seconds(_ l: Substring) -> Double? { stamp.date(from: String(l.prefix(19)))?.timeIntervalSince1970 }
        func number(before marker: String, in l: Substring) -> Int? {
            guard let r = l.range(of: marker) else { return nil }
            return Int(String(l[..<r.lowerBound].reversed().prefix { $0.isNumber }.reversed()))
        }
        var found: [String] = []
        let all = runs(lines)
        for run in all {
            let version = run.first.flatMap { event($0).split(separator: " ").dropFirst().first } ?? "?"
            // closed by iOS: the step it was on
            if endedBadly(run), let step = run.dropLast().last(where: { !event($0).hasPrefix("memory ") && !event($0).hasPrefix("iOS memory warning") }) {
                found.append("iOS closed Lumen (\(version)) after \"\(event(step).split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")\" at \(time(step))")
            }
            // the same heavy work over and over in a short time
            for (marker, name, window, most) in [("AI masks: working them out", "AI masks worked out", 30.0, 3),
                                                 ("original copy", "original copy made", 60.0, 2),
                                                 ("100% view: building", "100% copy built", 60.0, 3),
                                                 ("heal model loading", "Heal model loaded", 120.0, 3)] {
                let times = run.filter { event($0).hasPrefix(marker) }.compactMap { l in seconds(l).map { ($0, l) } }
                var i = 0, worst = 0, worstAt: Substring = ""
                for j in times.indices {
                    while times[j].0 - times[i].0 > window { i += 1 }
                    if j - i + 1 > worst { worst = j - i + 1; worstAt = times[i].1 }
                }
                if worst > most { found.append("\(name) \(worst) times within \(Int(window)) s from \(time(worstAt)) (\(version))") }
            }
            // close to the limit
            if let low = run.compactMap({ number(before: " MB left", in: $0) }).min(), low < 800,
               let at = run.first(where: { number(before: " MB left", in: $0) == low }) {
                let before = run.prefix { $0 != at }.last { !event($0).hasPrefix("memory ") && !event($0).hasPrefix("iOS memory warning") }
                found.append("memory got to \(low) MB from the limit at \(time(at))" + (before.map { " during \"\(event($0).split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")\"" } ?? "") + " (\(version))")
            }
            let warnings = run.filter { event($0).hasPrefix("iOS memory warning") }.count
            if warnings > 0 { found.append("\(warnings) iOS memory warning\(warnings == 1 ? "" : "s") (\(version))") }
            // jobs that started short of memory, failures, slow or wrong AI Denoise tiles
            var short: [String: Int] = [:]
            for l in run {
                let e = event(l)
                if let r = e.range(of: ": starting with only ") { short[String(e[..<r.lowerBound]), default: 0] += 1 }
                for bad in ["reload failed", "denoise failed", "couldn't keep a", "heal failed", "export failed"] where e.hasPrefix(bad) {
                    found.append("\(e.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") at \(time(l)) (\(version))")
                }
                if e.hasPrefix("denoise done in "), let r = e.range(of: "median "), let v = Double(e[r.upperBound...].prefix { $0.isNumber || $0 == "." }), v > 0.6 {
                    found.append("AI Denoise slow: \(v) s per tile (usual ~0.42) at \(time(l)) (\(version))")
                }
                if e.contains("redone on the CPU"), e.hasPrefix("denoise: tile") { found.append("AI Denoise: a tile looked wrong from the GPU at \(time(l)) (\(version))") }
            }
            for (job, n) in short.sorted(by: { $0.value > $1.value }) { found.append("\(job) started short of memory \(n) time\(n == 1 ? "" : "s") (\(version))") }
        }
        guard !found.isEmpty else { return "== Findings ==\nNo problems spotted in the last launches.\n" }
        return "== Findings (\(found.count)) ==\n" + found.prefix(15).map { "• " + $0 }.joined(separator: "\n") + "\n"
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
    @State private var crashReport: URL?
    @State private var crashes = 0
    @State private var summary: Diagnostics.Summary?
    @State private var findings: [String]?

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
                if let findings {
                    // what the report's Findings say, readable without sharing anything
                    VStack(alignment: .leading, spacing: 4) {
                        Text(findings.isEmpty ? "No problems spotted" : "Findings").font(.headline)
                        ForEach(Array(findings.prefix(5).enumerated()), id: \.offset) { _, f in
                            Text("• " + f).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("diagnostics-findings")
                }
                if let report {
                    // after a crash the short crash report comes first: what Lumen was doing when iOS closed it
                    if crashes > 0, let crashReport {
                        ShareLink(item: crashReport) {
                            Label("Share crash report (\(min(3, crashes)) latest)", systemImage: "exclamationmark.triangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("diagnostics-share-crashes")
                        ShareLink(item: report) {
                            Label("Share full report", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("diagnostics-share")
                    } else {
                        ShareLink(item: report) {
                            Label("Share report", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("diagnostics-share")
                    }
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
        .presentationDetents([.medium, .large])
        .task {
            let (s, r, c, n, f) = await Task.detached {
                (Diagnostics.shared.summary, Diagnostics.shared.makeReport(), Diagnostics.shared.makeReport(crashOnly: true),
                 Diagnostics.shared.crashCount, Diagnostics.shared.findingLines)
            }.value
            summary = s; report = r; crashReport = c; crashes = n; findings = f
        }
    }
}
