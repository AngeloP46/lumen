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
}
