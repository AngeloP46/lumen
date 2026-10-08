import SwiftUI

@main
struct LumenApp: App {
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
