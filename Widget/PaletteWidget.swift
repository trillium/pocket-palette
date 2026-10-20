import SwiftUI
import WidgetKit
#if WIDGET_UNDER_TEST
@testable import PocketPalette  // only in the unit-test target, which compiles this file to render it
#endif

struct PaletteEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// Reads the snapshot the app last wrote to the App Group. Never touches the network or the Keychain.
struct PaletteProvider: TimelineProvider {
    var store: WidgetSnapshotStore = .shared

    func placeholder(in context: Context) -> PaletteEntry {
        PaletteEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (PaletteEntry) -> Void) {
        let snapshot = context.isPreview ? WidgetSnapshot.sample : (store.load() ?? .empty)
        completion(PaletteEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PaletteEntry>) -> Void) {
        // The app reloads this timeline whenever the ranking changes; the refresh below is only a backstop.
        let entry = PaletteEntry(date: Date(), snapshot: store.load() ?? .empty)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

struct PaletteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PaletteEntry

    var body: some View {
        PaletteWidgetContent(entry: entry, family: family)
    }
}

/// The family is a parameter so tests can render every size (the environment value is read-only).
struct PaletteWidgetContent: View {
    let entry: PaletteEntry
    let family: WidgetFamily

    private var items: [WidgetSnapshot.Item] { entry.snapshot.items }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline: inline
            case .accessoryRectangular: rectangular
            default: home
            }
        }
        .tint(.primary)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var inline: some View {
        Text(items.first.map { "\u{25B6} \($0.rule)" } ?? "Open Palette")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.snapshot.dryRun ? "Palette \u{00B7} DRY RUN" : "Palette")
                .font(.caption2.weight(.semibold))
                .widgetAccentable()
            if items.isEmpty {
                Text("Open the app to load commands").font(.caption)
            }
            ForEach(items) { item in
                Link(destination: item.url) {
                    Text(item.rule).font(.caption).lineLimit(1).foregroundStyle(.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(entry.snapshot.appName ?? "Palette", systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if entry.snapshot.dryRun {
                    Text("DRY RUN")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.25), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            if items.isEmpty {
                Spacer()
                Text("Open Palette to load commands").font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(items) { item in row(item) }
            if !items.isEmpty { Spacer(minLength: 0) }
        }
        // systemSmall allows a single tap target, so the whole widget opens the top command.
        .widgetURL(family == .systemSmall ? items.first?.url : nil)
    }

    @ViewBuilder
    private func row(_ item: WidgetSnapshot.Item) -> some View {
        let label = VStack(alignment: .leading, spacing: 0) {
            Text(item.rule).font(.subheadline).lineLimit(1)
            if family != .systemSmall {
                Text(item.context).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if family == .systemSmall {
            label
        } else {
            Link(destination: item.url) { label.foregroundStyle(.primary) }
        }
    }
}

struct PaletteWidget: Widget {
    let kind = "PaletteTopCommands"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PaletteProvider()) { entry in
            PaletteWidgetView(entry: entry)
        }
        .configurationDisplayName("Top commands")
        .description("The three voice commands that fit what you are doing. Tap one to open it in Palette.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}
