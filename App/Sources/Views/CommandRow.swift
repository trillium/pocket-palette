import SwiftUI

struct CommandRow: View {
    let match: CommandMatch
    let isStale: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(match.command.rule).font(.body.monospaced())
                HStack(spacing: 6) {
                    Text(match.command.contextName).font(.caption).foregroundStyle(.secondary)
                    if let badge = scopeBadge {
                        Label(badge.text, systemImage: badge.icon).font(.caption2).foregroundStyle(.tint)
                            .accessibilityIdentifier("scopeBadge")
                    }
                    if match.historyBoost > 0 {
                        Image(systemName: "clock.arrow.circlepath").font(.caption2).foregroundStyle(.tint)
                            .accessibilityLabel("Run before").accessibilityIdentifier("historyBadge")
                    }
                }
            }
            Spacer()
            if match.spoken == nil {
                Image(systemName: "text.cursor").foregroundStyle(.secondary).accessibilityLabel("Needs input")
            }
        }
        .contentShape(Rectangle())
        .opacity(isStale ? 0.4 : 1)
    }

    private var scopeBadge: (text: String, icon: String)? {
        switch match.command.scope {
        case .app: (match.command.apps.first ?? "this app", "app.badge")
        case .tag: (match.command.tags.first ?? "tag", "tag")
        case .global: nil
        }
    }
}
