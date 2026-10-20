import XCTest
@testable import PocketPalette

final class ContextRankingTests: XCTestCase {
    private func cmd(_ rule: String, _ scope: PaletteCommand.Scope = .global, apps: [String] = [], tags: [String] = []) -> PaletteCommand {
        PaletteCommand(id: rule, rule: rule, context: "user/\(rule).voice", scope: scope, apps: apps, tags: tags)
    }

    private func rank(_ query: String, _ commands: [PaletteCommand], _ options: SearchOptions = SearchOptions()) -> [String] {
        CommandIndex(commands).search(query, options: options).map(\.command.rule)
    }

    // MARK: - Decoding

    func testScopeFieldsDecodeFromTheFeed() throws {
        let json = """
        {"id":"a1","rule":"zoom mute","kind":"literal","slots":[],"context":"user/zoom.voice","lineno":3,"shadowed":0,
         "scope":"app","apps":["zoom"],"tags":["meeting"]}
        """
        let command = try JSONDecoder.palette.decode(PaletteCommand.self, from: Data(json.utf8))
        XCTAssertEqual(command.scope, .app)
        XCTAssertEqual(command.apps, ["zoom"])
        XCTAssertEqual(command.tags, ["meeting"])
    }

    func testOlderFeedWithoutScopeDecodesAsGlobal() throws {
        let list = try JSONDecoder.palette.decode(CommandList.self, from: Data(Fixture.commandsJSON.utf8))
        XCTAssertEqual(Set(list.commands.map(\.scope)), [.global])
        XCTAssertTrue(list.commands.allSatisfy { $0.apps.isEmpty && $0.tags.isEmpty })
    }

    func testUnknownScopeValueDecodesAsGlobal() throws {
        let json = #"{"id":"a","rule":"x","scope":"window","apps":[],"tags":[]}"#
        XCTAssertEqual(try JSONDecoder.palette.decode(PaletteCommand.self, from: Data(json.utf8)).scope, .global)
    }

    func testScopeSurvivesTheDiskCacheRoundTrip() throws {
        let original = cmd("zoom mute", .app, apps: ["zoom"], tags: ["t"])
        let data = try JSONEncoder.palette.encode(original)
        XCTAssertEqual(try JSONDecoder.palette.decode(PaletteCommand.self, from: data), original)
    }

    // MARK: - Boost

    private var commands: [PaletteCommand] {
        [cmd("tab alpha"), cmd("tab beta", .tag, tags: ["browser"]), cmd("tab gamma", .app, apps: ["zoom"])]
    }

    func testDefaultOptionsKeepPlainTextRanking() {
        XCTAssertEqual(rank("tab", commands), ["tab beta", "tab alpha", "tab gamma"], "the shorter rule wins ties on text")
    }

    func testBoostRanksAppThenTagThenGlobalAmongEqualTextMatches() {
        let ranked = rank("tab", commands, SearchOptions(contextBoost: true))
        XCTAssertEqual(ranked, ["tab gamma", "tab beta", "tab alpha"])
    }

    func testBoostReportsItsSplitOnTheMatch() {
        let hits = CommandIndex(commands).search("tab", options: SearchOptions(contextBoost: true))
        XCTAssertEqual(hits.first?.contextBoost, RankingBoost.app)
        XCTAssertEqual(hits.last?.contextBoost, 0)
        XCTAssertEqual(hits.first?.historyBoost, 0)
    }

    func testBoostNeverLiftsAWorseTextTierOverAClearlyBetterOne() {
        // "tab" is a whole word in "tab open" but only a prefix of the word in "tabs closed": a 20+ point gap.
        let better = cmd("tab open")
        let worse = cmd("tabs open", .app, apps: ["zoom"])
        var options = SearchOptions(contextBoost: true)
        var history = ExecuteHistory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<50 { history.record(rule: "tabs open", at: now) }
        options.history = history
        options.now = now
        XCTAssertEqual(rank("tab", [worse, better], options), ["tab open", "tabs open"])
    }

    func testTotalBoostStaysUnderTheSmallestTextTierGap() {
        XCTAssertLessThan(RankingBoost.maxTotal, 20)
    }

    func testEmptyQueryPutsAppCommandsFirstAndKeepsServerOrderOtherwise() {
        let list = [cmd("c global"), cmd("a global"), cmd("z app", .app, apps: ["zoom"]), cmd("t tag", .tag, tags: ["x"]), cmd("b global")]
        XCTAssertEqual(rank("", list, SearchOptions(contextBoost: true)), ["z app", "t tag", "c global", "a global", "b global"])
        XCTAssertEqual(rank("", list), ["c global", "a global", "z app", "t tag", "b global"], "off: server order")
    }

    // MARK: - Filter

    func testThisAppOnlyKeepsJustAppScopedCommands() {
        let options = SearchOptions(appOnly: true)
        XCTAssertEqual(rank("tab", commands, options), ["tab gamma"])
        XCTAssertEqual(rank("", commands, options), ["tab gamma"])
    }

    func testThisAppOnlyStillRequiresATextMatch() {
        XCTAssertEqual(rank("zzz", commands, SearchOptions(appOnly: true)), [])
    }

    func testTagScopedCommandsAreNotAppOnly() {
        XCTAssertEqual(rank("beta", commands, SearchOptions(appOnly: true)), [])
    }

    func testFilterDoesNotNeedTheBoost() {
        XCTAssertEqual(rank("", commands, SearchOptions(contextBoost: false, appOnly: true)), ["tab gamma"])
    }
}
