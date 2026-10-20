import XCTest
@testable import PocketPalette

@MainActor
final class DryRunTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "dryrun-tests-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return store
    }

    private func makeModel(_ transport: FakeTransport, defaults: UserDefaults) -> PaletteModel {
        PaletteModel(
            settings: FakeSettingsStore(), cache: FakeCache(), defaults: defaults,
            makeAPI: { PaletteAPI(baseURL: $0, transport: transport) }
        )
    }

    private let command = PaletteCommand(id: "b41c9e07", rule: "tab (open | new)")

    func testDryRunIsOffByDefault() throws {
        XCTAssertFalse(makeModel(FakeTransport(), defaults: try defaults()).dryRun)
    }

    func testDryRunSurvivesRelaunchAndHonoursTheLaunchArgumentKey() throws {
        let store = try defaults()
        makeModel(FakeTransport(), defaults: store).dryRun = true
        XCTAssertTrue(makeModel(FakeTransport(), defaults: store).dryRun)
        store.set(false, forKey: PaletteModel.dryRunKey)
        XCTAssertFalse(makeModel(FakeTransport(), defaults: store).dryRun)
        XCTAssertEqual(PaletteModel.dryRunKey, "dryRunMode", "UI tests launch with -dryRunMode YES")
    }

    func testTapInDryRunSendsNothingAndStagesTheExactRequest() async throws {
        let transport = FakeTransport([.http(200, Fixture.injectOK, [:])])
        let model = makeModel(transport, defaults: try defaults())
        model.dryRun = true
        let ran = await model.execute(command)
        XCTAssertFalse(ran)
        XCTAssertTrue(transport.requests.isEmpty, "dry run must not reach the transport")
        let preview = try XCTUnwrap(model.dryRunPreview)
        XCTAssertEqual(preview.method, "POST")
        XCTAssertEqual(preview.url, "\(Fixture.server)/inject")
        XCTAssertEqual(preview.phrase, "tab open")
        let body = try JSONSerialization.jsonObject(with: Data(preview.body.utf8)) as? [String: String]
        XCTAssertEqual(body, ["phrase": "tab open"])
        XCTAssertNil(model.dryRunOutcome, "nothing is confirmed until Confirm")
    }

    func testPreviewIsByteForByteTheRealRequest() async throws {
        let transport = FakeTransport([.http(200, Fixture.injectOK, [:])])
        let model = makeModel(transport, defaults: try defaults())
        await model.execute(command)
        let real = try XCTUnwrap(transport.requests.first)
        model.dryRun = true
        await model.execute(command)
        let preview = try XCTUnwrap(model.dryRunPreview)
        XCTAssertEqual(preview.url, real.url?.absoluteString)
        XCTAssertEqual(preview.body, String(data: try XCTUnwrap(real.httpBody), encoding: .utf8))
        let realHeaders = Set((real.allHTTPHeaderFields ?? [:]).keys)
        XCTAssertEqual(Set(preview.headers.map(\.name)), realHeaders)
        XCTAssertEqual(transport.requests.count, 1, "only the first, non-dry execute was sent")
    }

    func testNeitherPreviewNorRequestCarriesAuthorization() async throws {
        let transport = FakeTransport([.http(200, Fixture.injectDryRun, [:])])
        let model = makeModel(transport, defaults: try defaults())
        model.dryRun = true
        await model.execute(command)
        let preview = try XCTUnwrap(model.dryRunPreview)
        await model.confirmDryRun()
        XCTAssertFalse(preview.headers.contains { $0.name.lowercased() == "authorization" })
        XCTAssertFalse(preview.requestText.lowercased().contains("bearer"))
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testConfirmAsksTheFeedWithDryRunAndShowsWhatWouldRun() async throws {
        let transport = FakeTransport([.http(200, Fixture.injectDryRun, [:])])
        let model = makeModel(transport, defaults: try defaults())
        model.dryRun = true
        await model.execute(command)
        XCTAssertTrue(transport.requests.isEmpty, "staging sends nothing")
        await model.confirmDryRun()
        let outcome = try XCTUnwrap(model.dryRunOutcome)
        XCTAssertEqual(outcome.previewID, model.dryRunPreview?.id)
        XCTAssertEqual(outcome.wouldRun, ["tab (open | new)"])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.text, "tab (open | new)")
        XCTAssertEqual(model.feedback?.text, "Dry run: nothing was executed")
        let probe = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(probe.url?.absoluteString, "\(Fixture.server)/inject?dry_run=1", "Confirm only ever sends the dry_run probe")
        await model.confirmDryRun()
        XCTAssertEqual(transport.requests.count, 1, "a second Confirm does not ask again")
        model.closeDryRun()
        XCTAssertNil(model.dryRunPreview)
        XCTAssertNil(model.dryRunOutcome)
    }

    func testConfirmShowsTheFeedsRefusal() async throws {
        let transport = FakeTransport([.http(422, Fixture.error("no_match"), [:])])
        let model = makeModel(transport, defaults: try defaults())
        model.dryRun = true
        await model.run("nothing like this")
        XCTAssertNil(model.dryRunPreview?.command, "free text has no row")
        await model.confirmDryRun()
        XCTAssertEqual(model.dryRunOutcome?.wouldRun, [])
        XCTAssertEqual(model.dryRunOutcome?.error, "No matching command")
        XCTAssertEqual(model.feedback?.isError, true)
        XCTAssertTrue(model.history.isEmpty)
    }

    func testRunFieldInDryRunStagesTheInjectRequest() async throws {
        let transport = FakeTransport()
        let model = makeModel(transport, defaults: try defaults())
        model.dryRun = true
        let ran = await model.run("focus finder")
        XCTAssertFalse(ran)
        XCTAssertTrue(transport.requests.isEmpty)
        let preview = try XCTUnwrap(model.dryRunPreview)
        XCTAssertEqual(preview.url, "\(Fixture.server)/inject")
        XCTAssertEqual(preview.body, #"{"phrase":"focus finder"}"#)
    }

    func testConfirmWithoutAStagedRequestOrOutsideDryRunDoesNothing() async throws {
        let transport = FakeTransport()
        let model = makeModel(transport, defaults: try defaults())
        model.dryRun = true
        await model.confirmDryRun()
        XCTAssertNil(model.dryRunOutcome)
        XCTAssertNil(model.feedback)
        await model.execute(command)
        model.dryRun = false
        await model.confirmDryRun()
        XCTAssertNil(model.dryRunOutcome)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTurningDryRunOffRestoresRealExecute() async throws {
        let transport = FakeTransport([.http(200, Fixture.injectOK, [:])])
        let model = makeModel(transport, defaults: try defaults())
        model.dryRun = true
        model.dryRun = false
        let ran = await model.execute(command)
        XCTAssertTrue(ran)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.url?.query, nil, "real execute carries no dry_run flag")
        XCTAssertNil(model.dryRunPreview)
    }

    func testOversizedPhraseIsRejectedInDryRunToo() async throws {
        let model = makeModel(FakeTransport(), defaults: try defaults())
        model.dryRun = true
        let ran = await model.execute(command, phrase: String(repeating: "x", count: PaletteAPI.maxBodyBytes))
        XCTAssertFalse(ran)
        XCTAssertNil(model.dryRunPreview)
        XCTAssertEqual(model.feedback?.text, PaletteError.bodyTooLarge.message)
    }

    func testUnconfiguredDryRunStillSaysSetUpSettings() async throws {
        let model = PaletteModel(
            settings: FakeSettingsStore(""), cache: FakeCache(), defaults: try defaults()
        )
        model.dryRun = true
        await model.execute(command)
        XCTAssertNil(model.dryRunPreview)
        XCTAssertEqual(model.feedback?.text, PaletteError.notConfigured.message)
    }
}
