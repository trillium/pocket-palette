import Foundation

/// Connection settings. There is no secret: the tailnet is the trust boundary.
struct ServerSettings: Equatable, Sendable {
    /// Build-time prefill: Info.plist `PaletteServerURL` = `http://$(PALETTE_SERVER_HOST)`, set in the gitignored
    /// `Config/Local.xcconfig`. Empty when that file does not set it: the app then shows "Not set up".
    static let prefilledBaseURL = prefill(Bundle.main.object(forInfoDictionaryKey: "PaletteServerURL") as? String)

    static func prefill(_ raw: String?) -> String {
        validate(raw ?? "")?.absoluteString ?? ""
    }

    var baseURLText: String

    /// http or https. Plain http reaches only `*.ts.net` hosts: that is the one App Transport Security exception.
    static func validate(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else {
            return nil
        }
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    var baseURL: URL? { Self.validate(baseURLText) }
}

protocol SettingsStore: Sendable {
    func load() -> ServerSettings
    func save(_ settings: ServerSettings)
}

struct UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let fallback: String
    /// Was "serverBaseURL" in the https + token builds; renamed so the URL those builds saved gives way to the prefill.
    static let key = "serverURL"

    init(defaults: UserDefaults = .standard, fallback: String = ServerSettings.prefilledBaseURL) {
        self.defaults = defaults
        self.fallback = fallback
    }

    /// A missing or empty saved value means the build-time prefill (UI tests launch with `-serverURL ""`).
    func load() -> ServerSettings {
        let saved = defaults.string(forKey: Self.key) ?? ""
        return ServerSettings(baseURLText: saved.isEmpty ? fallback : saved)
    }

    func save(_ settings: ServerSettings) {
        defaults.set(settings.baseURLText.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.key)
    }
}
