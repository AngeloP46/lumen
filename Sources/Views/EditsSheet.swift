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
