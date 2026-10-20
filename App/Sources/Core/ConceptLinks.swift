import Foundation

/// Relations between words that word similarity does not give: opposites ("the opposite of indenting"), what undoes
/// what ("put back the tab I closed", "undo the undo") and everyday words that point at interface words ("wallpaper"
/// -> desktop). Ranking only: it rewrites a query and offers extra stand-in words, it never creates or changes a
/// command. Everything is on-device; the tables are in `ConceptLinkData`.
///
/// Off by default: `CommandIndex` takes a `ConceptLinks` only when asked (`appDefault` is the app's setting).
struct ConceptLinks: Sendable {
    static let standard = ConceptLinks()
    /// What the app passes to `CommandIndex`: nil keeps the feature off until it is measured and chosen.
    static let appDefault: ConceptLinks? = nil

    /// Query word -> interface words (see `ConceptLinkData.concepts`), tried like thesaurus entries.
    let alternatives: [String: [String]]
    private let opposites: [String: String]

    init(concepts: [String: [String]] = ConceptLinkData.concepts, pairs: [(String, String)] = ConceptLinkData.antonymPairs) {
        alternatives = concepts
        var table = [String: String]()
        for (first, second) in pairs {
            table[first] = table[first] ?? second
            table[second] = table[second] ?? first
        }
        opposites = table
    }

    /// How a marker asks for the reverse: `opposite` flips a word to its antonym; `undo` names the word that takes
    /// back what a verb did. Only `opposite` may use antonyms, or "undo my last change" would turn into "first".
    private enum Style { case opposite, undo }

    /// The query with its inversion spelled out ("the opposite of indenting" -> "outdent"), or nil when the query
    /// holds no inversion marker with something to invert. `normalized` is `FuzzyMatcher.normalize` output.
    func rewrite(_ normalized: String) -> String? {
        let words = normalized.split(separator: " ").map(String.init)
        if let (range, style) = marker(in: words) {
            var rest = words
            rest.removeSubrange(range)
            if let out = invert(rest, nearest: range.lowerBound, style: style) { return out }
            // "the reverse of pasting": nothing has an opposite, so the reverse is an undo.
            return style == .opposite ? (["undo"] + rest).joined(separator: " ") : nil
        }
        // "I pasted it and need that reversed"
        if let index = words.lastIndex(where: ConceptLinkData.trailingMarkers.contains) {
            var rest = words
            rest.remove(at: index)
            return invert(rest, nearest: index, style: .undo)
        }
        return nil
    }

    /// Replaces the word nearest `position` (looking forward first, then back) that has a reverse.
    private func invert(_ words: [String], nearest position: Int, style: Style) -> String? {
        let order = Array(position..<words.count) + Array((0..<position).reversed())
        for index in order {
            if let reverse = reverse(of: words[index], style: style) {
                var out = words
                out[index] = reverse
                return out.joined(separator: " ")
            }
        }
        return nil
    }

    private func reverse(of word: String, style: Style) -> String? {
        for form in [word] + FuzzyMatcher.stems(word) + shortStems(word) {
            let base = ConceptLinkData.forms[form] ?? form
            // "The opposite of closing" is open; "put back what I closed" is reopen.
            if style == .opposite, let opposite = opposites[base] { return opposite }
            if let undone = ConceptLinkData.reversals[base] { return undone }
        }
        return nil
    }

    /// Base forms of short verbs the matcher's stemmer skips (hiding -> hide, hid is in `forms`).
    private func shortStems(_ word: String) -> [String] {
        var out = [String]()
        for suffix in ["ing", "ed", "s"] where word.count > suffix.count + 1 && word.hasSuffix(suffix) {
            let base = String(word.dropLast(suffix.count))
            out.append(contentsOf: [base, base + "e"])
        }
        return out
    }

    private func marker(in words: [String]) -> (Range<Int>, Style)? {
        var best: (range: Range<Int>, style: Style)?
        func look(_ phrases: [[String]], _ style: Style) {
            for phrase in phrases {
                guard words.count >= phrase.count else { continue }
                for start in 0...(words.count - phrase.count) where Array(words[start..<(start + phrase.count)]) == phrase {
                    // Earliest marker wins; at the same place the longer phrase.
                    if let current = best, current.range.lowerBound < start
                        || (current.range.lowerBound == start && current.range.count >= phrase.count) { continue }
                    best = (start..<(start + phrase.count), style)
                }
            }
        }
        look(ConceptLinkData.oppositeMarkers, .opposite)
        look(ConceptLinkData.undoMarkers, .undo)
        return best
    }
}
