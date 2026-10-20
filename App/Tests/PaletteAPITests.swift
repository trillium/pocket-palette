import XCTest
@testable import PocketPalette

final class PaletteAPITests: XCTestCase {
    private let base = URL(string: "http://macbook.example.ts.net:7399")!

    private func makeAPI(_ transport: FakeTransport) -> PaletteAPI {
        PaletteAPI(baseURL: base, transport: transport)
    }

    private func assertThrows<T>(_ expected: PaletteError, _ work: () async throws -> T, line: UInt = #line) async {
        do {
            _ = try await work()
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? PaletteError, expected, line: line)
        }
    }

    // MARK: - Requests

    func testStateSendsNoAuthorizationAndDecodes() async throws {
        let transport = FakeTransport([.http(200, Fixture.stateJSON, [:])])
        let state = try await makeAPI(transport).state()
        XCTAssertEqual(state.host, "macbookpro")
        XCTAssertEqual(state.app.name, "WezTerm")
        XCTAssertEqual(state.window.fileExt, "")
        XCTAssertEqual(state.commandsRev, "9a2e")
        XCTAssertTrue(state.inCommandMode)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://macbook.example.ts.net:7399/state")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testStateWithoutCommandModeIsReported() async throws {
        let body = Fixture.stateJSON.replacingOccurrences(of: #"["all","command"]"#, with: #"["all","sleep"]"#)
        let state = try await makeAPI(FakeTransport([.http(200, body, [:])])).state()
        XCTAssertFalse(state.inCommandMode)
    }

    // MARK: - ETag / rev caching

    func testCommandsFirstFetchHasNoRevAndDecodesEveryField() async throws {
        let transport = FakeTransport([.http(200, Fixture.commandsJSON, ["ETag": "\"9a2e\""])])
        let fetch = try await makeAPI(transport).commands(knownRev: nil)
        guard case .updated(let list) = fetch else { return XCTFail("expected updated") }
        XCTAssertEqual(list.commandsRev, "9a2e")
        XCTAssertEqual(list.commands.count, 3)
        XCTAssertEqual(list.commands[1].shadowed, 1)
        XCTAssertEqual(list.commands[2].kind, .capture)
        XCTAssertEqual(list.commands[2].slots, [.init(name: "text", type: "capture", n: nil, open: true)])
        XCTAssertEqual(list.commands[0].contextName, "most_recent_command_playback.voice")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testKnownRevIsSentAsQueryAndIfNoneMatch() async throws {
        let transport = FakeTransport([.http(304, "", ["ETag": "\"9a2e\""])])
        _ = try await makeAPI(transport).commands(knownRev: "9a2e")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.query, "rev=9a2e")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"9a2e\"")
    }

    func testNotModifiedYieldsNotModified() async throws {
        let fetch = try await makeAPI(FakeTransport([.http(304, "", [:])])).commands(knownRev: "9a2e")
        XCTAssertEqual(fetch, .notModified)
    }

    func testChangedRevReturnsNewList() async throws {
        let body = Fixture.commandsJSON.replacingOccurrences(of: "9a2e", with: "ffff")
        let fetch = try await makeAPI(FakeTransport([.http(200, body, [:])])).commands(knownRev: "9a2e")
        guard case .updated(let list) = fetch else { return XCTFail("expected updated") }
        XCTAssertEqual(list.commandsRev, "ffff")
    }

    // MARK: - Failures: 401, offline, rate limit, size cap

    func testUnauthorized() async {
        let api = makeAPI(FakeTransport([.http(401, Fixture.error("unauthorized"), ["WWW-Authenticate": "Bearer"])]))
        await assertThrows(.unauthorized) { try await api.state() }
    }

    func testConnectionFailuresMeanOffline() async {
        for code: URLError.Code in [.cannotConnectToHost, .notConnectedToInternet, .timedOut, .networkConnectionLost, .dnsLookupFailed] {
            let api = makeAPI(FakeTransport([.failure(URLError(code))]))
            await assertThrows(.offline) { try await api.state() }
        }
    }

    func testGatewayErrorsFromTailscaleServeMeanOffline() async {
        for status in [502, 503, 504] {
            let api = makeAPI(FakeTransport([.http(status, "Bad Gateway", [:])]))
            await assertThrows(.offline) { try await api.commands(knownRev: nil) }
        }
    }

    func testOfflineMessageIsMacOffline() {
        XCTAssertEqual(PaletteError.offline.message, "Mac offline")
    }

    func testExecuteTimeoutFromFeedIsNotOffline() async {
        let api = makeAPI(FakeTransport([.http(504, Fixture.error("execute_timeout"), [:])]))
        await assertThrows(.rejected(status: 504, code: "execute_timeout", wouldRun: nil)) {
            try await api.execute(phrase: "playback now", id: nil)
        }
    }

    func testRateLimitedCarriesRetryAfter() async {
        let api = makeAPI(FakeTransport([.http(429, Fixture.error("rate_limited"), ["Retry-After": "1"])]))
        await assertThrows(.rateLimited(retryAfter: 1)) { try await api.execute(phrase: "x", id: nil) }
    }

    func testServerSideBodyCapIsMapped() async {
        let api = makeAPI(FakeTransport([.http(413, Fixture.error("body_too_large"), [:])]))
        await assertThrows(.bodyTooLarge) { try await api.execute(phrase: "x", id: nil) }
    }

    func testOversizedBodyIsRefusedBeforeSending() async {
        let transport = FakeTransport([.http(200, Fixture.executeOK, [:])])
        let api = makeAPI(transport)
        await assertThrows(.bodyTooLarge) { try await api.execute(phrase: String(repeating: "a", count: 5000), id: nil) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testGarbageBodyIsInvalidResponse() async {
        let api = makeAPI(FakeTransport([.http(200, "<html>", [:])]))
        await assertThrows(.invalidResponse) { try await api.state() }
    }

    // MARK: - Execute

    func testExecutePostsJSONBodyAndDecodesResult() async throws {
        let transport = FakeTransport([.http(200, Fixture.executeOK, [:])])
        let result = try await makeAPI(transport).execute(phrase: "playback now", id: "b41c9e07")
        XCTAssertEqual(result.matchedRule, "playback now")
        XCTAssertTrue(result.ok)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/execute")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["phrase": "playback now", "id": "b41c9e07"])
        XCTAssertLessThanOrEqual(body.count, PaletteAPI.maxBodyBytes)
    }

    func testInjectPostsThePhraseAndDecodesWhatRanOrWouldRun() async throws {
        let transport = FakeTransport([.http(200, Fixture.injectOK, [:]), .http(200, Fixture.injectDryRun, [:])])
        let api = makeAPI(transport)
        let ran = try await api.inject(phrase: "playback now")
        XCTAssertEqual(ran.rules, ["playback now"])
        let checked = try await api.inject(phrase: "tab open", dryRun: true)
        XCTAssertEqual(checked.dryRun, true)
        XCTAssertEqual(checked.rules, ["tab (open | new)"])
        let (real, probe) = (transport.requests[0], transport.requests[1])
        XCTAssertEqual(real.httpMethod, "POST")
        XCTAssertEqual(real.url?.path, "/inject")
        XCTAssertNil(real.url?.query)
        XCTAssertEqual(real.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(real.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(String(data: try XCTUnwrap(real.httpBody), encoding: .utf8), #"{"phrase":"playback now"}"#)
        XCTAssertEqual(probe.url?.query, "dry_run=1")
    }

    func testDryRunAndForceAreQueryFlags() async throws {
        let transport = FakeTransport([.http(200, #"{"ok":true,"dry_run":true,"matched_rule":"r","path":"p"}"#, [:])])
        let result = try await makeAPI(transport).execute(phrase: "show debug modes", id: nil, dryRun: true, force: true)
        XCTAssertEqual(result.dryRun, true)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.query, "dry_run=1&force=1")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["phrase": "show debug modes"])
    }

    func testRuleMismatchSurfacesWhatWouldRun() async {
        let body = Fixture.error("rule_mismatch", extra: #","would_run":{"rule":"other rule","path":"p.voice"}"#)
        let api = makeAPI(FakeTransport([.http(409, body, [:])]))
        await assertThrows(.rejected(status: 409, code: "rule_mismatch", wouldRun: "other rule")) {
            try await api.execute(phrase: "x", id: "1")
        }
    }

    func testRejectionMessagesAreHumanReadable() {
        XCTAssertEqual(PaletteError.rejected(status: 422, code: "no_match", wouldRun: nil).message, "No matching command")
        let notInMode = PaletteError.rejected(status: 423, code: "not_in_command_mode", wouldRun: nil)
        XCTAssertEqual(notInMode.message, "The engine is not in command mode")
        let denied = PaletteError.rejected(status: 403, code: "denied", wouldRun: nil)
        XCTAssertEqual(denied.message, "Blocked: the phone may not run this command")
        XCTAssertEqual(PaletteError.rejected(status: 418, code: "teapot", wouldRun: nil).message, "Rejected (teapot)")
        XCTAssertEqual(PaletteError.rateLimited(retryAfter: 2).message, "Rate limited (5/s): retry in 2s")
    }
}
