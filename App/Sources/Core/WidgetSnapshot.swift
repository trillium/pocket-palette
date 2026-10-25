import Foundation

/// What the home/Lock Screen widget shows: the top commands, already ranked by the app, plus enough state to
/// say how fresh it is. Shared source: compiled into the app and the widget extension, so it depends on nothing
/// else in the app. Holds rule text only, never the token or the server URL.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let rule: String
        /// Subtitle: the defining command file name.
        let context: String
        /// "app", "tag" or "global".
        let scope: String

        /// Tap target: opens the app, which runs it through the same Dry run gate as an in-app tap.
        var url: URL { WidgetLink.url(forCommand: id) }
    }

    /// How many rows the widget ever shows.
    static let limit = 3

    var items: [Item]
    /// Frontmost Mac app when the snapshot was taken, if known.
    var appName: String?
    /// The app's Dry run switch at snapshot time (the widget only displays it; the app enforces it).
    var dryRun: Bool
    var updatedAt: Date

    static let empty = WidgetSnapshot(items: [], appName: nil, dryRun: false, updatedAt: .distantPast)

    /// Placeholder content for the widget gallery and previews.
    static let sample = WidgetSnapshot(
        items: [
            Item(id: "s1", rule: "tab (open | new)", context: "browser.voice", scope: "app"),
            Item(id: "s2", rule: "go back", context: "browser.voice", scope: "app"),
            Item(id: "s3", rule: "page down", context: "scroll.voice", scope: "global")
        ],
        appName: "Safari", dryRun: true, updatedAt: Date()
    )
}

/// The App Group and URL scheme this build uses. Both come from the Info.plist (APP_GROUP_ID and PALETTE_URL_SCHEME in
/// Config/*.xcconfig) so the beta app and its widget use their own and never touch the stable app's data or links.
enum SharedIdentity {
    static func value(_ key: String, fallback: String, bundle: Bundle = .main) -> String {
        let value = bundle.object(forInfoDictionaryKey: key) as? String
        guard let value, !value.isEmpty, !value.hasPrefix("$(") else { return fallback }
        return value
    }

    static var appGroup: String { value("PaletteAppGroup", fallback: "group.com.trillium.pocketpalette") }
    static var urlScheme: String { value("PaletteURLScheme", fallback: "pocketpalette") }
}

/// The `pocketpalette://command?id=...` links the widget opens (`pocketpalette-beta://` in the beta app).
enum WidgetLink {
    static var scheme: String { SharedIdentity.urlScheme }

    static func url(forCommand id: String) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "command"
        parts.queryItems = [URLQueryItem(name: "id", value: id)]
        return parts.url ?? URL(fileURLWithPath: "/")
    }

    /// The command id in a widget link, or nil for any other URL.
    static func commandID(in url: URL) -> String? {
        guard url.scheme == scheme, url.host == "command",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty else { return nil }
        return id
    }
}

/// The snapshot as one JSON file in the App Group container. Unsigned builds have no container: both sides
/// then see nil / do nothing, and the widget falls back to its empty state.
struct WidgetSnapshotStore: Sendable {
    static var appGroup: String { SharedIdentity.appGroup }
    let fileURL: URL?

    static var shared: WidgetSnapshotStore {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        return WidgetSnapshotStore(fileURL: base?.appendingPathComponent("widget-snapshot.json"))
    }

    func load() -> WidgetSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.snapshot.decode(WidgetSnapshot.self, from: data)
    }

    /// Returns true when the stored snapshot changed (ignoring `updatedAt`), i.e. the widget should reload.
    @discardableResult
    func save(_ snapshot: WidgetSnapshot) -> Bool {
        guard let fileURL, let data = try? JSONEncoder.snapshot.encode(snapshot) else { return false }
        if var old = load() {
            old.updatedAt = snapshot.updatedAt
            if old == snapshot { return false }
        }
        return (try? data.write(to: fileURL, options: .atomic)) != nil
    }
}

private extension JSONEncoder {
    static var snapshot: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var snapshot: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
