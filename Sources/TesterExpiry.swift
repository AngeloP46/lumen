import SwiftUI

/// Tester builds only: the build workflow `tester-build.yml` writes `LumenTesterExpires` (yyyy-MM-dd) into Info.plist,
/// 30 days after the build. From that day the app shows `TesterExpiredView` instead of the library. Normal builds
/// (SideStore feed, App Store) have no such key and never expire. Photos and edits stay on the phone either way.
enum TesterExpiry {
    static var date: Date? {
        if DemoMode.isOn, DemoMode.value("-lumenDemoExpired") != nil { return Date(timeIntervalSince1970: 0) }
        guard let text = Bundle.main.infoDictionary?["LumenTesterExpires"] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text)
    }
    static var isExpired: Bool { date.map { Date() >= $0 } ?? false }
}

struct TesterExpiredView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("This test version has ended").font(.title3.bold())
            Text("Thanks for trying Lumen. Ask Angelo for a new version. Your photos and edits are still on this phone.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(32)
        .accessibilityIdentifier("tester-expired")
    }
}
