import SwiftUI

/// Rules with `<captures>` or `{lists}` need a concrete phrase; the user edits the template and sends it.
struct PhraseSheet: View {
    let match: CommandMatch
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phrase: String

    init(match: CommandMatch, onSend: @escaping (String) -> Void) {
        self.match = match
        self.onSend = onSend
        _phrase = State(initialValue: match.command.rule)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rule") { Text(match.command.rule).font(.body.monospaced()) }
                Section("Phrase to say") {
                    TextField("Phrase", text: $phrase, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("phraseField")
                }
                Section { Text("Replace the <captures> and {lists} with what you would say out loud.").font(.footnote) }
            }
            .navigationTitle("Fill in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") {
                        onSend(phrase.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(phrase.trimmingCharacters(in: .whitespaces).isEmpty || phrase.contains("<") || phrase.contains("{"))
                }
            }
        }
        .presentationDetents([.medium])
    }
}
