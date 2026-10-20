import XCTest
@testable import PocketPalette

/// Concept links: inverse relations and concept words. Examples are not taken from any golden or held-out set.
final class ConceptLinksTests: XCTestCase {
    private let links = ConceptLinks.standard

    private func rewrite(_ query: String) -> String? { links.rewrite(FuzzyMatcher.normalize(query)) }

    func testOppositeFlipsTheNamedWord() {
        XCTAssertEqual(rewrite("the opposite of expanding"), "collapse")
        XCTAssertEqual(rewrite("opposite of locking the screen"), "unlock the screen")
        XCTAssertEqual(rewrite("inverse of folding"), "unfold")
    }

    func testOppositeUsesAntonymNotUndoWord() {
        // Antonym of close is open; reopen is only what takes a close back.
        XCTAssertEqual(rewrite("the opposite of closing"), "open")
        XCTAssertEqual(rewrite("put back the thing I closed"), "the thing i reopen")
    }

    func testUndoMarkersNameTheWordThatTakesTheActionBack() {
        XCTAssertEqual(rewrite("undo hiding the toolbar"), "show the toolbar")
        XCTAssertEqual(rewrite("bring back the window I minimized"), "the window i maximize")
        XCTAssertEqual(rewrite("I locked it and want that reversed"), "i unlock it and want that")
    }

    func testReverseOfUnflippableActionIsUndo() {
        XCTAssertEqual(rewrite("the reverse of pasting"), "the undo")
        XCTAssertEqual(rewrite("the opposite of renaming"), "undo renaming")
    }

    func testQueriesWithoutAnInversionAreUnchanged() {
        XCTAssertNil(rewrite("undo my last change"))
        XCTAssertNil(rewrite("bring back the sidebar"))
        XCTAssertNil(rewrite("lock the screen"))
        XCTAssertNil(rewrite("restore defaults"))
        XCTAssertNil(rewrite(""))
    }

    func testIndexSearchesTheInversionFirstAndKeepsTheLiteralReadingAfter() {
        let commands = ["window (maximize|expand)", "window minimize", "screen lock"].map { Fixture.command($0) }
        let linked = CommandIndex(commands, links: .standard)
        XCTAssertEqual(linked.search("the opposite of minimizing").first?.command.rule, "window (maximize|expand)")
        XCTAssertTrue(linked.search("the opposite of minimizing").map(\.command.rule).contains("window minimize"))
        // Off: the named word wins, as before.
        XCTAssertEqual(CommandIndex(commands).search("the opposite of minimizing").first?.command.rule, "window minimize")
    }

    func testConceptWordReachesRuleWordOnlyWhenOn() {
        let commands = ["(show|hide) desktop", "tab close"].map { Fixture.command($0) }
        XCTAssertEqual(CommandIndex(commands, links: .standard).search("backdrop").first?.command.rule, "(show|hide) desktop")
        XCTAssertTrue(CommandIndex(commands).search("backdrop").isEmpty)
    }

    func testOffByDefaultInTheApp() {
        XCTAssertNil(ConceptLinks.appDefault)
    }

    func testFlagOffIsIdentical() {
        let commands = ["tab (new|open)", "tab close", "undo that", "redo that"].map { Fixture.command($0) }
        let plain = CommandIndex(commands), nilLinks = CommandIndex(commands, links: nil)
        for query in ["undo the undo", "open a tab", "close it", "the opposite of closing"] {
            XCTAssertEqual(plain.search(query).map(\.id), nilLinks.search(query).map(\.id), query)
        }
    }

    func testTablesAreConsistent() {
        for (first, second) in ConceptLinkData.antonymPairs {
            XCTAssertNotEqual(first, second)
        }
        for (word, targets) in ConceptLinkData.concepts {
            XCTAssertFalse(targets.isEmpty, word)
            XCTAssertFalse(targets.contains(word), word)
        }
    }
}
