import SwiftUI

/// Result of the last tap, shown for a few seconds. Errors stay a little longer.
struct FeedbackBanner: View {
    let model: PaletteModel

    var body: some View {
        if let feedback = model.feedback {
            Label(feedback.text, systemImage: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(feedback.isError ? Color.red : Color.green, in: Capsule())
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("feedbackBanner")
                .task(id: feedback.id) {
                    try? await Task.sleep(for: .seconds(feedback.isError ? 4 : 2))
                    if !Task.isCancelled { model.dismissFeedback() }
                }
        }
    }
}
