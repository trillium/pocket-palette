import XCTest
@testable import PocketPalette

/// Mutable clock for the model; tests move it by hand so nothing depends on the wall clock.
final class FixedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

final class ExecuteHistoryTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600

    func testNeverRunHasNoBoost() {
        XCTAssertEqual(ExecuteHistory().boost(for: "tab open", now: epoch), 0)
    }

    func testJustRunGetsFullRecencyPlusOneRunOfFrequency() {
        var history = ExecuteHistory()
        history.record(rule: "tab open", at: epoch)
        XCTAssertEqual(history.boost(for: "tab open", now: epoch), RankingBoost.maxRecency + RankingBoost.frequencyStep, accuracy: 1e-9)
    }

    func testRecencyHalvesEveryHalfLifeWhileFrequencyStays() {
        var history = ExecuteHistory()
        history.record(rule: "tab open", at: epoch)
        let fresh = history.boost(for: "tab open", now: epoch)
        let later = history.boost(for: "tab open", now: epoch.addingTimeInterval(RankingBoost.halfLife))
        XCTAssertEqual(fresh - later, RankingBoost.maxRecency / 2, accuracy: 1e-9)
        let muchLater = history.boost(for: "tab open", now: epoch.addingTimeInterval(365 * day))
        XCTAssertEqual(muchLater, RankingBoost.frequencyStep, accuracy: 0.01, "old runs keep only the frequency part")
    }

    func testFrequentBeatsOnceAtTheSameTime() {
        var history = ExecuteHistory()
        history.record(rule: "once", at: epoch)
        for _ in 0..<4 { history.record(rule: "often", at: epoch) }
        XCTAssertGreaterThan(history.boost(for: "often", now: epoch), history.boost(for: "once", now: epoch))
    }

    func testMoreRecentBeatsOlderAtEqualCount() {
        var history = ExecuteHistory()
        history.record(rule: "old", at: epoch)
        history.record(rule: "new", at: epoch.addingTimeInterval(5 * day))
        let now = epoch.addingTimeInterval(5 * day)
        XCTAssertGreaterThan(history.boost(for: "new", now: now), history.boost(for: "old", now: now))
    }

    func testBoostIsBoundedNoMatterHowOftenOrRecentlyRun() {
        var history = ExecuteHistory()
        for _ in 0..<10_000 { history.record(rule: "spam", at: epoch) }
        XCTAssertLessThanOrEqual(history.boost(for: "spam", now: epoch), RankingBoost.maxHistory + 1e-9)
    }

    func testAClockBehindTheLastRunDoesNotInflateTheBoost() {
        var history = ExecuteHistory()
        history.record(rule: "x", at: epoch)
        XCTAssertLessThanOrEqual(history.boost(for: "x", now: epoch.addingTimeInterval(-day)), RankingBoost.maxHistory + 1e-9)
    }

    func testEntriesAreCappedKeepingTheMostRecent() {
        var history = ExecuteHistory()
        for index in 0..<(ExecuteHistory.maxEntries + 20) {
            history.record(rule: "rule \(index)", at: epoch.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(history.count, ExecuteHistory.maxEntries)
        XCTAssertNil(history.entry(for: "rule 0"))
        XCTAssertNotNil(history.entry(for: "rule \(ExecuteHistory.maxEntries + 19)"))
    }

    func testClearEmptiesIt() {
        var history = ExecuteHistory()
        history.record(rule: "x", at: epoch)
        history.clear()
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(history.boost(for: "x", now: epoch), 0)
    }

    func testStoreRoundTripsInIsolatedDefaultsAndClearRemovesTheKey() throws {
        let name = "history-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let store = UserDefaultsHistoryStore(defaults: defaults)
        XCTAssertTrue(store.load().isEmpty)
        var history = ExecuteHistory()
        history.record(rule: "tab open", at: epoch)
        history.record(rule: "tab open", at: epoch)
        store.save(history)
        XCTAssertEqual(store.load(), history)
        history.clear()
        store.save(history)
        XCTAssertNil(defaults.data(forKey: UserDefaultsHistoryStore.key))
    }

    func testStoredHistoryHoldsOnlyRuleTextCountsAndDates() throws {
        let name = "history-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        var history = ExecuteHistory()
        history.record(rule: "tab open", at: epoch)
        UserDefaultsHistoryStore(defaults: defaults).save(history)
        let data = try XCTUnwrap(defaults.data(forKey: UserDefaultsHistoryStore.key))
        let raw = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertFalse(raw.contains(Fixture.server))
        XCTAssertFalse(raw.lowercased().contains("bearer"))
    }

    func testHistoryReordersEqualTextMatchesInSearch() {
        var history = ExecuteHistory()
        history.record(rule: "tab omega", at: epoch)
        let index = CommandIndex(["tab alpha", "tab omega"].map { Fixture.command($0) })
        let plain = index.search("tab").map(\.command.rule)
        let boosted = index.search("tab", options: SearchOptions(history: history, now: epoch))
        XCTAssertEqual(plain, ["tab alpha", "tab omega"])
        XCTAssertEqual(boosted.map(\.command.rule), ["tab omega", "tab alpha"])
        XCTAssertGreaterThan(boosted[0].historyBoost, 0)
        XCTAssertEqual(boosted[0].contextBoost, 0)
    }

    func testHistoryDoesNotOverrideAClearlyBetterTextMatch() {
        var history = ExecuteHistory()
        for _ in 0..<20 { history.record(rule: "tabs closed", at: epoch) }
        let index = CommandIndex(["tab open", "tabs closed"].map { Fixture.command($0) })
        let hits = index.search("tab", options: SearchOptions(history: history, now: epoch))
        XCTAssertEqual(hits.map(\.command.rule), ["tab open", "tabs closed"])
    }

    func testEmptyQueryListsRecentlyRunFirst() {
        var history = ExecuteHistory()
        history.record(rule: "c", at: epoch)
        let index = CommandIndex(["a", "b", "c"].map { Fixture.command($0) })
        XCTAssertEqual(index.search("", options: SearchOptions(history: history, now: epoch)).map(\.command.rule), ["c", "a", "b"])
    }
}

@MainActor
final class ModelHistoryTests: XCTestCase {
    private func make(
        _ transport: FakeTransport, clock: FixedClock = FixedClock(), defaults: UserDefaults? = nil
    ) throws -> (PaletteModel, UserDefaults) {
        let name = "model-history-tests-\(UUID().uuidString)"
        let store = try defaults ?? XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let model = PaletteModel(
            settings: FakeSettingsStore(), cache: FakeCache(), defaults: store,
            now: { clock.now },
            makeAPI: { PaletteAPI(baseURL: $0, transport: transport) }
        )
        return (model, store)
    }

    private let command = Fixture.command("playback now")

    func testSuccessfulExecuteIsRecordedAtTheClockTime() async throws {
        let clock = FixedClock()
        let (model, _) = try make(FakeTransport([.http(200, Fixture.injectOK, [:])]), clock: clock)
        let started = clock.now
        await model.execute(command)
        XCTAssertEqual(model.history.entry(for: "playback now")?.count, 1)
        XCTAssertEqual(model.history.entry(for: "playback now")?.last, started)
    }

    func testFailedExecuteIsNotRecorded() async throws {
        let (model, _) = try make(FakeTransport([.http(422, Fixture.error("no_match"), [:])]))
        await model.execute(command)
        XCTAssertTrue(model.history.isEmpty)
    }

    func testDryRunTapAloneIsNotRecordedButConfirmIsAndOnlyOnce() async throws {
        let transport = FakeTransport([.http(200, Fixture.injectDryRun, [:]), .http(200, Fixture.injectDryRun, [:])])
        let (model, _) = try make(transport)
        model.dryRun = true
        await model.execute(command)
        XCTAssertTrue(model.history.isEmpty, "staging is not a run")
        await model.confirmDryRun()
        await model.confirmDryRun()
        XCTAssertEqual(model.history.entry(for: "playback now")?.count, 1)
        XCTAssertEqual(transport.requests.map { $0.url?.query }, ["dry_run=1"], "one dry_run probe, nothing run")
    }

    func testHistoryPersistsAcrossRelaunchAndClearForgetsIt() async throws {
        let (model, defaults) = try make(FakeTransport([.http(200, Fixture.injectOK, [:])]))
        await model.execute(command)
        let (relaunched, _) = try make(FakeTransport(), defaults: defaults)
        XCTAssertEqual(relaunched.history.count, 1)
        relaunched.clearHistory()
        XCTAssertTrue(relaunched.history.isEmpty)
        let (again, _) = try make(FakeTransport(), defaults: defaults)
        XCTAssertTrue(again.history.isEmpty)
    }

    func testResultsRankRunCommandsFirstAndDecayWithTheClock() async throws {
        let clock = FixedClock()
        let transport = FakeTransport([
            .http(200, Fixture.stateJSON, [:]), .http(200, Fixture.commandsJSON, [:]), .http(200, Fixture.injectOK, [:])
        ])
        let (model, _) = try make(transport, clock: clock)
        await model.pollOnce()
        XCTAssertEqual(model.results.first?.command.rule, "playback now", "server order with an empty history")
        let tab = try XCTUnwrap(model.results.first { $0.command.rule == "tab (open|new)" }).command
        await model.execute(tab, phrase: "tab open")
        XCTAssertEqual(model.results.first?.command.rule, "tab (open|new)")
        XCTAssertGreaterThan(model.results.first?.historyBoost ?? 0, RankingBoost.frequencyStep)
        clock.advance(400 * 24 * 3600)
        XCTAssertEqual(model.results.first?.historyBoost ?? 0, RankingBoost.frequencyStep, accuracy: 0.01)
    }

    func testContextBoostDefaultsOnPersistsAndAppOnlyIsPerSession() throws {
        let (model, defaults) = try make(FakeTransport())
        XCTAssertTrue(model.contextBoost)
        XCTAssertFalse(model.thisAppOnly)
        model.contextBoost = false
        model.thisAppOnly = true
        let (relaunched, _) = try make(FakeTransport(), defaults: defaults)
        XCTAssertFalse(relaunched.contextBoost)
        XCTAssertFalse(relaunched.thisAppOnly)
        XCTAssertEqual(PaletteModel.contextBoostKey, "contextBoost")
    }

    func testModelFiltersAndBoostsByScopeFromTheFeed() async throws {
        let json = """
        {"commands_rev":"r1","count":3,"commands":[
         {"id":"1","rule":"tab alpha","scope":"global","apps":[],"tags":[]},
         {"id":"2","rule":"tab beta","scope":"tag","apps":[],"tags":["browser"]},
         {"id":"3","rule":"tab gamma","scope":"app","apps":["WezTerm"],"tags":[]}]}
        """
        let transport = FakeTransport([.http(200, Fixture.stateJSON, [:]), .http(200, json, [:])])
        let (model, _) = try make(transport)
        await model.pollOnce()
        XCTAssertEqual(model.appName, "WezTerm")
        model.query = "tab"
        XCTAssertEqual(model.results.map(\.command.rule), ["tab gamma", "tab beta", "tab alpha"])
        model.contextBoost = false
        XCTAssertEqual(model.results.map(\.command.rule), ["tab beta", "tab alpha", "tab gamma"])
        model.thisAppOnly = true
        XCTAssertEqual(model.results.map(\.command.rule), ["tab gamma"])
    }
}
