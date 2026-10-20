import XCTest
@testable import PocketPalette

final class RuleSpellerTests: XCTestCase {
    func testLiteralRuleIsSpokenAsIs() {
        XCTAssertEqual(RuleSpeller.spoken("playback now"), "playback now")
    }

    func testTakesFirstAlternativeAndDropsOptionals() {
        XCTAssertEqual(RuleSpeller.spoken("tab (open | new)"), "tab open")
        XCTAssertEqual(RuleSpeller.spoken("go [to] line"), "go line")
        XCTAssertEqual(RuleSpeller.spoken("(reference | ref | cheat sheet)"), "reference")
        XCTAssertEqual(RuleSpeller.spoken("a | b"), "a")
    }

    func testAnchorsAndRepeatMarkers() {
        XCTAssertEqual(RuleSpeller.spoken("^help$"), "help")
        XCTAssertEqual(RuleSpeller.spoken("go up+ now"), "go up now")
        XCTAssertEqual(RuleSpeller.spoken("go up* now"), "go now")
    }

    func testCapturesAndListsNeedInput() {
        XCTAssertNil(RuleSpeller.spoken("say <text>"))
        XCTAssertNil(RuleSpeller.spoken("emoji {emoji}"))
    }

    func testUnbalancedRuleIsNotSpoken() {
        XCTAssertNil(RuleSpeller.spoken("tab (open"))
        XCTAssertNil(RuleSpeller.spoken("tab open)"))
        XCTAssertNil(RuleSpeller.spoken(""))
    }

    func testSearchTextKeepsAllAlternativesAndDropsPlaceholders() {
        XCTAssertEqual(RuleSpeller.searchText("tab (open|new) [now]"), "tab open new now")
        XCTAssertEqual(RuleSpeller.searchText("say <text> {emoji} twice"), "say twice")
    }
}
