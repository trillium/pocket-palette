import XCTest
@testable import PocketPalette

final class FuzzyMatcherTests: XCTestCase {
    private func rank(_ query: String, _ rules: [String]) -> [String] {
        CommandIndex(rules.map { Fixture.command($0) }).search(query).map(\.command.rule)
    }

    func testExactBeatsWordPrefixBeatsSubstringBeatsScattered() {
        let rules = ["xtab", "retab thing", "tab open", "tab", "tobacco anywhere bold"]
        XCTAssertEqual(rank("tab", rules), ["tab", "tab open", "xtab", "retab thing", "tobacco anywhere bold"])
    }

    func testNonMatchesAreExcluded() {
        XCTAssertEqual(rank("zzz", ["tab open", "playback now"]), [])
        XCTAssertEqual(rank("tab pl", ["tab open", "playback now"]), [])
    }

    func testEveryTokenMustMatchInAnyOrder() {
        let rules = ["playback now", "now playing", "tab open"]
        XCTAssertEqual(Set(rank("now play", rules)), ["playback now", "now playing"])
        XCTAssertEqual(rank("open tab", rules), ["tab open"])
    }

    func testScatteredLettersMatchAsLastResort() {
        let rules = ["playback now", "tab open"]
        XCTAssertEqual(rank("pbn", rules), ["playback now"])
    }

    func testEarlierWordsAndShorterRulesWin() {
        XCTAssertEqual(rank("open", ["close open tab", "open", "open tab"]), ["open", "open tab", "close open tab"])
    }

    func testCaseAccentsAndPunctuationAreIgnored() {
        XCTAssertEqual(rank("TAB-open", ["tab open"]), ["tab open"])
        XCTAssertEqual(rank("cafe", ["caf\u{E9} order"]), ["caf\u{E9} order"])
    }

    func testEmptyQueryKeepsServerOrder() {
        XCTAssertEqual(rank("   ", ["b", "a", "c"]), ["b", "a", "c"])
    }

    func testMatchesAnyAlternativeOfAGroup() {
        // "new" only appears inside the (open|new) group; the spoken form uses the first alternative.
        let hits = CommandIndex([Fixture.command("tab (open|new)")]).search("new")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.spoken, "tab open")
    }

    func testCapturesAreNotSearchableButRuleWordsAre() {
        let index = CommandIndex([Fixture.command("say <text>")])
        XCTAssertEqual(index.search("say").count, 1)
        XCTAssertEqual(index.search("user").count, 0)
        XCTAssertNil(index.search("say").first?.spoken)
    }

    func testLimitIsApplied() {
        let index = CommandIndex((0..<50).map { Fixture.command("cmd \($0)") })
        XCTAssertEqual(index.search("cmd", limit: 10).count, 10)
    }

    func testScoreIsNilOrNumber() {
        XCTAssertNil(FuzzyMatcher.score(query: "q", in: "abc"))
        XCTAssertNotNil(FuzzyMatcher.score(query: "ab", in: "abc"))
        XCTAssertEqual(FuzzyMatcher.score(query: "", in: "abc"), 0)
    }

    // MARK: partial matching, stems, app slots

    func testPartialFallbackRanksByMatchedWordsWhenNothingMatchesFully() {
        let rules = ["speech off", "speech wake", "tab close"]
        // "stop" is in no rule: the strict pass is empty, so words matched decide.
        let ranked = rank("stop speech wake", rules)
        XCTAssertEqual(ranked.first, "speech wake")
        XCTAssertFalse(ranked.contains("tab close"))
    }

    func testPartialFallbackNeedsHalfTheWordsToMatch() {
        XCTAssertEqual(rank("make coffee tomorrow morning", ["make tea", "tab close"]), [])
    }

    func testPartialFallbackStaysOffWhenAStrictMatchExists() {
        XCTAssertEqual(rank("tab close", ["tab close", "tab open", "window close"]), ["tab close"])
    }

    func testOneCommonWordDoesNotCarryALongQuery() {
        let rules = ["volume down", "scroll bottom", "show downloads"]
        XCTAssertEqual(rank("jump to the very end of everything", rules), [])
        XCTAssertEqual(rank("scroll down to the end", rules).first, "scroll bottom")
    }

    func testStemsCoverInflections() {
        XCTAssertEqual(FuzzyMatcher.stems("vertically"), ["vertical"])
        XCTAssertTrue(FuzzyMatcher.stems("listening").contains("listen"))
        XCTAssertTrue(FuzzyMatcher.stems("usages").contains("usage"))
        XCTAssertTrue(FuzzyMatcher.stems("rerun").contains("run"))
        XCTAssertTrue(FuzzyMatcher.stems("debugger").contains("debugg"))
        XCTAssertEqual(FuzzyMatcher.stems("tab"), [])
    }

    func testInflectedQueryWordsMatchRuleWords() {
        XCTAssertEqual(rank("split vertically", ["split vertical", "split horizontal"]).first, "split vertical")
        XCTAssertEqual(rank("rerun command", ["run last command", "tab close"]).first, "run last command")
        XCTAssertEqual(rank("show usages", ["show references", "show downloads"]).first, "show references")
    }

    func testTrailingWordFillsARunningApplicationsSlot() {
        let rules = ["focus <app>", "focus address bar", "tab close"]
        XCTAssertEqual(rank("focus chrome", rules).first, "focus <app>")
        // A rule with real words for it still wins.
        XCTAssertEqual(rank("focus address bar", rules).first, "focus address bar")
        // The verb must match: a bare app name is not a command.
        XCTAssertEqual(rank("chrome", rules), [])
    }

    // MARK: phrasal verbs, open slots

    func testPhrasalVerbsCollapseToOneVerb() {
        XCTAssertEqual(FuzzyMatcher.collapsePhrases(["get", "rid", "of", "the", "file"]), ["remove", "the", "file"])
        XCTAssertEqual(FuzzyMatcher.collapsePhrases(["turn", "on", "the", "lamp"]), ["start", "the", "lamp"])
        XCTAssertEqual(FuzzyMatcher.collapsePhrases(["bring", "up", "history"]), ["open", "history"])
        // A trailing particle belongs to the verb at the front ("turn the lamp off").
        XCTAssertEqual(FuzzyMatcher.collapsePhrases(["turn", "the", "lamp", "off"]), ["stop", "the", "lamp"])
        // A particle that opens a noun phrase is left alone.
        XCTAssertEqual(
            FuzzyMatcher.collapsePhrases(["switch", "to", "the", "file", "on", "the", "left"]),
            ["switch", "to", "the", "file", "on", "the", "left"]
        )
        XCTAssertEqual(FuzzyMatcher.collapsePhrases(["switch", "off"]), ["stop"])
    }

    func testPhrasalVerbsReachRulesThatNameTheVerb() {
        XCTAssertEqual(rank("get rid of the pane", ["pane close", "pane open"]).first, "pane close")
        XCTAssertEqual(rank("turn the lights on", ["(start|stop) lights", "lights dim"]).first, "(start|stop) lights")
        XCTAssertEqual(rank("look up weather", ["(search|find) weather", "weather map"]).first, "(search|find) weather")
    }

    func testFreeTextSlotTakesTheWordsAfterTheVerb() {
        let rules = ["(search|find) <text>", "search history", "tab close"]
        XCTAssertEqual(rank("find red shoes on sale", rules).first, "(search|find) <text>")
        // Real rule words still win, and the verb must come first.
        XCTAssertEqual(rank("search history", rules).first, "search history")
        XCTAssertEqual(rank("red shoes", rules), [])
    }

    func testThatRuleTakesAnObjectAfterTheVerb() {
        let rules = ["(copy|yank) that", "copy line", "tab close"]
        XCTAssertEqual(rank("copy the selected text", rules).first, "(copy|yank) that")
        XCTAssertEqual(rank("copy line", rules).first, "copy line")
        XCTAssertEqual(rank("selected text", rules), [])
    }

    func testRemoveAndRestoreReachCloseAndReopen() {
        XCTAssertEqual(rank("remove window", ["window close", "window open"]).first, "window close")
        XCTAssertEqual(rank("restore window", ["window close", "window reopen"]).first, "window reopen")
    }

    // MARK: verb classes

    func testInterchangeableVerbsReachTheRuleVerb() {
        XCTAssertEqual(rank("highlight paragraph", ["(select|grab) paragraph", "paragraph indent"]).first, "(select|grab) paragraph")
        XCTAssertEqual(rank("reveal the minimap", ["(show|hide) minimap", "minimap size"]).first, "(show|hide) minimap")
        XCTAssertEqual(rank("locate bookmark", ["find bookmark", "bookmark new"]).first, "find bookmark")
        XCTAssertEqual(rank("navigate to inbox", ["(go|jump) to inbox", "inbox archive"]).first, "(go|jump) to inbox")
        XCTAssertEqual(rank("exit the room", ["leave room", "room new"]).first, "leave room")
    }

    func testVerbClassesWorkBothWays() {
        XCTAssertEqual(rank("pick color", ["choose color", "color reset"]).first, "choose color")
        XCTAssertEqual(rank("choose color", ["pick color", "color reset"]).first, "pick color")
    }

    func testDirectionVerbsReachUpAndDownRules() {
        XCTAssertEqual(rank("boost the bass", ["bass up", "bass down"]).first, "bass up")
        XCTAssertEqual(rank("reduce brightness", ["brightness up", "brightness down"]).first, "brightness down")
        XCTAssertEqual(rank("revert", ["undo that", "redo that"]).first, "undo that")
    }

    func testAWordInTheRuleBeatsItsSynonym() {
        XCTAssertEqual(rank("pick color", ["choose color", "pick color"]).first, "pick color")
        XCTAssertEqual(rank("lower hand", ["raise hand", "lower hand"]).first, "lower hand")
    }

    func testDisappearIdiomsReachRemovalRules() {
        XCTAssertEqual(
            FuzzyMatcher.collapsePhrases(["let", "the", "popup", "go", "away"]), ["let", "the", "popup", "remove"]
        )
        XCTAssertEqual(FuzzyMatcher.collapsePhrases(["go", "back"]), ["go", "back"])
        XCTAssertEqual(rank("make the popup go away", ["popup close", "popup open"]).first, "popup close")
        XCTAssertEqual(rank("make the banner disappear", ["banner hide", "banner show"]).first, "banner hide")
        XCTAssertEqual(rank("go back", ["(go|navigate) back", "popup close"]).first, "(go|navigate) back")
    }

    // MARK: coverage, size words, take-me phrases

    func testShortSynonymsDoNotMatchAsWordPrefixes() {
        // "enlarge" means zoom in; the stand-in "in" must not reach the front of "incognito".
        XCTAssertEqual(rank("enlarge", ["incognito window", "zoom in"]), ["zoom in"])
    }

    func testSizeWordsReachRulesWithTheirDirection() {
        XCTAssertEqual(rank("make it larger", ["zoom in", "zoom out", "font reset"]).first, "zoom in")
        XCTAssertEqual(rank("tiny", ["zoom out", "zoom in"]).first, "zoom out")
    }

    func testASetOfHintsFitsBestWhereMostOfItIsPresent() {
        XCTAssertEqual(rank("louder", ["page up", "volume up", "volume down"]).first, "volume up")
    }

    func testTakeMeToIsGoTo() {
        XCTAssertEqual(FuzzyMatcher.collapsePhrases(["take", "me", "to", "the", "inbox"]), ["go", "the", "inbox"])
        XCTAssertEqual(rank("take me to the inbox", ["(go|jump) to inbox", "take note"]).first, "(go|jump) to inbox")
        XCTAssertEqual(FuzzyMatcher.collapsePhrases(["hang", "up", "now"]), ["end", "now"])
        XCTAssertEqual(FuzzyMatcher.collapsePhrases(["throw", "away", "it"]), ["remove", "it"])
    }

    func testNounClassesAndSplitVerbs() {
        XCTAssertEqual(rank("divide the screen", ["screen split", "screen lock"]).first, "screen split")
        XCTAssertEqual(rank("open the garbage", ["(empty|open) trash", "trash settings"]).first, "(empty|open) trash")
        XCTAssertEqual(rank("unindent", ["outdent line", "indent line"]).first, "outdent line")
    }

    func testCoverageIsTheShareOfQueryWordsTheRuleExplains() throws {
        let full = try XCTUnwrap(FuzzyMatcher.match(normalizedQuery: "garage door", inNormalized: "garage door open"))
        XCTAssertEqual(full.coverage, 1)
        let slotOnly = try XCTUnwrap(FuzzyMatcher.match(
            normalizedQuery: "garage door lights", inNormalized: "garage that", slot: .anaphor
        ))
        XCTAssertEqual(slotOnly.coverage, 1.0 / 3.0, accuracy: 0.001, "words a slot swallowed are not explained")
    }
}
