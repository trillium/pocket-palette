import XCTest
@testable import PocketPalette

final class PunctuationStripTests: XCTestCase {
    private let rules = ["open the file", "dont panic", "re open tab", "close file", "naïve café", "日本語 入力"]

    private func ids(_ query: String) -> [String] {
        CommandIndex(rules.map { Fixture.command($0) }).search(query).map(\.command.rule)
    }

    func testPunctuationDoesNotChangeResults() {
        XCTAssertEqual(ids("open, the file!"), ids("open the file"))
        XCTAssertEqual(ids("open the file?!"), ids("open the file"))
        XCTAssertEqual(ids("...open the file..."), ids("open the file"))
        XCTAssertEqual(ids("  open,,,   the\tfile  "), ids("open the file"))
    }

    func testNormalizeShapes() {
        XCTAssertEqual(FuzzyMatcher.normalize("open, the file!"), "open the file")
        XCTAssertEqual(FuzzyMatcher.normalize("don't"), "dont")
        XCTAssertEqual(FuzzyMatcher.normalize("don\u{2019}t"), "dont")
        XCTAssertEqual(FuzzyMatcher.normalize("re-open"), "re open")
        XCTAssertEqual(FuzzyMatcher.normalize("a   b\n\tc"), "a b c")
        XCTAssertEqual(FuzzyMatcher.normalize("open 🙂 file $+<>"), "open file")
        XCTAssertEqual(FuzzyMatcher.normalize("Café, NAÏVE"), "cafe naive")
        XCTAssertEqual(FuzzyMatcher.normalize("日本語、入力。"), "日本語 入力")
        XCTAssertEqual(FuzzyMatcher.normalize("abc123!"), "abc123")
    }

    func testInternalPunctuationAndHyphens() {
        XCTAssertEqual(ids("don't panic").first, "dont panic")
        XCTAssertEqual(ids("re-open tab").first, "re open tab")
    }

    func testEmptyAfterStripBehavesAsEmptyQuery() {
        let empty = ids("")
        XCTAssertFalse(empty.isEmpty)
        XCTAssertEqual(ids("?!..."), empty)
        XCTAssertEqual(ids("🙂"), empty)
        XCTAssertEqual(FuzzyMatcher.normalize("!!!"), "")
    }

    func testUnicodeLettersSurvive() {
        XCTAssertEqual(ids("日本語, 入力!").first, "日本語 入力")
        XCTAssertEqual(ids("naïve café?").first, "naïve café")
    }
}
