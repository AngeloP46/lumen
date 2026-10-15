import SwiftUI

/// The same depth band, feather rows and brush refinement used by Masks.
struct LensBlurPanel: View {
    @ObservedObject var vm: EditorViewModel
    var refine: () -> Void

    private var depthComponent: MaskComponent {
        if let id = vm.settings.lensBlur.maskID,
           let c = vm.settings.masks.first(where: { $0.id == id })?.components.first(where: { $0.kind == .depth }) { return c }
        var c = MaskComponent.make(.depth)
        c.lumLow = vm.settings.lensBlur.fullFrom
        c.lumHigh = 1; c.lumLowFeather = vm.settings.lensBlur.fullFrom - vm.settings.lensBlur.rampStart; c.lumHighFeather = 0
        return c
    }
    private func depthValue(_ key: WritableKeyPath<MaskComponent, Double>) -> Binding<Double> {
        Binding(get: { depthComponent[keyPath: key] }, set: { value in
            vm.updateLensDepth { $0[keyPath: key] = value; if $0.amount == 0 { $0.amount = 100 } }
        })
    }
    private var amount: Binding<Double> {
        Binding(get: { vm.settings.lensBlur.amount }, set: { value in
            var s = vm.settings; s.lensBlur.amount = value; s.lensBlur.activated = true; s.lensBlur.controlsVersion = 1
            vm.settings = s
        })
    }
    var body: some View {
        if vm.lensBlurRefining {
            VStack(spacing: 4) {
                HStack {
                    Text("Refine background").font(.headline)
                    Spacer()
                    IconButton(system: vm.overlayEnabled ? "eye" : "eye.slash", active: vm.overlayEnabled) {
                        vm.overlayEnabled.toggle()
                    }.accessibilityIdentifier("lens-blur-refine-eye")
                    Button("Done") { vm.lensBlurRefining = false }
                        .accessibilityIdentifier("lens-blur-refine-done")
                }.frame(minHeight: 44).padding(.horizontal, 14)
                MaskPanel(vm: vm, lensOnly: true)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button { vm.lensBlurPicking.toggle(); vm.lensSelectionPreview = false } label: {
                            Label(vm.lensBlurPicking ? "Tap subject in photo" : (vm.settings.lensBlur.subjectPoint == nil ? "Select subject" : "Change subject"), systemImage: "viewfinder")
                                .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(.white)
                                .background(vm.lensBlurPicking ? Theme.accent : Theme.chip, in: RoundedRectangle(cornerRadius: 10))
                        }.accessibilityIdentifier("lens-blur-focus")
                        IconButton(system: vm.lensSelectionPreview ? "eye.fill" : "eye", active: vm.lensSelectionPreview) {
                            vm.toggleLensSelectionPreview()
                        }.frame(width: 44, height: 44).accessibilityIdentifier("lens-blur-selection-eye")
                            .accessibilityLabel("Show background selection").accessibilityValue(vm.lensSelectionPreview ? "shown" : "hidden")
                    }.disabled(vm.depthField == nil || vm.autoMaskBusy)
                    if vm.autoMaskBusy {
                        HStack { ProgressView(); Text(vm.lensFocusMessage == "Selecting subject…" ? "Selecting subject…" : "Finding depth…") }.font(.caption)
                    } else if vm.depthField == nil {
                        Text("Depth couldn't be estimated. Blur hasn't been applied.").font(.caption).foregroundStyle(.secondary)
                    } else if vm.lensBlurPicking {
                        Text("Tap the subject you want to keep sharp.").font(.caption).foregroundStyle(Theme.accent)
                            .accessibilityIdentifier("lens-focus-feedback")
                    } else if let message = vm.lensFocusMessage {
                        Label(message, systemImage: message.hasPrefix("Subject selected") ? "checkmark.circle.fill" : "info.circle")
                            .font(.caption).foregroundStyle(Theme.accent).accessibilityIdentifier("lens-focus-feedback")
                    }
                    LabeledSlider(title: "Blur amount", value: amount, neutral: 0, labelWidth: 94, onActive: { vm.lensSliderActive = $0 })
                        .disabled(vm.depthField == nil)
                    LumRangeEditor(low: depthValue(\.lumLow), high: depthValue(\.lumHigh),
                                   lowFeather: depthValue(\.lumLowFeather), highFeather: depthValue(\.lumHighFeather),
                                   histogram: vm.depthField?.histogram, depth: true, onActive: { vm.lensSliderActive = $0 })
                        .disabled(vm.depthField == nil)
                    HStack {
                        Button("Refine with brush", action: refine).accessibilityIdentifier("lens-blur-refine")
                            .disabled(vm.depthField == nil)
                        Spacer()
                        // preference, not an everyday control: shows red over the background while a slider moves
                        Button { vm.lensPreviewEnabled.toggle() } label: {
                            Image(systemName: vm.lensPreviewEnabled ? "square.dashed.inset.filled" : "square.dashed")
                                .frame(width: 44, height: 44)
                        }
                        .foregroundStyle(vm.lensPreviewEnabled ? Theme.accent : .secondary)
                        .accessibilityIdentifier("lens-blur-preview")
                        .accessibilityLabel("Show background in red while sliding")
                        .accessibilityValue(vm.lensPreviewEnabled ? "1" : "0")
                        Button("Reset") { vm.settings.reset(.lensBlur); vm.lensBlurPicking = false; vm.lensSelectionPreview = false }
                            .accessibilityIdentifier("lens-blur-reset")
                    }.font(.system(size: 13, weight: .medium)).frame(minHeight: 44)
                    if vm.settings.lensBlur.subjectPoint == nil && vm.lensFocusMessage == nil && !vm.lensBlurPicking {
                        Text("Select the subject to keep sharp, then set where the blur starts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
    }
}
