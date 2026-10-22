import SwiftUI

/// Every tool's edits in one place (top bar button): switch a tool off to see the photo without it (its settings are
/// kept), reset one tool, or reset everything (asks first; undo still works).
struct EditsSheet: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmAll = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(EditSection.allCases) { row($0) }
                } footer: {
                    Text("Switch a tool off to compare the photo without it. Its settings are kept until you reset them.")
                }
                Section {
                    Button(role: .destructive) { confirmAll = true } label: {
                        Label("Reset all edits", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(vm.settings.isDefault)
                    .accessibilityIdentifier("edits-reset-all")
                }
            }
            .navigationTitle("Edits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Reset all edits on this photo?", isPresented: $confirmAll, titleVisibility: .visible) {
                Button("Reset all edits", role: .destructive) { vm.reset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Undo can bring them back.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private func row(_ sec: EditSection) -> some View {
        let edited = vm.settings.hasEdits(sec)
        let on = vm.settings.isOn(sec)
        return HStack(spacing: 12) {
            Image(systemName: sec.icon)
                .font(.system(size: 16))
                .frame(width: 26)
                .foregroundStyle(on ? Color.white : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(sec.rawValue).font(.system(size: 15, weight: .medium))
                Text(!edited ? "No edits" : (on ? "Edited" : "Switched off"))
                    .font(.caption)
                    .foregroundStyle(!edited ? Color.secondary : (on ? Theme.accent : Color.orange))
            }
            Spacer()
            Button { vm.settings.reset(sec) } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!edited)
            .accessibilityIdentifier("edits-reset-\(sec.rawValue)")
            if sec.canSwitchOff {
                Toggle(sec.rawValue, isOn: Binding(get: { on }, set: { vm.settings.setOn(sec, $0) }))
                    .labelsHidden()
                    // nothing to switch off until the tool has edits (a switched-off tool can always come back on)
                    .disabled(!edited && on)
                    .accessibilityIdentifier("edits-toggle-\(sec.rawValue)")
            } else {
                Color.clear.frame(width: 51, height: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Paste some edits: choose which tools to take from the copied edits. Tools the copy has edits in start ticked,
/// except Crop (a crop rarely fits another photo; Lightroom leaves it out by default too).
struct PasteSomeSheet: View {
    let clip: EditSettings
    /// How many photos it pastes onto (the library's "Choose…" can pick several).
    var photos = 1
    /// The sections, and whether AI Denoise goes too (it needs a clean of each photo).
    let paste: (Set<EditSection>, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<EditSection> = []
    @State private var denoise = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(EditSection.allCases.filter(\.canPaste)) { sec in
                        let has = clip.hasEdits(sec)
                        Toggle(isOn: Binding(get: { chosen.contains(sec) },
                                             set: { if $0 { chosen.insert(sec) } else { chosen.remove(sec) } })) {
                            HStack(spacing: 12) {
                                Image(systemName: sec.icon).frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sec.rawValue)
                                    Text(has ? "Has edits" : "No edits (pasting resets it)")
                                        .font(.caption).foregroundStyle(has ? Theme.accent : Color.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("paste-toggle-\(sec.rawValue)")
                    }
                } footer: {
                    Text(photos == 1 ? "Only the ticked tools are pasted. The rest of this photo stays as it is."
                         : "Only the ticked tools are pasted onto the \(photos) photos. The rest of each stays as it is.")
                }
                if clip.aiDenoise > 0, EditSession.hasDenoiseModel {
                    Section {
                        Toggle(isOn: $denoise) {
                            HStack(spacing: 12) {
                                Image(systemName: "wand.and.sparkles").frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("AI Denoise \(Int(clip.aiDenoise))")
                                    Text(photos == 1 ? "Cleans this photo: about a minute (2 for 48 MP ProRAW)"
                                         : "Cleans up to \(min(photos, LibraryStore.denoiseBatchCap)) photos, one after another: about a minute each")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("paste-toggle-denoise")
                    }
                }
            }
            .navigationTitle(photos == 1 ? "Paste some edits" : "Paste onto \(photos) photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Paste") { paste(chosen, denoise); dismiss() }
                        .disabled(chosen.isEmpty && !denoise)
                        .accessibilityIdentifier("paste-go")
                }
            }
            .onAppear { chosen = Set(EditSection.allCases.filter { $0 != .crop && clip.hasEdits($0) }) }
        }
        .presentationDetents([.medium, .large])
    }
}


/// ⋯ → History: every edit step since the photo's undo history began; tap one to go back to it (redo comes forward).
struct HistorySheet: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(vm.historySteps) { step in
                Button {
                    vm.goBack(step.back)
                    dismiss()
                } label: {
                    HStack {
                        Text(step.label)
                        Spacer()
                        if step.back == 0 { Text("Now").font(.caption).foregroundStyle(Theme.accent) }
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("history-step")
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
