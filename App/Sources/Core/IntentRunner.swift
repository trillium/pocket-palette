import Foundation

/// Search and run behind Siri/Spotlight (App Intents). Pure of the AppIntents framework so tests can drive it
/// with fakes: commands come from the disk cache only, and run goes through `PaletteAPI.execute` unless Dry run is on.
struct IntentRunner: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        case ran(rule: String)
        /// Dry run was on: the request was built, not sent.
        case dryRun(rule: String)
        case failed(String)

        var message: String {
            switch self {
            case .ran(let rule): "Ran \u{201C}\(rule)\u{201D}"
            case .dryRun(let rule): "Dry run: \u{201C}\(rule)\u{201D} was not sent"
            case .failed(let text): text
            }
        }
    }

    /// Same key as `PaletteModel.dryRunKey` (that one is main-actor isolated).
    static let dryRunKey = "dryRunMode"

    let settings: SettingsStore
    let cache: CommandCaching
    let defaults: UserDefaults
    let makeAPI: @Sendable (URL) -> PaletteAPI

    init(
        settings: SettingsStore = UserDefaultsSettingsStore(),
        cache: CommandCaching = DiskCommandCache.standard,
        defaults: UserDefaults = .standard,
        makeAPI: @escaping @Sendable (URL) -> PaletteAPI = { PaletteAPI(baseURL: $0) }
    ) {
        self.settings = settings
        self.cache = cache
        self.defaults = defaults
        self.makeAPI = makeAPI
    }

    /// Cached commands for the configured server; empty when unconfigured or never fetched.
    func commands() -> [PaletteCommand] {
        guard let url = settings.load().baseURL else { return [] }
        return cache.load(server: url.absoluteString)?.commands ?? []
    }

    func commands(ids: [String]) -> [PaletteCommand] {
        let wanted = Set(ids)
        return commands().filter { wanted.contains($0.id) }
    }

    /// Fuzzy search over the cached list, best first.
    func search(_ text: String, limit: Int = 25) -> [PaletteCommand] {
        let ranked = CommandIndex(commands()).search(text, options: SearchOptions())
        return ranked.prefix(limit).map(\.command)
    }

    func run(id: String, phrase: String? = nil) async -> Outcome {
        guard let url = settings.load().baseURL else {
            return .failed(PaletteError.notConfigured.message)
        }
        guard let command = commands().first(where: { $0.id == id }) else {
            return .failed(PaletteError.rejected(status: 404, code: "unknown_command", wouldRun: nil).message)
        }
        guard let text = phrase ?? RuleSpeller.spoken(command.rule) else {
            return .failed("This command needs a phrase: run it from the app")
        }
        let api = makeAPI(url)
        // Same gate as PaletteModel.execute: Dry run never reaches the transport.
        if defaults.bool(forKey: Self.dryRunKey) {
            do {
                _ = try api.executeRequest(phrase: text, id: command.id)
                return .dryRun(rule: command.rule)
            } catch {
                return .failed((error as? PaletteError)?.message ?? PaletteError.invalidResponse.message)
            }
        }
        do {
            let result = try await api.execute(phrase: text, id: command.id)
            return .ran(rule: result.matchedRule)
        } catch {
            return .failed((error as? PaletteError)?.message ?? PaletteError.invalidResponse.message)
        }
    }
}
