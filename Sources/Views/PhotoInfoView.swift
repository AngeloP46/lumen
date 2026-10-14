import SwiftUI

struct PhotoInfoView: View {
    let item: LibraryItem
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var info: PhotoInformation?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let info {
                    VStack(alignment: .leading, spacing: 28) {
                        row("camera.fill", info.camera, info.lens)
                        row("calendar", info.date, nil)
                        row("photo", item.displayName, "\(info.dimensions) · \(info.size)")
                        Text(url.pathExtension.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
                        HStack(alignment: .top) {
                            exposure("Shutter", info.shutter)
                            exposure("Aperture", info.aperture)
                            exposure("ISO", info.iso)
                        }
                    }.padding(24)
                } else { ProgressView().padding(40) }
            }
            .background(Theme.panel)
            .navigationTitle("Photo information").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("photo-info-done") } }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("photo-info")
        .task {
            let original = url
            info = await Task.detached(priority: .userInitiated) { PhotoInformation.read(original) }.value
        }
    }

    private func row(_ icon: String, _ title: String, _ subtitle: String?) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).textSelection(.enabled)
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
    }
    private func exposure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
