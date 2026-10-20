import XCTest
@testable import PocketPalette

/// Fake 3-d word vectors, so the logic is tested without the OS model: axis 0 = erase, 1 = bookmark/save, 2 = history.
private final class FakeEmbedding: WordEmbedding, @unchecked Sendable {
    private let table: [String: [Float]] = [
        "clear": [1, 0, 0.2], "wipe": [0.95, 0, 0.3], "erase": [1, 0.05, 0.1],
        "history": [0.2, 0, 1], "browsing": [0.1, 0, 0.9], "record": [0.2, 0.1, 0.9],
        "bookmark": [0, 1, 0], "favorite": [0.05, 0.95, 0], "add": [0, 0.8, 0.1],
    ]
    private(set) var lookups = 0

    func vector(for word: String) -> [Float]? {
        lookups += 1
        return table[word]
    }
}

final class SemanticFallbackTests: XCTestCase {
    private let rules = ["history clear", "bookmark add", "tab (open|new)"]

    private func index(_ embedding: WordEmbedding?, rules: [PaletteCommand]? = nil) -> CommandIndex {
        CommandIndex(rules ?? self.rules.map { Fixture.command($0) }, embedding: embedding)
    }

    func testTextMatcherAloneFindsNothingForParaphrase() {
        XCTAssertEqual(index(nil).search("wipe my browsing record").map(\.command.rule), [])
    }

    func testFallbackRanksByMeaningWhenTextFindsNothing() {
        let hits = index(FakeEmbedding()).search("wipe my browsing record")
        XCTAssertEqual(hits.first?.command.rule, "history clear")
        XCTAssertFalse(hits.contains { $0.command.rule == "tab (open|new)" }, "unrelated rules stay out")
    }

    func testTextHitsStayFirstAndAreNotDuplicated() {
        let commands = ["history clear", "history show", "clear browsing record"].map { Fixture.command($0) }
        let hits = index(FakeEmbedding(), rules: commands).search("history")
        // Two text hits (fewer than the trigger): the fallback may add rules but never reorder or repeat them.
        XCTAssertEqual(hits.prefix(2).map(\.command.rule), ["history show", "history clear"])
        XCTAssertEqual(Set(hits.map(\.id)).count, hits.count)
    }

    func testFallbackNotConsultedWhenTextFillsTheTopThree() {
        let embedding = FakeEmbedding()
        let commands = ["tab one", "tab two", "tab three", "history clear"].map { Fixture.command($0) }
        let hits = index(embedding, rules: commands).search("tab")
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(embedding.lookups, 0, "built lazily and not at all when the text matcher is enough")
    }

    /// Three text hits that explain one word of the query each must not stop the fallback (the old trigger counted hits).
    func testJunkTextHitsDoNotBlockTheFallback() {
        let junk = ["wipe that", "erase that", "browsing that", "wipe <text>"]
        let commands = (junk + ["history clear"]).map { Fixture.command($0) }
        let query = "wipe browsing record"
        XCTAssertGreaterThanOrEqual(index(nil, rules: commands).search(query).count, 3, "three text hits: the old trigger stopped here")
        let hits = index(FakeEmbedding(), rules: commands).search(query)
        XCTAssertTrue(hits.prefix(5).contains { $0.command.rule == "history clear" }, "the meaning match is found")
        XCTAssertTrue(Set(junk).isSubset(of: Set(hits.map(\.command.rule))), "guesses are still listed")
    }

    func testTrustedTextHitsStayAheadOfTheFallback() {
        let commands = ["wipe that", "history clear"].map { Fixture.command($0) }
        XCTAssertEqual(index(FakeEmbedding(), rules: commands).search("wipe that").first?.command.rule, "wipe that")
    }

    func testHitsThatExplainLittleOfTheQueryCountAsGuesses() throws {
        let junk = try XCTUnwrap(FuzzyMatcher.match(
            normalizedQuery: "wipe browsing record", inNormalized: "wipe that", slot: .anaphor, partial: true
        ))
        XCTAssertLessThan(junk.coverage, CommandIndex.trustedCoverage)
        let real = try XCTUnwrap(FuzzyMatcher.match(
            normalizedQuery: "browsing record", inNormalized: "browsing record clear", slot: .none, partial: false
        ))
        XCTAssertGreaterThanOrEqual(real.coverage, CommandIndex.trustedCoverage)
    }

    func testContextWordsFavourTheCommandsOfTheAppNamed() {
        let ranker = SemanticRanker(
            rules: ["wipe", "wipe"],
            contexts: [SemanticRanker.contextWords(apps: ["Alacritty"], tags: [], context: ""),
                       SemanticRanker.contextWords(apps: ["Firefox"], tags: [], context: "")],
            embedding: FakeEmbedding()
        )
        XCTAssertEqual(ranker.rankAll(["wipe", "terminal"]).first?.rule, 0)
        XCTAssertEqual(ranker.rankAll(["wipe", "browser"]).first?.rule, 1)
        XCTAssertEqual(SemanticRanker.contextWords(apps: ["zoom.us"], tags: ["media"], context: "x/y/call.voice"),
                       ["zoom", "meeting", "call", "video", "media"])
    }

    func testThesaurusWordsStandInForWordsTheModelLacks() {
        // "enlarge" is not in the fake model; the matcher's table says it means zoom in.
        let ranker = SemanticRanker(rules: ["zoom in", "history clear"], embedding: FakeEmbedding())
        XCTAssertEqual(ranker.rank(["enlarge"]).first?.rule, 0)
    }

    func testIndexBuildIsLazy() {
        let embedding = FakeEmbedding()
        let commands = ["tab one", "tab two", "tab three", "history clear"].map { Fixture.command($0) }
        let built = index(embedding, rules: commands)
        XCTAssertEqual(embedding.lookups, 0)
        _ = built.search("tab")
        XCTAssertEqual(embedding.lookups, 0)
        _ = built.search("wipe my browsing record")
        XCTAssertGreaterThan(embedding.lookups, 0)
    }

    func testDissimilarQueryReturnsNothing() {
        XCTAssertEqual(index(FakeEmbedding()).search("quantum banana").map(\.command.rule), [])
    }

    func testEmptyQueryIsUnchanged() {
        XCTAssertEqual(index(FakeEmbedding()).search("  ").map(\.command.rule), rules)
    }

    func testAppOnlyFilterAppliesToFallbackHits() {
        let commands = [
            PaletteCommand(id: "a", rule: "history clear", context: "x", scope: .global),
            PaletteCommand(id: "b", rule: "bookmark add", context: "x", scope: .app, apps: ["Safari"]),
        ]
        var options = SearchOptions()
        options.appOnly = true
        XCTAssertEqual(index(FakeEmbedding(), rules: commands).search("wipe browsing record", options: options), [])
        XCTAssertEqual(index(FakeEmbedding(), rules: commands).search("favorite", options: options).map(\.id), ["b"])
    }

    func testRuleVariantsExpandGroupsAndOptionals() {
        XCTAssertEqual(SemanticRanker.variants(of: "tab (open|new)"), [["tab", "open"], ["tab", "new"]])
        XCTAssertEqual(
            Set(SemanticRanker.variants(of: "(mark|flag) (all )?unread")),
            [["mark", "all", "unread"], ["mark", "unread"], ["flag", "all", "unread"], ["flag", "unread"]]
        )
        XCTAssertEqual(SemanticRanker.variants(of: "find <text> older [mail]"), [["find", "older", "mail"], ["find", "older"]])
        XCTAssertEqual(SemanticRanker.variants(of: "say <text>"), [["say"]])
    }

    func testRuleVariantsAreCapped() {
        let rule = (1...6).map { _ in "(a|b|c)" }.joined(separator: " ")
        XCTAssertLessThanOrEqual(SemanticRanker.variants(of: rule).count, SemanticRanker.maxVariantsPerRule)
    }

    /// Real OS model; skipped where it is not installed (no assertion on exact order beyond a clear paraphrase).
    func testSystemEmbeddingParaphrase() throws {
        try XCTSkipUnless(SystemWordEmbedding.shared.isAvailable, "no English word embedding on this OS")
        let commands = ["tab close", "volume up", "screen lock"].map { Fixture.command($0) }
        let hits = CommandIndex(commands, embedding: SystemWordEmbedding.shared).search("lock the display")
        XCTAssertEqual(hits.first?.command.rule, "screen lock")
    }

    /// Cost of the real model on the 106-rule fixture, printed not asserted (simulator figures; on-device is unverified).
    func testReportCost() throws {
        try XCTSkipUnless(SystemWordEmbedding.shared.isAvailable, "no English word embedding on this OS")
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden/commands.json")
        struct File: Decodable { let commands: [PaletteCommand] }
        let commands = try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).commands
        let before = Self.residentMegabytes()
        let started = Date()
        let hits = CommandIndex(commands, embedding: SystemWordEmbedding.shared).search("shrink this thing down out of sight")
        let first = Date().timeIntervalSince(started) * 1000
        let after = Self.residentMegabytes()
        print("SEMANTIC cost: first fallback query (loads model, builds \(commands.count)-rule index) \(Int(first)) ms, "
            + "resident memory \(Int(before)) -> \(Int(after)) MB, hits \(hits.count)")
    }

    /// The same at the size of the live feed (about 814 rules): the fixture's rules recombined (a first word from one
    /// rule, the rest from another) so vocabulary and variant counts are realistic. Printed, not asserted.
    func testReportCostAtLiveScale() throws {
        try XCTSkipUnless(SystemWordEmbedding.shared.isAvailable, "no English word embedding on this OS")
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden/commands.json")
        struct File: Decodable { let commands: [PaletteCommand] }
        let base = try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).commands
        var commands = base
        var step = 1
        while commands.count < 814 {
            for (offset, command) in base.enumerated() where commands.count < 814 {
                let other = base[(offset * 7 + step) % base.count].rule.split(separator: " ").dropFirst().joined(separator: " ")
                commands.append(PaletteCommand(
                    id: "s\(commands.count)", rule: command.rule.split(separator: " ").prefix(1).joined() + " " + other,
                    context: command.context, scope: command.scope, apps: command.apps, tags: command.tags
                ))
            }
            step += 1
        }
        let queries = ["shrink this thing down out of sight", "I want everyone in the call to see my display",
                       "move the cursor to the start of the file", "quickly open a file by its name", "tab"]
        let before = Self.residentMegabytes()
        let index = CommandIndex(commands, embedding: SystemWordEmbedding.shared)
        var timings = [String]()
        for query in queries + queries {
            let started = Date()
            _ = index.search(query)
            timings.append(String(format: "%.0f", Date().timeIntervalSince(started) * 1000))
        }
        print("SEMANTIC cost at \(commands.count) rules: search ms per query (first includes model load + index build) "
            + timings.joined(separator: ", ") + "; resident memory \(Int(before)) -> \(Int(Self.residentMegabytes())) MB")
    }

    private static func residentMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}
