import SwiftUI

/// What an export produces. The last choice is remembered (AppStorage in `ExportOptionsSheet`).
struct ExportOptions: Equatable {
    var format: ExportFormat = .jpeg
    /// JPEG/HEIC quality 10...100 (Lightroom-style); TIFF is always lossless 16-bit.
    var quality: Double = 92
    /// Long edge in pixels; 0 = full size.
    var longEdge: Int = 0
    /// Add an HDR gain map when the photo is edited in HDR (JPEG/HEIC).
    var hdr = true

    var maxEdge: CGFloat? { longEdge > 0 ? CGFloat(longEdge) : nil }
    var summary: String {
        var parts = [format.label]
        if format != .tiff { parts.append("quality \(Int(quality))") }
        parts.append(longEdge > 0 ? "\(longEdge) px" : "full size")
        return parts.joined(separator: " · ")
    }

    static let sizes: [(String, Int)] = [("Full size", 0), ("4096 px", 4096), ("2048 px", 2048), ("1080 px", 1080)]
}

/// Format, quality, size and HDR, for one photo or a batch.
struct ExportOptionsSheet: View {
    let count: Int
    let hdrAvailable: Bool
    let onExport: (ExportOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportFormat") private var format = ExportFormat.jpeg.rawValue
    @AppStorage("exportQuality") private var quality = 92.0
    @AppStorage("exportLongEdge") private var longEdge = 0
    @AppStorage("exportHDR") private var hdr = true

    private var fmt: ExportFormat { ExportFormat(rawValue: format) ?? .jpeg }

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("export-format")
                }
                if fmt != .tiff {
                    Section {
                        HStack {
                            Text("Quality")
                            Slider(value: $quality, in: 10...100, step: 1).accessibilityIdentifier("export-quality")
                            Text("\(Int(quality))").monospacedDigit().frame(width: 34, alignment: .trailing)
                                .accessibilityIdentifier("export-quality-value")
                        }
                        HStack(spacing: 8) {
                            ForEach([60, 80, 92, 100], id: \.self) { q in
                                Button("\(q)") { quality = Double(q) }
                                    .buttonStyle(.bordered).tint(Int(quality) == q ? Theme.accent : .gray)
                            }
                        }
                    } footer: {
                        Text("100 is the largest file. 80–92 usually looks the same at a fraction of the size.")
                    }
                } else {
                    Section { Text("TIFF is saved lossless at 16 bits per channel.").font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Size (long edge)") {
                    Picker("Size", selection: $longEdge) {
                        ForEach(ExportOptions.sizes, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("export-size")
                }
                if hdrAvailable && fmt != .tiff {
                    Section {
                        Toggle("Include HDR", isOn: $hdr)
                    } footer: {
                        Text("Adds an HDR gain map: brighter highlights on HDR screens, the normal photo everywhere else.")
                    }
                }
            }
            .navigationTitle(count > 1 ? "Export \(count) photos" : "Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(count > 1 ? "Export \(count)" : "Export") {
                        let o = ExportOptions(format: fmt, quality: quality, longEdge: longEdge, hdr: hdr)
                        dismiss()
                        onExport(o)
                    }
                    .bold()
                    .accessibilityIdentifier("export-go")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// After a batch export: save them all to Photos, or share / save to Files.
struct BatchExportSheet: View {
    let urls: [URL]
    let save: () async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green)
                Text("\(urls.count) photo\(urls.count == 1 ? "" : "s") exported").font(.headline)
                    .accessibilityIdentifier("batch-exported")
                Button {
                    Task { await save(); dismiss() }
                } label: { Label("Save all to Photos", systemImage: "photo.badge.plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                ShareLink(items: urls) {
                    Label("Share / Save to Files", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .navigationTitle("Exported")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
