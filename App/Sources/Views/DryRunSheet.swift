import SwiftUI

/// Dry run: shows the exact request a tap or Run would send; Confirm asks the feed with `dry_run=1`, which runs nothing.
struct DryRunSheet: View {
    let model: PaletteModel
    let preview: DryRunPreview
    @Environment(\.dismiss) private var dismiss

    private var outcome: DryRunOutcome? { model.dryRunOutcome.flatMap { $0.previewID == preview.id ? $0 : nil } }
    private var confirmed: Bool { outcome != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("DRY RUN \u{2014} the Mac runs nothing", systemImage: "hand.raised.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("dryRunBanner")
                }
                Section("Phrase") {
                    Text(preview.phrase).font(.body.monospaced())
                        .accessibilityIdentifier("dryRunPhrase")
                }
                Section("Request it would send") {
                    Text(preview.requestText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("dryRunRequest")
                }
                if let outcome {
                    Section("The Mac would run (dry_run=1, nothing executed)") {
                        Label(
                            outcome.error == nil ? "Checked: nothing was executed" : "Refused: nothing was executed",
                            systemImage: outcome.error == nil ? "checkmark.circle.fill" : "xmark.octagon.fill"
                        )
                        .foregroundStyle(outcome.error == nil ? .green : .red)
                        .accessibilityIdentifier("dryRunResultLabel")
                        Text(outcome.text)
                            .font(.caption.monospaced())
                            .accessibilityIdentifier("dryRunResult")
                    }
                }
            }
            .navigationTitle("Dry run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(confirmed ? "Done" : "Cancel") { dismiss() }
                        .accessibilityIdentifier("dryRunCancel")
                }
                if !confirmed {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Confirm") { Task { await model.confirmDryRun() } }
                            .accessibilityIdentifier("dryRunConfirm")
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}
