import SwiftUI

/// The open-source AI models Lumen ships and their licences (Apache 2.0 asks that the licence travels with the model).
/// Opened from the library's menu.
struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Credit: Identifiable {
        let id = UUID()
        let feature, model, authors, source: String
    }

    private let credits = [
        Credit(feature: "AI Denoise", model: "SCUNet (real noise)", authors: "Kai Zhang, Yawei Li, Jingyun Liang and others",
               source: "github.com/cszn/SCUNet"),
        Credit(feature: "Heal and Remove people", model: "LaMa inpainting", authors: "Roman Suvorov and others (Samsung AI Center); Core ML version by mlboydaisuke",
               source: "github.com/advimman/lama"),
        Credit(feature: "Depth mask and Lens Blur", model: "Depth Anything V2 Small", authors: "Lihe Yang and others; Core ML version by Apple",
               source: "huggingface.co/apple/coreml-depth-anything-v2-small"),
        Credit(feature: "Sky and landscape masks", model: "DETR ResNet-50 semantic segmentation", authors: "Facebook AI Research; Core ML version by Apple",
               source: "huggingface.co/apple/coreml-detr-semantic-segmentation"),
    ]

    private var licenceText: String {
        Bundle.main.url(forResource: "Apache-2.0", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "Apache License, Version 2.0: https://www.apache.org/licenses/LICENSE-2.0"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Lumen runs these open-source AI models on your iPhone. Each is used under the Apache License 2.0, shown below.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(credits) { c in
                    Section(c.feature) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.model).font(.headline)
                            Text(c.authors).font(.subheadline).foregroundStyle(.secondary)
                            Text(c.source).font(.footnote).foregroundStyle(.secondary)
                            Text("Apache License 2.0").font(.footnote)
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section("Apache License 2.0") {
                    Text(licenceText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }
            .navigationTitle("Acknowledgements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("ack-done") } }
            .accessibilityIdentifier("acknowledgements")
        }
    }
}
