import XCTest
@testable import PocketPalette

final class ServerSettingsTests: XCTestCase {
    func testPrefillComesFromTheBuildSettingOrIsEmpty() {
        XCTAssertEqual(ServerSettings.prefill("http://macbook.tail0.ts.net:7399"), "http://macbook.tail0.ts.net:7399")
        XCTAssertEqual(ServerSettings.prefill("http://"), "", "PALETTE_SERVER_HOST unset: not set up")
        XCTAssertEqual(ServerSettings.prefill(nil), "")
        XCTAssertNotNil(ServerSettings(baseURLText: Fixture.server).baseURL)
    }

    func testHTTPAndHTTPSHostsAreAccepted() {
        XCTAssertNotNil(ServerSettings.validate("  http://host.ts.net:7399 "))
        XCTAssertNotNil(ServerSettings.validate("https://host.ts.net:7399"))
        XCTAssertNil(ServerSettings.validate("ftp://host.ts.net"))
        XCTAssertNil(ServerSettings.validate("host.ts.net"))
        XCTAssertNil(ServerSettings.validate("http://"))
        XCTAssertNil(ServerSettings.validate(""))
        XCTAssertNil(ServerSettings.validate("http://user:pw@host.ts.net"))
        XCTAssertNil(ServerSettings.validate("http://host.ts.net/?token=abc"))
    }

    func testUserDefaultsStoreFallsBackToThePrefillAndPersists() throws {
        let suite = "palette-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults, fallback: Fixture.server)
        XCTAssertEqual(store.load().baseURLText, Fixture.server)
        defaults.set("", forKey: UserDefaultsSettingsStore.key)
        XCTAssertEqual(store.load().baseURLText, Fixture.server, "an empty saved value means the prefill")
        store.save(ServerSettings(baseURLText: " http://other.ts.net:1 "))
        XCTAssertEqual(store.load().baseURLText, "http://other.ts.net:1")
    }
}

final class CommandCacheTests: XCTestCase {
    private var file: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString).json")
    }

    func testRoundTripPreservesCommands() throws {
        let url = file
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = DiskCommandCache(fileURL: url)
        let list = try JSONDecoder.palette.decode(CommandList.self, from: Data(Fixture.commandsJSON.utf8))
        cache.save(CachedCommands(server: "https://a", rev: list.commandsRev, commands: list.commands))
        let loaded = try XCTUnwrap(cache.load(server: "https://a"))
        XCTAssertEqual(loaded.commands, list.commands)
        XCTAssertEqual(loaded.rev, "9a2e")
    }

    func testListFromAnotherServerIsIgnored() {
        let url = file
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = DiskCommandCache(fileURL: url)
        cache.save(CachedCommands(server: "https://a", rev: "1", commands: [Fixture.command("x")]))
        XCTAssertNil(cache.load(server: "https://b"))
    }

    func testMissingOrCorruptFileIsNil() throws {
        let url = file
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = DiskCommandCache(fileURL: url)
        XCTAssertNil(cache.load(server: "https://a"))
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(cache.load(server: "https://a"))
    }
}

final class BackoffTests: XCTestCase {
    func testDoublesUpToMaximumAndResets() {
        var backoff = Backoff(base: 1.5, maximum: 10)
        XCTAssertEqual(backoff.current, 1.5)
        XCTAssertEqual(backoff.failure(), 1.5)
        XCTAssertEqual(backoff.failure(), 3)
        XCTAssertEqual(backoff.failure(), 6)
        XCTAssertEqual(backoff.failure(), 10)
        XCTAssertEqual(backoff.failure(), 10)
        backoff.success()
        XCTAssertEqual(backoff.current, 1.5)
    }
}
