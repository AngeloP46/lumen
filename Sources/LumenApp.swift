import SwiftUI

@main
struct LumenApp: App {
    @StateObject private var store = LibraryStore()

    init() { Diagnostics.shared.start() }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
