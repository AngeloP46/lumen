import Foundation

/// Launch-argument hooks used by the CI simulator run to open the app on sample photos and screenshot it.
/// Nothing here runs unless the app is launched with `-lumenDemoDir`.
enum DemoMode {
    private static let args = ProcessInfo.processInfo.arguments

    static func value(_ key: String) -> String? {
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var isOn: Bool { value("-lumenDemoDir") != nil }

    /// CI (App Store screenshots): present the paywall shortly after launch.
    static var paywall: Bool { isOn && value("-lumenDemoPaywall") == "1" }

    /// CI (App Store screenshots): put non-zero Pro values (Detail) into the demo edits, so the
    /// watermark and the export gate are exercised without touching any real photo.
    static var proEdits: Bool { isOn && value("-lumenDemoPro") == "1" }
}

extension DemoMode {
    /// CI-only event log (`-lumenDemoLog <path>`): lets the UI tests check *when* something happened, e.g. that the
    /// original stays visible for as long as the finger is down.
    static func log(_ message: String) {
        guard let path = value("-lumenDemoLog") else { return }
        let line = "\(Date().timeIntervalSince1970) \(message)" + "\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
}
