import XCTest
@testable import PocketPalette

/// Siri/Spotlight path and the offline-cache behaviour. Every transport here is a fake: no real /execute.
final class IntentRunnerTests: XCTestCase {
    private let server = Fixture.server

    private func cached() -> FakeCache {
        let list = [Fixture.command("playback now", id: "b41c9e07"), Fixture.command("say <text>", id: "e19b3f10")]
        return FakeCache(CachedCommands(server: server, rev: "9a2e", commands: list))
    }

    private func makeRunner(_ transport: FakeTransport, dryRun: Bool, server: String = Fixture.server) -> IntentRunner {
        let suite = "intent-runner-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults()
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(dryRun, forKey: IntentRunner.dryRunKey)
        return IntentRunner(
            settings: FakeSettingsStore(server), cache: cached(), defaults: defaults,
            makeAPI: { PaletteAPI(baseURL: $0, transport: transport) }
        )
    }

    func testSearchReadsTheCacheOnly() {
        let transport = FakeTransport()
        let runner = makeRunner(transport, dryRun: false)
        XCTAssertEqual(runner.search("play").map(\.id), ["b41c9e07"])
        XCTAssertEqual(runner.commands(ids: ["e19b3f10"]).map(\.rule), ["say <text>"])
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRunSendsIdAndSpokenPhrase() async throws {
        let transport = FakeTransport([.http(200, Fixture.executeOK, [:])])
        let outcome = await makeRunner(transport, dryRun: false).run(id: "b41c9e07")
        XCTAssertEqual(outcome, .ran(rule: "playback now"))
        let body = try XCTUnwrap(transport.requests.first?.httpBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["phrase": "playback now", "id": "b41c9e07"])
    }

    func testDryRunNeverReachesTheTransport() async {
        let transport = FakeTransport([.http(200, Fixture.executeOK, [:])])
        let outcome = await makeRunner(transport, dryRun: true).run(id: "b41c9e07")
        XCTAssertEqual(outcome, .dryRun(rule: "playback now"))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRunFailuresAreSentencesNotCrashes() async {
        let transport = FakeTransport()
        let unconfigured = await makeRunner(transport, dryRun: false, server: "").run(id: "b41c9e07")
        XCTAssertEqual(unconfigured, .failed(PaletteError.notConfigured.message))
        let unknown = await makeRunner(transport, dryRun: false).run(id: "nope")
        XCTAssertEqual(unknown, .failed("Command list is out of date"))
        let template = await makeRunner(transport, dryRun: false).run(id: "e19b3f10")
        XCTAssertEqual(template, .failed("This command needs a phrase: run it from the app"))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testOfflineRunReportsMacOfflineAndDoesNotQueue() async {
        let transport = FakeTransport([.failure(URLError(.notConnectedToInternet))])
        let runner = makeRunner(transport, dryRun: false)
        let outcome = await runner.run(id: "b41c9e07")
        XCTAssertEqual(outcome, .failed("Mac offline"))
        XCTAssertEqual(transport.requests.count, 1, "one attempt, nothing queued for retry")
        XCTAssertEqual(runner.search("play").count, 1, "cache still searchable")
    }
}

/// Existing design: when the feed is unreachable the cached list stays on screen, greyed, and a run is attempted
/// and fails with "Mac offline" (no queue). Failing transport injected; nothing real is sent.
@MainActor
final class OfflineCacheBehaviourTests: XCTestCase {
    private func makeModel(_ transport: FakeTransport) -> PaletteModel {
        let suite = "offline-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults()
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let cache = FakeCache(CachedCommands(
            server: Fixture.server, rev: "9a2e",
            commands: [Fixture.command("playback now", id: "b41c9e07"), Fixture.command("tab open", id: "5d0a77c2")]
        ))
        return PaletteModel(
            settings: FakeSettingsStore(), cache: cache, defaults: defaults,
            makeAPI: { PaletteAPI(baseURL: $0, transport: transport) }
        )
    }

    func testUnreachableFeedServesCacheShowsOfflineAndRunFails() async {
        let transport = FakeTransport([.failure(URLError(.cannotConnectToHost)), .failure(URLError(.cannotConnectToHost))])
        let model = makeModel(transport)
        XCTAssertEqual(model.commandCount, 2, "cache loaded before any network call")
        let healthy = await model.pollOnce()
        XCTAssertFalse(healthy)
        XCTAssertEqual(model.connection, .offline)
        XCTAssertTrue(model.isStale, "rows greyed")
        XCTAssertEqual(model.feedback?.text, "Mac offline")
        model.query = "tab"
        XCTAssertEqual(model.results.map(\.command.rule), ["tab open"], "search still works on cached list")
        let ran = await model.execute(Fixture.command("playback now", id: "b41c9e07"))
        XCTAssertFalse(ran)
        XCTAssertEqual(model.feedback?.text, "Mac offline")
        XCTAssertEqual(model.connection, .offline)
        XCTAssertEqual(model.commandCount, 2, "failed refresh never clears the cache")
    }
}
