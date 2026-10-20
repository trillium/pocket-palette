import Foundation
import Observation

/// Main-screen state: connection, the engine `/state`, the command list (live or cached), and execute feedback.
@MainActor
@Observable
final class PaletteModel {
    enum Connection: Equatable {
        case unconfigured, connecting, online, offline, unauthorized
    }

    struct Feedback: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    private(set) var connection: Connection = .unconfigured
    private(set) var state: PaletteState?
    private(set) var feedback: Feedback?
    private(set) var isExecuting = false
    private(set) var commandCount = 0
    /// Set while a dry-run tap or Run waits for Confirm; the sheet shows exactly what would be sent.
    private(set) var dryRunPreview: DryRunPreview?
    /// Set by Confirm in dry-run mode: what the feed says would run (`dry_run=1`). Cleared when the sheet closes.
    private(set) var dryRunOutcome: DryRunOutcome?
    var query = ""
    /// Dry run: taps and Run show the request instead of running it; Confirm only asks the feed with `dry_run=1`.
    /// Off by default.
    /// Persisted under `dryRunMode`, which also makes `-dryRunMode YES` a launch argument for UI tests.
    var dryRun: Bool {
        didSet {
            defaults.set(dryRun, forKey: Self.dryRunKey)
            publishWidget()
        }
    }

    /// Rank commands from the frontmost app's (or an active tag's) contexts above global ones. Default on.
    /// Persisted under `contextBoost`. It reorders only; `thisAppOnly` is the hard filter.
    var contextBoost: Bool {
        didSet { defaults.set(contextBoost, forKey: Self.contextBoostKey) }
    }
    /// Show only commands whose context names the frontmost app. Per session, off at launch.
    var thisAppOnly = false
    /// Commands run from this device (real executes and dry-run confirms); drives the recent/frequent boost.
    private(set) var history: ExecuteHistory

    private var index = CommandIndex([])
    private let widget: WidgetPublishing
    private var commands: [PaletteCommand] = []
    private var commandsRev: String?
    private var api: PaletteAPI?
    private var serverKey = ""
    private var backoff = Backoff()

    static let dryRunKey = "dryRunMode"
    static let contextBoostKey = "contextBoost"
    private let defaults: UserDefaults
    private let historyStore: ExecuteHistoryStoring
    private let now: @Sendable () -> Date
    private let settings: SettingsStore
    private let cache: CommandCaching
    private let makeAPI: @Sendable (URL) -> PaletteAPI

    init(
        settings: SettingsStore,
        cache: CommandCaching,
        defaults: UserDefaults = .standard,
        history historyStore: ExecuteHistoryStoring? = nil,
        widget: WidgetPublishing = NoWidgetPublisher(),
        now: @escaping @Sendable () -> Date = { Date() },
        makeAPI: @escaping @Sendable (URL) -> PaletteAPI = { PaletteAPI(baseURL: $0) }
    ) {
        self.defaults = defaults
        self.widget = widget
        dryRun = defaults.bool(forKey: Self.dryRunKey)
        contextBoost = defaults.object(forKey: Self.contextBoostKey) as? Bool ?? true
        let store = historyStore ?? UserDefaultsHistoryStore(defaults: defaults)
        self.historyStore = store
        history = store.load()
        self.now = now
        self.settings = settings
        self.cache = cache
        self.makeAPI = makeAPI
        reloadConfiguration()
    }

    var results: [CommandMatch] {
        index.search(
            query,
            options: SearchOptions(contextBoost: contextBoost, appOnly: thisAppOnly, history: history, now: now())
        )
    }

    /// Name of the frontmost app on the Mac, for the "this app only" chip.
    var appName: String? { state.flatMap { $0.app.name.isEmpty ? nil : $0.app.name } }

    /// Rows are greyed whenever the list on screen may not be what the engine currently has.
    var isStale: Bool { connection != .online }

    // MARK: - Configuration

    /// Re-reads settings; call after the settings screen saves.
    func reloadConfiguration() {
        guard let url = settings.load().baseURL else {
            api = nil
            connection = .unconfigured
            state = nil
            return
        }
        api = makeAPI(url)
        if serverKey != url.absoluteString {
            serverKey = url.absoluteString
            apply(commands: [], rev: nil, publish: false)
            let cached = cache.load(server: serverKey)
            apply(commands: cached?.commands ?? [], rev: cached?.rev)
        }
        connection = .connecting
        backoff = Backoff()
    }

    // MARK: - Polling

    /// Polls `/state` until cancelled: 1.5 s while healthy, doubling to 20 s while failing.
    func pollForever() async {
        while !Task.isCancelled {
            let healthy = await pollOnce()
            let delay = healthy ? backoff.current : backoff.failure()
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    @discardableResult
    func pollOnce() async -> Bool {
        guard let api else { return false }
        do {
            let fresh = try await api.state()
            let appChanged = fresh.app.name != state?.app.name
            state = fresh
            if appChanged { publishWidget() }
            connection = .online
            backoff.success()
            if fresh.commandsRev != commandsRev { await refreshCommands() }
            return true
        } catch is CancellationError {
            return false
        } catch {
            fail(with: error)
            return false
        }
    }

    func refreshCommands() async {
        guard let api else { return }
        do {
            switch try await api.commands(knownRev: commandsRev) {
            case .notModified:
                break
            case .updated(let list):
                apply(commands: list.commands, rev: list.commandsRev)
                cache.save(CachedCommands(server: serverKey, rev: list.commandsRev, commands: list.commands))
            }
        } catch is CancellationError {
            return
        } catch {
            fail(with: error)
        }
    }

    // MARK: - Execute

    /// Runs a row: `phrase` (default: the rule's spoken form) goes through `run`, the same path as the Run field.
    @discardableResult
    func execute(_ command: PaletteCommand, phrase: String? = nil) async -> Bool {
        guard api != nil else {
            show(PaletteError.notConfigured.message, isError: true)
            return false
        }
        guard let text = phrase ?? RuleSpeller.spoken(command.rule) else { return false }
        return await send(text, command: command)
    }

    /// The Run field: free text, run by the engine as if spoken (`POST /inject`). Returns true when it ran.
    @discardableResult
    func run(_ text: String) async -> Bool {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return false }
        return await send(phrase, command: nil)
    }

    /// The single gate. In dry-run mode the request is staged for `confirmDryRun` and nothing runs.
    private func send(_ phrase: String, command: PaletteCommand?) async -> Bool {
        guard let api else {
            show(PaletteError.notConfigured.message, isError: true)
            return false
        }
        guard !isExecuting else { return false }
        if dryRun { return stageDryRun(command, phrase: phrase, api: api) }
        isExecuting = true
        defer { isExecuting = false }
        do {
            let result = try await api.inject(phrase: phrase)
            connection = .online
            let ran = result.rules.isEmpty ? phrase : result.rules.joined(separator: ", ")
            show("Ran \u{201C}\(ran)\u{201D}", isError: false)
            if let command { recordRun(command) }
            return true
        } catch is CancellationError {
            return false
        } catch {
            fail(with: error)
            return false
        }
    }

    /// Widget tap (`pocketpalette://command?id=`). Goes through `execute`, so Dry run stages instead of sending.
    func openFromWidget(commandID: String) async {
        guard let command = commands.first(where: { $0.id == commandID }) else {
            show("That command is no longer available", isError: true)
            return
        }
        await execute(command)
    }

    func clearHistory() {
        history.clear()
        historyStore.save(history)
        publishWidget()
    }

    /// Re-reads history from storage, for when something else cleared it.
    func reloadHistory() {
        history = historyStore.load()
    }

    private func recordRun(_ command: PaletteCommand) {
        history.record(rule: command.rule, at: now())
        historyStore.save(history)
        publishWidget()
    }

    /// Hands the widget its top rows. Cheap when nothing changed: the publisher skips identical snapshots.
    private func publishWidget() {
        widget.publish(WidgetPicker.snapshot(
            index: index, appName: appName, dryRun: dryRun, history: history, now: now()
        ))
    }

    func dismissFeedback() {
        feedback = nil
    }

    // MARK: - Internals

    private func apply(commands: [PaletteCommand], rev: String?, publish: Bool = true) {
        self.commands = commands
        index = CommandIndex(commands, embedding: SystemWordEmbedding.shared, links: ConceptLinks.appDefault)
        Task.detached(priority: .utility) { [index] in index.prepareSemantic() }
        commandCount = commands.count
        commandsRev = rev
        if publish { publishWidget() }
    }

    private func fail(with error: Error) {
        let mapped = error as? PaletteError ?? .invalidResponse
        switch mapped {
        case .offline:
            connection = .offline
            state = nil
        case .unauthorized:
            connection = .unauthorized
            state = nil
        default:
            break
        }
        show(mapped.message, isError: true)
    }

    private func show(_ text: String, isError: Bool) {
        feedback = Feedback(text: text, isError: isError)
    }
}

// MARK: - Dry run

extension PaletteModel {
    /// Builds the request the real path would send and keeps it for the sheet. Never touches the transport.
    fileprivate func stageDryRun(_ command: PaletteCommand?, phrase: String, api: PaletteAPI) -> Bool {
        do {
            let request = try api.injectRequest(phrase: phrase)
            dryRunOutcome = nil
            dryRunPreview = DryRunPreview(command: command, phrase: phrase, request: request)
        } catch {
            fail(with: error)
        }
        return false
    }

    /// Dry-run Confirm: sends the staged phrase with `dry_run=1`, so the feed reports what would run and runs nothing.
    func confirmDryRun() async {
        guard dryRun, let preview = dryRunPreview, let api, dryRunOutcome?.previewID != preview.id else { return }
        do {
            let result = try await api.inject(phrase: preview.phrase, dryRun: true)
            guard dryRunPreview?.id == preview.id else { return }
            connection = .online
            dryRunOutcome = DryRunOutcome(previewID: preview.id, wouldRun: result.rules, error: nil)
            if let command = preview.command { recordRun(command) }
            show("Dry run: nothing was executed", isError: false)
        } catch is CancellationError {
            return
        } catch {
            let mapped = error as? PaletteError ?? .invalidResponse
            if dryRunPreview?.id == preview.id {
                dryRunOutcome = DryRunOutcome(previewID: preview.id, wouldRun: [], error: mapped.message)
            }
            fail(with: error)
        }
    }

    func closeDryRun() {
        dryRunPreview = nil
        dryRunOutcome = nil
    }
}
