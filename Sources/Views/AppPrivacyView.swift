// DRAFT — sandbox: verify this app privacy notice and publish it at a stable URL before submission.
import SwiftUI
#if APP_STORE
struct AppPrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("App privacy policy").font(.title.bold())
                    Text("Updated 22 October 2026")
                    Text("Lumen RAW is developed by Angelo Parodi.")
                    Text("Photos and edits stay on your device. The app processes imported photos locally and stores its imported copies and editing data in its local library. It does not upload your photos to the developer or operate a cloud editing service.")
                    Text("You choose which photos or files to import. Saving an export to Photos requires your permission. If you share an export with another app, that service handles the file under its own privacy policy.")
                    Text("Diagnostics leave the app only if you choose ⋯ → Send diagnostics and send them yourself. They hold app memory and timing notes, never photos.")
                    Text("Purchases, subscriptions and restore use Apple's StoreKit service. Apple processes payments and provides the app with purchase information to check Pro access. The developer does not receive your payment card details.")
                    Text("The app does not include advertising or analytics tracking. You can remove imported photos and their edits from the app's library; this does not remove the originals from Photos or Files. Device backups and services you enable are controlled by your device settings.")
                    Text("The optional website waitlist is separate from the app and has its own privacy notice. Signing up is not required to edit photos.")
                    Link("Privacy questions: theracinglineltd@gmail.com", destination: URL(string: "mailto:theracinglineltd@gmail.com")!)
                }
                .padding(24)
            }
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
#endif
