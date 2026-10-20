import SwiftUI

@main
struct LumenApp: App {
    @StateObject private var store = LibraryStore()

    init() {
        Diagnostics.shared.start()
        EditSession.stepNote = { Diagnostics.shared.note($0) }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if TesterExpiry.isExpired { TesterExpiredView() } else { LibraryView() }
            }
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
