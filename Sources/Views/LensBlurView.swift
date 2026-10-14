import SwiftUI

/// A photo-specific focus tool. The existing Masks editor supplies optional brush/range corrections.
struct LensBlurPanel: View {
    @ObservedObject var vm: EditorViewModel
    var refine: () -> Void

    private func value(_ key: WritableKeyPath<LensBlurSettings, Double>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { vm.settings.lensBlur[keyPath: key] * scale }, set: { newValue in
            var s = vm.settings
            s.lensBlur[keyPath: key] = newValue / scale
            if key != \.amount { s.lensBlur.maskID = nil }
            vm.settings = s
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if vm.autoMaskBusy {
                    HStack { ProgressView().tint(.white); Text("Measuring depth…") }
                        .font(.caption).accessibilityIdentifier("lens-blur-status")
                } else if vm.depthField == nil {
                    Text("Depth couldn't be estimated for this photo. Blur hasn't been applied.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("lens-blur-status")
                } else {
                    Button { vm.lensBlurPicking.toggle() } label: {
                        Label(vm.lensBlurPicking ? "Tap the subject in the photo" : "Pick focus", systemImage: "viewfinder")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("lens-blur-focus")
                }
                LabeledSlider(title: "Blur amount", value: value(\.amount), neutral: 0, labelWidth: 94)
                    .disabled(vm.depthField == nil || vm.autoMaskBusy)
                LabeledSlider(title: "Focus distance", value: value(\.focusDistance, scale: 100), neutral: 30, labelWidth: 94)
                    .disabled(vm.depthField == nil || vm.autoMaskBusy)
                LabeledSlider(title: "Focus range", value: value(\.focusWidth, scale: 100), range: 2...50, neutral: 12, labelWidth: 94)
                    .disabled(vm.depthField == nil || vm.autoMaskBusy)
                HStack {
                    Button("Refine background", action: refine)
                        .disabled(vm.depthField == nil || vm.autoMaskBusy)
                        .accessibilityIdentifier("lens-blur-refine")
                    Spacer()
                    Button("Reset") { vm.settings.reset(.lensBlur); vm.lensBlurPicking = false }
                        .accessibilityIdentifier("lens-blur-reset")
                }
                .font(.system(size: 13, weight: .medium)).frame(minHeight: 44)
                Text("Keeps the focus distance sharp and softens what's behind it. Depth is estimated; refine the background around difficult edges.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
        }
    }
}
