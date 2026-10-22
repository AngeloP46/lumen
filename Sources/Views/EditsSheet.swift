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

/// Copy edits… (library and editor), like Lightroom's Copy Settings: choose what Paste will apply. Tools and each mask
/// by name; Select: All / Modified / None. The choice is remembered for next time (masks: all or none).
struct CopyEditsSheet: View {
    let settings: EditSettings
    let sourceName: String
    let copy: (Clipboard) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sel = CopySelection()

    private static let rememberKey = "copySelection"
    private static let rememberMasksKey = "copySelectionAllMasks"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        quick("All", id: "copy-all") { sel = .all(settings) }
                        quick("Modified", id: "copy-modified") { sel = .modified(settings) }
                        quick("None", id: "copy-none") { sel = CopySelection() }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                Section("Tools") {
                    ForEach(CopySelection.tools) { t in
                        row(icon: t.icon, title: t.copyTitle, note: settings.hasEdits(t) ? "Edited" : "No edits",
                            edited: settings.hasEdits(t), id: "copy-\(t.rawValue)",
                            isOn: Binding(get: { sel.has(t) }, set: { sel.set(t, $0) }))
                    }
                    row(icon: "sun.max", title: "HDR", note: settings.hdr ? "On" : "Off", edited: settings.hdr, id: "copy-hdr",
                        isOn: $sel.hdr)
                }
                if !settings.copyableMasks.isEmpty {
                    Section {
                        ForEach(settings.copyableMasks) { m in
                            let ai = m.components.contains { $0.kind.needsAnalysis }
                            row(icon: m.components.first?.kind.icon ?? "circle.dashed", title: m.name,
                                note: ai ? "Found again on each photo" : "Placed as on this photo", edited: true, id: "copy-mask",
                                isOn: Binding(get: { sel.masks.contains(m.id) },
                                              set: { if $0 { sel.masks.insert(m.id) } else { sel.masks.remove(m.id) } }))
                        }
                    } header: { Text("Masks") }
                }
                if settings.aiDenoise > 0, EditSession.hasDenoiseModel {
                    Section {
                        row(icon: "wand.and.sparkles", title: "AI Denoise \(Int(settings.aiDenoise))",
                            note: "Each photo is cleaned first, about a minute each; Paste asks", edited: true, id: "copy-denoise",
                            isOn: $sel.aiDenoise)
                    }
                }
                Section {} footer: {
                    Text("Paste applies exactly what's ticked, to one photo or many. Heal and Lens Blur always stay with each photo.")
                }
            }
            .navigationTitle("Copy edits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        remember()
                        copy(Clipboard(settings: settings, selection: sel, sourceName: sourceName))
                        dismiss()
                    }
                    .disabled(Clipboard(settings: settings, selection: sel, sourceName: sourceName).isEmpty)
                    .accessibilityIdentifier("copy-go")
                }
            }
            .onAppear { sel = recalled() }
        }
        .presentationDetents([.medium, .large])
    }

    private func quick(_ title: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(id)
    }

    private func row(icon: String, title: String, note: String, edited: Bool, id: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(note).font(.caption).foregroundStyle(edited ? Theme.accent : Color.secondary)
                }
            }
        }
        .accessibilityIdentifier(id)
    }

    /// Last time's choice for the tools, HDR and AI Denoise; masks all or none. First time: Modified.
    private func recalled() -> CopySelection {
        let d = UserDefaults.standard
        guard let data = d.data(forKey: Self.rememberKey), var c = try? JSONDecoder().decode(CopySelection.self, from: data) else {
            return .modified(settings)
        }
        c.aiDenoise = c.aiDenoise && settings.aiDenoise > 0
        c.masks = d.bool(forKey: Self.rememberMasksKey) ? Set(settings.copyableMasks.map(\.id)) : []
        return c
    }

    private func remember() {
        var c = sel
        c.masks = []
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: Self.rememberKey) }
        let all = !settings.copyableMasks.isEmpty && settings.copyableMasks.allSatisfy { sel.masks.contains($0.id) }
        if !settings.copyableMasks.isEmpty { UserDefaults.standard.set(all, forKey: Self.rememberMasksKey) }
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
