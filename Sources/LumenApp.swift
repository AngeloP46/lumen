import SwiftUI

@main
struct LumenApp: App {
    @StateObject private var store = LibraryStore()

    init() {
        Diagnostics.shared.start()
        EditSession.stepNote = { BlackBox.shared.crumb($0); Diagnostics.shared.note($0) }
        HeavyWork.note = { Diagnostics.shared.note($0) }
        HeavyWork.availableMB = { Diagnostics.availableMB }
        // short of room for a heavy job with nothing else heavy running: what can be made again goes (models in use
        // are kept alive by the job holding them)
        HeavyWork.release = { kind in
            LumenGPU.context.clearCaches()
            if kind != .aiMasks { EditSession.releaseMaskModels() }
        }
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
