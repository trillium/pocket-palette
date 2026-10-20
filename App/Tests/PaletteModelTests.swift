import XCTest
@testable import PocketPalette

@MainActor
final class PaletteModelTests: XCTestCase {
    private let server = Fixture.server

    private func makeModel(
        _ transport: FakeTransport, server: String = Fixture.server, cache: FakeCache = FakeCache()
    ) -> (PaletteModel, FakeCache) {
        // Isolated defaults: the persisted `dryRunMode` on the simulator (left on by make ui-test) must not leak in.
        let suite = "palette-model-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults()
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let model = PaletteModel(
            settings: FakeSettingsStore(server), cache: cache, defaults: defaults,
            makeAPI: { PaletteAPI(baseURL: $0, transport: transport) }
        )
        return (model, cache)
    }

    func testWithoutServerURLTheModelIsUnconfiguredAndSendsNothing() async {
        let transport = FakeTransport()
        let (model, _) = makeModel(transport, server: "")
        XCTAssertEqual(model.connection, .unconfigured)
        let polled = await model.pollOnce()
        XCTAssertFalse(polled)
        let ran = await model.execute(Fixture.command("playback now"))
        XCTAssertFalse(ran)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(model.feedback?.isError, true)
    }

    func testPollLoadsStateThenCommandsAndCachesThem() async {
        let transport = FakeTransport([.http(200, Fixture.stateJSON, [:]), .http(200, Fixture.commandsJSON, [:])])
        let (model, cache) = makeModel(transport)
        let ok = await model.pollOnce()
        XCTAssertTrue(ok)
        XCTAssertEqual(model.connection, .online)
        XCTAssertFalse(model.isStale)
        XCTAssertEqual(model.state?.host, "macbookpro")
        XCTAssertEqual(model.commandCount, 3)
        XCTAssertEqual(cache.saved?.rev, "9a2e")
        XCTAssertEqual(cache.saved?.server, server)
        XCTAssertEqual(transport.requests.map { $0.url?.path }, ["/state", "/commands"])
    }

    func testUnchangedRevSkipsTheCommandFetch() async {
        let transport = FakeTransport([
            .http(200, Fixture.stateJSON, [:]), .http(200, Fixture.commandsJSON, [:]), .http(200, Fixture.stateJSON, [:])
        ])
        let (model, _) = makeModel(transport)
        await model.pollOnce()
        await model.pollOnce()
        XCTAssertEqual(transport.requests.count, 3, "second poll is /state only: commands_rev matches")
    }

    func testRevChangeRefetchesWithIfNoneMatchAnd304KeepsList() async {
        let changed = Fixture.stateJSON.replacingOccurrences(of: #""commands_rev":"9a2e""#, with: #""commands_rev":"zzzz""#)
        let transport = FakeTransport([
            .http(200, Fixture.stateJSON, [:]), .http(200, Fixture.commandsJSON, [:]),
            .http(200, changed, [:]), .http(304, "", [:])
        ])
        let (model, _) = makeModel(transport)
        await model.pollOnce()
        await model.pollOnce()
        XCTAssertEqual(transport.requests.last?.url?.query, "rev=9a2e")
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "\"9a2e\"")
        XCTAssertEqual(model.commandCount, 3)
    }

    func testOfflineKeepsCachedListGreyedAndSaysMacOffline() async {
        let cached = CachedCommands(server: server, rev: "9a2e", commands: [Fixture.command("playback now")])
        let transport = FakeTransport([.failure(URLError(.cannotConnectToHost))])
        let (model, _) = makeModel(transport, cache: FakeCache(cached))
        XCTAssertEqual(model.results.map(\.command.rule), ["playback now"], "cache is shown before any network call")
        let ok = await model.pollOnce()
        XCTAssertFalse(ok)
        XCTAssertEqual(model.connection, .offline)
        XCTAssertTrue(model.isStale)
        XCTAssertNil(model.state)
        XCTAssertEqual(model.feedback?.text, "Mac offline")
        XCTAssertEqual(model.results.count, 1, "list stays on screen")
    }

    func testUnauthorizedIsDistinctFromOffline() async {
        let transport = FakeTransport([.http(401, Fixture.error("unauthorized"), [:])])
        let (model, _) = makeModel(transport)
        await model.pollOnce()
        XCTAssertEqual(model.connection, .unauthorized)
        XCTAssertEqual(model.feedback?.text, PaletteError.unauthorized.message)
    }

    func testRecoversToOnlineAfterOffline() async {
        let transport = FakeTransport([
            .failure(URLError(.timedOut)), .http(200, Fixture.stateJSON, [:]), .http(200, Fixture.commandsJSON, [:])
        ])
        let (model, _) = makeModel(transport)
        await model.pollOnce()
        XCTAssertEqual(model.connection, .offline)
        await model.pollOnce()
        XCTAssertEqual(model.connection, .online)
        XCTAssertEqual(model.commandCount, 3)
    }

    func testSearchOverLoadedCommands() async {
        let transport = FakeTransport([.http(200, Fixture.stateJSON, [:]), .http(200, Fixture.commandsJSON, [:])])
        let (model, _) = makeModel(transport)
        await model.pollOnce()
        model.query = "play"
        XCTAssertEqual(model.results.map(\.command.rule), ["playback now"])
    }

    func testRowTapInjectsTheSpokenPhraseAndShowsWhatRan() async throws {
        let transport = FakeTransport([.http(200, Fixture.injectOK, [:])])
        let (model, _) = makeModel(transport)
        let command = PaletteCommand(id: "b41c9e07", rule: "tab (open | new)")
        let ran = await model.execute(command)
        XCTAssertTrue(ran)
        XCTAssertEqual(model.feedback?.text, "Ran \u{201C}playback now\u{201D}")
        XCTAssertEqual(model.feedback?.isError, false)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "\(server)/inject")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["phrase": "tab open"])
    }

    func testRunFieldInjectsTrimmedFreeTextThroughTheSamePath() async throws {
        let reply = #"{"ok":true,"phrase":"focus finder","ran":[{"rule":"focus <app>","path":"w.voice"}]}"#
        let transport = FakeTransport([.http(200, reply, [:])])
        let (model, _) = makeModel(transport)
        let ran = await model.run("  focus finder \n")
        XCTAssertTrue(ran)
        XCTAssertEqual(model.feedback?.text, "Ran \u{201C}focus <app>\u{201D}")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/inject")
        XCTAssertNil(request.url?.query, "a real run carries no dry_run flag")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["phrase": "focus finder"])
        XCTAssertTrue(model.history.isEmpty, "free text is not a listed command")
    }

    func testRunFieldIgnoresBlankText() async {
        let transport = FakeTransport()
        let (model, _) = makeModel(transport)
        let ran = await model.run("   ")
        XCTAssertFalse(ran)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(model.feedback)
    }

    func testRunWithoutTailnetIdentityIsExplained() async {
        let (model, _) = makeModel(FakeTransport([.http(403, Fixture.error("tailnet_identity_required"), [:])]))
        let ran = await model.run("focus finder")
        XCTAssertFalse(ran)
        XCTAssertEqual(model.feedback?.text, "Refused: use the feed's tailscale serve address")
        XCTAssertEqual(model.feedback?.isError, true)
    }

    func testExecuteFailuresAreExplained() async {
        let cases: [(FakeTransport.Reply, String)] = [
            (.http(422, Fixture.error("no_match"), [:]), "No matching command"),
            (.http(429, Fixture.error("rate_limited"), ["Retry-After": "1"]), "Rate limited (5/s): retry in 1s"),
            (.http(401, Fixture.error("unauthorized"), [:]), PaletteError.unauthorized.message),
            (.failure(URLError(.notConnectedToInternet)), "Mac offline")
        ]
        for (reply, text) in cases {
            let (model, _) = makeModel(FakeTransport([reply]))
            let ran = await model.execute(Fixture.command("playback now"))
            XCTAssertFalse(ran)
            XCTAssertEqual(model.feedback?.text, text)
            XCTAssertEqual(model.feedback?.isError, true)
        }
    }

    func testTemplateRuleNeedsAnExplicitPhrase() async {
        let transport = FakeTransport()
        let (model, _) = makeModel(transport)
        let ran = await model.execute(Fixture.command("say <text>"))
        XCTAssertFalse(ran)
        XCTAssertTrue(transport.requests.isEmpty)
    }
}

@MainActor
final class SettingsModelTests: XCTestCase {
    func testSaveStoresAPlainHTTPURL() {
        let settings = FakeSettingsStore()
        let model = SettingsModel(settings: settings)
        model.baseURLText = "http://mini0.tail0.ts.net:7399"
        XCTAssertTrue(model.save())
        XCTAssertNil(model.message)
        XCTAssertEqual(settings.load().baseURLText, "http://mini0.tail0.ts.net:7399")
    }

    func testFormStartsFromTheStoredURL() {
        XCTAssertEqual(SettingsModel(settings: FakeSettingsStore()).baseURLText, Fixture.server)
    }

    func testInvalidURLIsRejectedAndNothingIsSaved() {
        let settings = FakeSettingsStore()
        let model = SettingsModel(settings: settings)
        model.baseURLText = "mini0.tail0.ts.net:7399"
        XCTAssertFalse(model.canSave)
        XCTAssertFalse(model.save())
        XCTAssertEqual(model.message, "Enter an http:// or https:// URL")
        XCTAssertEqual(settings.load().baseURLText, Fixture.server)
    }
}
