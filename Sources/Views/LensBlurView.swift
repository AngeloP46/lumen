import SwiftUI

/// A photo-specific focus tool. The existing Masks editor supplies optional brush/range corrections.
struct LensBlurPanel: View {
    @ObservedObject var vm: EditorViewModel
    var refine: () -> Void

    private var distance: Binding<Double> {
        let range = vm.depthField?.usefulRange ?? 0...1
        let span = max(range.upperBound - range.lowerBound, 0.001)
        return Binding(get: { min(max((vm.settings.lensBlur.focusDistance - range.lowerBound) / span * 100, 0), 100) }, set: {
            value(\.focusDistance).wrappedValue = range.lowerBound + $0 / 100 * span
        })
    }

    private func value(_ key: WritableKeyPath<LensBlurSettings, Double>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { vm.settings.lensBlur[keyPath: key] * scale }, set: { newValue in
            var s = vm.settings
            s.lensBlur[keyPath: key] = newValue / scale
            if key != \.amount { s.lensBlur.maskID = nil }
            vm.settings = s
        })
    }

    var body: some View {
        if vm.lensBlurRefining {
            VStack(spacing: 4) {
                HStack {
                    Text("Refine background").font(.headline)
                    Spacer()
                    Button("Done") { vm.lensBlurRefining = false }
                        .accessibilityIdentifier("lens-blur-refine-done")
                }.frame(minHeight: 44).padding(.horizontal, 14)
                MaskPanel(vm: vm, lensOnly: true)
            }
        } else {
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
                LabeledSlider(title: "Blur amount", value: value(\.amount), neutral: 0, labelWidth: 94, onActive: { vm.lensSliderActive = $0 })
                    .disabled(vm.depthField == nil || vm.autoMaskBusy)
                LabeledSlider(title: "Focus distance", value: distance, neutral: 30, labelWidth: 94, onActive: { vm.lensSliderActive = $0 })
                    .disabled(vm.depthField == nil || vm.autoMaskBusy)
                LabeledSlider(title: "Focus range", value: value(\.focusWidth, scale: 100), range: 2...100, neutral: 12, labelWidth: 94, onActive: { vm.lensSliderActive = $0 })
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
                Toggle("Preview selection while sliding", isOn: $vm.lensPreviewEnabled)
                    .font(.caption).accessibilityIdentifier("lens-blur-preview")
                Text(vm.lensFocusMessage ?? "Protects detected subjects and gradually softens farther background. Distance is relative, not metres. Refine difficult edges with a brush.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
        }
        }
    }
}
