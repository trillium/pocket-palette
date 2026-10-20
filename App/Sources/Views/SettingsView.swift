import SwiftUI

struct SettingsView: View {
    @Bindable var model: SettingsModel
    let buildInfo: BuildInfo
    let historyCount: Int
    let onClearHistory: () -> Void
    @State private var cleared = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("http://host.tailnet.ts.net:7399", text: $model.baseURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("baseURLField")
                }
                if let message = model.message {
                    Section { Text(message).foregroundStyle(.red) }
                }
                Section {
                    Button("Clear run history", role: .destructive) {
                        onClearHistory()
                        cleared = true
                    }
                    .disabled(cleared || historyCount == 0)
                    .accessibilityIdentifier("clearHistoryButton")
                } header: {
                    Text("History")
                } footer: {
                    Text(cleared
                        ? "History cleared."
                        : "\(historyCount) commands run from this phone boost the ranking. Stored only on this device.")
                }
                Section {
                    LabeledContent("Version", value: buildInfo.display)
                        .accessibilityIdentifier("aboutVersion")
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if model.save() { dismiss() } }
                        .disabled(!model.canSave)
                        .accessibilityIdentifier("saveButton")
                }
            }
        }
    }
}
