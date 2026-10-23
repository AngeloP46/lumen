import SwiftUI

@main
struct LumenApp: App {
    @StateObject private var store = LibraryStore()

    init() {
        Diagnostics.shared.start()
        EditSession.stepNote = { BlackBox.shared.crumb($0); Diagnostics.shared.note($0) }
        HeavyWork.note = { Diagnostics.shared.note($0) }
        HeavyWork.availableMB = { Diagnostics.availableMB }
        // GPU work is refused in the background (checklist B2): heavy jobs wait for the screen
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in HeavyWork.isForeground = true }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in HeavyWork.isForeground = false }
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
