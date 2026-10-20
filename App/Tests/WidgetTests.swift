import XCTest
@testable import PocketPalette

final class RecordingWidget: WidgetPublishing, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [WidgetSnapshot] = []
    var published: [WidgetSnapshot] { lock.withLock { snapshots } }
    func publish(_ snapshot: WidgetSnapshot) { lock.withLock { snapshots.append(snapshot) } }
}

final class WidgetPickerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cmd(_ rule: String, _ scope: PaletteCommand.Scope = .global) -> PaletteCommand {
        PaletteCommand(id: "id-\(rule)", rule: rule, context: "user/x.voice", scope: scope)
    }

    private func pick(_ commands: [PaletteCommand], history: ExecuteHistory = ExecuteHistory(), limit: Int = 3) -> [String] {
        WidgetPicker.snapshot(
            index: CommandIndex(commands), appName: "Safari", dryRun: false, history: history, now: now, limit: limit
        ).items.map(\.rule)
    }

    func testPicksAtMostThree() {
        XCTAssertEqual(pick((1...8).map { cmd("rule \($0)") }).count, 3)
        XCTAssertEqual(WidgetSnapshot.limit, 3)
    }

    func testAppScopedCommandsOutrankTagThenGlobal() {
        let commands = [cmd("g one"), cmd("g two"), cmd("t one", .tag), cmd("a one", .app), cmd("g three")]
        XCTAssertEqual(pick(commands), ["a one", "t one", "g one"])
    }

    func testRunHistoryReordersWithinAScope() {
        var history = ExecuteHistory()
        history.record(rule: "g three", at: now)
        history.record(rule: "g three", at: now)
        XCTAssertEqual(pick([cmd("g one"), cmd("g two"), cmd("g three")], history: history).first, "g three")
    }

    func testEqualBoostsKeepServerOrder() {
        XCTAssertEqual(pick([cmd("zeta"), cmd("alpha"), cmd("mid")]), ["zeta", "alpha", "mid"])
    }

    func testCommandsThatNeedASpokenValueAreSkipped() {
        let commands = [cmd("go to <line_number>", .app), cmd("tab open", .global)]
        XCTAssertEqual(pick(commands), ["tab open"])
    }

    func testFewerThanThreeAndNone() {
        XCTAssertEqual(pick([cmd("only")]), ["only"])
        XCTAssertEqual(pick([]), [])
    }

    func testSnapshotCarriesContextDryRunAndRuleOnly() throws {
        let snap = WidgetPicker.snapshot(
            index: CommandIndex([cmd("tab open", .app)]), appName: "Safari", dryRun: true, history: ExecuteHistory(), now: now
        )
        XCTAssertTrue(snap.dryRun)
        XCTAssertEqual(snap.appName, "Safari")
        XCTAssertEqual(snap.items.first?.scope, "app")
        XCTAssertEqual(snap.items.first?.context, "x.voice")
        let json = String(bytes: try JSONEncoder().encode(snap), encoding: .utf8) ?? ""
        XCTAssertFalse(json.lowercased().contains("token"))
        XCTAssertFalse(json.contains("://"))
    }
}

final class WidgetLinkAndStoreTests: XCTestCase {
    func testLinkRoundTripsAnId() {
        let url = WidgetLink.url(forCommand: "b41c9e07")
        XCTAssertEqual(url.absoluteString, "pocketpalette://command?id=b41c9e07")
        XCTAssertEqual(WidgetLink.commandID(in: url), "b41c9e07")
    }

    func testForeignOrEmptyLinksAreIgnored() throws {
        XCTAssertNil(WidgetLink.commandID(in: try XCTUnwrap(URL(string: "https://command?id=a"))))
        XCTAssertNil(WidgetLink.commandID(in: try XCTUnwrap(URL(string: "pocketpalette://other?id=a"))))
        XCTAssertNil(WidgetLink.commandID(in: try XCTUnwrap(URL(string: "pocketpalette://command?id="))))
        XCTAssertNil(WidgetLink.commandID(in: try XCTUnwrap(URL(string: "pocketpalette://command"))))
    }

    func testStoreRoundTripAndSkipsUnchangedWrites() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let store = WidgetSnapshotStore(fileURL: file)
        var snap = WidgetSnapshot.sample
        XCTAssertTrue(store.save(snap))
        XCTAssertEqual(store.load()?.items, snap.items)
        snap.updatedAt = snap.updatedAt.addingTimeInterval(60)
        XCTAssertFalse(store.save(snap), "only updatedAt differs: no reload")
        snap.dryRun.toggle()
        XCTAssertTrue(store.save(snap))
    }

    func testStoreWithoutAGroupContainerIsInert() {
        let store = WidgetSnapshotStore(fileURL: nil)
        XCTAssertNil(store.load())
        XCTAssertFalse(store.save(.sample))
    }
}

@MainActor
final class WidgetModelTests: XCTestCase {
    private let cached = CachedCommands(
        server: Fixture.server, rev: "r1",
        commands: [PaletteCommand(id: "c1", rule: "tab open", scope: .app), PaletteCommand(id: "c2", rule: "go back")]
    )

    private func make(_ transport: FakeTransport, widget: RecordingWidget, dryRun: Bool) throws -> PaletteModel {
        let name = "widget-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        defaults.set(dryRun, forKey: PaletteModel.dryRunKey)
        return PaletteModel(
            settings: FakeSettingsStore(), cache: FakeCache(cached),
            defaults: defaults, widget: widget,
            makeAPI: { PaletteAPI(baseURL: $0, transport: transport) }
        )
    }

    func testModelPublishesTopRowsFromTheCacheOnce() throws {
        let widget = RecordingWidget()
        _ = try make(FakeTransport(), widget: widget, dryRun: false)
        XCTAssertEqual(widget.published.count, 1, "no empty flash before the cached list")
        XCTAssertEqual(widget.published.last?.items.map(\.rule), ["tab open", "go back"])
    }

    func testDryRunToggleRepublishes() throws {
        let widget = RecordingWidget()
        let model = try make(FakeTransport(), widget: widget, dryRun: false)
        model.dryRun = true
        XCTAssertEqual(widget.published.last?.dryRun, true)
    }

    func testWidgetTapInDryRunStagesAndSendsNothing() async throws {
        let transport = FakeTransport([.http(200, Fixture.injectOK, [:])])
        let model = try make(transport, widget: RecordingWidget(), dryRun: true)
        await model.openFromWidget(commandID: "c1")
        XCTAssertTrue(transport.requests.isEmpty, "dry run must not reach the transport")
        XCTAssertEqual(model.dryRunPreview?.command?.id, "c1")
    }

    func testWidgetTapOnAVanishedCommandSendsNothing() async throws {
        let transport = FakeTransport([.http(200, Fixture.injectOK, [:])])
        let model = try make(transport, widget: RecordingWidget(), dryRun: false)
        await model.openFromWidget(commandID: "gone")
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(model.feedback?.isError, true)
    }
}
