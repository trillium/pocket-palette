import SwiftUI

/// The engine's current mode and context, or why there is none.
struct StateBar: View {
    let model: PaletteModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.subheadline.weight(.semibold))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stateBar")
    }

    private var color: Color {
        switch model.connection {
        case .online: model.state?.inCommandMode == false ? .orange : .green
        case .connecting, .unconfigured: .gray
        case .offline, .unauthorized: .red
        }
    }

    private var headline: String {
        switch model.connection {
        case .unconfigured: return "Not configured"
        case .connecting: return "Connecting\u{2026}"
        case .offline: return "Mac offline"
        case .unauthorized: return "Unauthorized"
        case .online:
            guard let state = model.state else { return "Online" }
            let modes = state.modes.filter { $0 != "all" }.joined(separator: ", ")
            return state.inCommandMode ? "Command mode" : "Modes: \(modes)"
        }
    }

    private var detail: String? {
        switch model.connection {
        case .offline: return "Showing the last known command list"
        case .unauthorized: return "The feed requires a token; this app sends none"
        case .online:
            guard let state = model.state else { return nil }
            let title = state.window.title.isEmpty ? "" : " \u{2014} \(state.window.title)"
            return "\(state.host) \u{00B7} \(state.app.name)\(title)"
        case .connecting, .unconfigured: return nil
        }
    }
}
