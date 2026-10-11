import Foundation

/// Downloads the Smart fill model files once (about 950 MB) into the app's Library folder. Files already there
/// (right size) are skipped, so an interrupted download carries on where it stopped.
@MainActor
final class SmartFillDownloader: ObservableObject {
    static let shared = SmartFillDownloader()

    enum State: Equatable { case idle, downloading, ready, failed(String) }
    @Published private(set) var state: State = SmartFillFiles.isComplete ? .ready : .idle
    @Published private(set) var fraction: Double = 0

    private var task: URLSessionDownloadTask?
    private var timer: Timer?
    private var cancelled = false

    var megabytes: Int { Int(SmartFillFiles.totalBytes / 1_000_000) }

    func start() {
        guard state != .downloading else { return }
        if SmartFillFiles.isComplete { state = .ready; return }
        cancelled = false
        state = .downloading
        Task { await run() }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        timer?.invalidate()
        state = .idle
    }

    private func run() async {
        let fm = FileManager.default
        let dir = SmartFillFiles.directory
        let total = Double(SmartFillFiles.totalBytes)
        var done: Int64 = 0
        for (path, size) in SmartFillFiles.files {
            if cancelled { return }
            let dest = dir.appendingPathComponent(path)
            let have = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? -1
            if have == size { done += size; fraction = Double(done) / total; continue }
            guard let url = URL(string: SmartFillFiles.repo + path) else { state = .failed("Bad address"); return }
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let tmp = try await download(url, base: done, total: total)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: tmp, to: dest)
            } catch {
                if !cancelled { state = .failed("Download stopped: \(error.localizedDescription)") }
                return
            }
            let got = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? -1
            guard got == size else { state = .failed("A file came down the wrong size. Try again."); return }
            done += size
            fraction = Double(done) / total
        }
        state = SmartFillFiles.isComplete ? .ready : .failed("Something is missing. Try again.")
    }

    private func download(_ url: URL, base: Int64, total: Double) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let t = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                if let error { cont.resume(throwing: error); return }
                guard let tmp, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    cont.resume(throwing: URLError(.badServerResponse)); return
                }
                // the system deletes `tmp` when this handler returns: move it somewhere of ours first
                let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do { try FileManager.default.moveItem(at: tmp, to: keep); cont.resume(returning: keep) }
                catch { cont.resume(throwing: error) }
            }
            task = t
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self, weak t] _ in
                guard let t else { return }
                Task { @MainActor in self?.fraction = (Double(base) + Double(t.countOfBytesReceived)) / total }
            }
            t.resume()
        }
    }
}
