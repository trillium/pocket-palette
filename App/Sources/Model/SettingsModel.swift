import Foundation
import Observation

/// Backs the settings screen: the server URL only (no token; the tailnet is the trust boundary).
@MainActor
@Observable
final class SettingsModel {
    var baseURLText: String
    private(set) var message: String?

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
        baseURLText = settings.load().baseURLText
    }

    var canSave: Bool { ServerSettings(baseURLText: baseURLText).baseURL != nil }

    /// Returns true when saved.
    func save() -> Bool {
        guard canSave else {
            message = "Enter an http:// or https:// URL"
            return false
        }
        settings.save(ServerSettings(baseURLText: baseURLText))
        message = nil
        return true
    }
}
