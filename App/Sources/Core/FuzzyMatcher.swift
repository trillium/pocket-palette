import Foundation

/// Ranked fuzzy matching: every query token must match; whole-word hits beat prefixes beat
/// substrings beat scattered letters. Pure functions, no UI types.
enum FuzzyMatcher {
    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}", "`"]

    /// The one query/rule normalizer: folds case and diacritics, drops apostrophes so "don't" is one word ("dont"),
    /// turns every other non-letter/digit (punctuation, symbols, emoji) into a word break, and collapses spaces.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let spaced = folded.compactMap { char -> Character? in
            if apostrophes.contains(char) { return nil }
            return char.isLetter || char.isNumber ? char : " "
        }
        return String(spaced).split(separator: " ").joined(separator: " ")
    }

    /// Higher is better; nil when the candidate does not match. An empty query matches everything with 0.
    static func score(query: String, in candidate: String) -> Double? {
        score(normalizedQuery: normalize(query), inNormalized: normalize(candidate))
    }

    /// `slot`: what the rule leaves open (see `Slot`); query words the rule lacks may be the slot's value, not a miss.
    /// `partial`: fallback pass for when nothing matched strictly; unmatched words only cost points, as long
    /// as at least half of the significant words match as whole words, prefixes, synonyms or stems.
    static func score(
        normalizedQuery query: String, inNormalized candidate: String,
        slot: Slot = .none, partial: Bool = false
    ) -> Double? {
        match(normalizedQuery: query, inNormalized: candidate, slot: slot, partial: partial)?.score
    }

    /// A text match: its score, and how much of the query it explains.
    struct Match: Sendable {
        let score: Double
        /// 0...1: the share of the query's significant words that matched a word of the rule (whole word, prefix of
        /// 3+ letters, synonym or stem). Words only taken in by an open slot, or matched as scattered letters, do not
        /// count. A hit that explains few of the query's words is a guess, whatever its score.
        let coverage: Double
    }

    /// `links`: extra stand-in words per query word (`ConceptLinks.alternatives`), tried like thesaurus entries.
    static func match(
        normalizedQuery query: String, inNormalized candidate: String,
        slot: Slot = .none, partial: Bool = false, links: [String: [String]] = [:]
    ) -> Match? {
        guard !query.isEmpty else { return Match(score: 0, coverage: 1) }
        guard !candidate.isEmpty else { return nil }
        let words = candidate.split(separator: " ").map(String.init)
        let tokens = queryTokens(query)
        var counts = tally(tokens, words: words, full: candidate, links: links)
        absorb(into: &counts, slot: slot)
        // A single whole-word hit must not carry a multi-word query: at least half of the words have to match
        // strongly, or "scroll down to the end" would rank "volume down" for the lone word "down".
        guard tokens.count < 2 || counts.strong * 2 >= tokens.count else { return nil }
        if partial {
            guard tokens.count >= 2, counts.solid * 2 >= tokens.count, !counts.fragmentMissed else { return nil }
        } else {
            // Spoken queries carry words the rule never contains ("turn the volume up"): with three or more
            // significant words one may go unmatched, at a price that keeps full matches ahead.
            guard counts.missed == 0 || (tokens.count >= 3 && counts.missed == 1 && counts.total > 0) else { return nil }
        }
        var total = counts.total - Double(counts.missed) * missPenalty
        if candidate == query {
            total += 200
        } else if candidate.hasPrefix(query) {
            total += 100
        }
        let coverage = Double(counts.matched) / Double(max(tokens.count, 1))
        return Match(score: total - Double(candidate.count) * 0.1, coverage: coverage)
    }

    /// What a rule leaves open for the user to say, derived from its captures and its last word.
    enum Slot: Sendable {
        case none
        /// Ends in `<app>`: one trailing unmatched query word is the app name ("focus chrome").
        case app
        /// Holds a free-text capture (`<text>`): the words after the matched verb are the text.
        case text
        /// Ends in "that"/"this" ("undo that"): the rule's object is whatever the query describes after the verb.
        case anaphor
    }

    private struct Tally {
        var total = 0.0
        var missed = 0
        var strong = 0
        /// Words matched by a word of the rule itself (not taken in by a slot, not scattered letters).
        var matched = 0
        /// Strong matches that are not a bare prefix: a prefix may only be a half-typed word.
        var solid = 0
        /// An unmatched word of one or two letters is a half-typed word, not a word the rules lack.
        var fragmentMissed = false
        var lastMissed = false
        /// Per query word, in order: how it matched, nil when it did not.
        var kinds = [Kind?]()
        var tokens = [String]()
    }

    private static func tally(_ tokens: [String], words: [String], full: String, links: [String: [String]]) -> Tally {
        var tally = Tally()
        tally.tokens = tokens
        for token in tokens {
            if let hit = resolve(token, words: words, full: full, links: links) {
                tally.total += hit.score
                if hit.kind != .loose { tally.strong += 1; tally.matched += 1 }
                if hit.kind == .whole || hit.kind == .derived { tally.solid += 1 }
                tally.lastMissed = false
                tally.kinds.append(hit.kind)
            } else {
                tally.missed += 1
                tally.lastMissed = true
                if token.count <= 2 { tally.fragmentMissed = true }
                tally.kinds.append(nil)
            }
        }
        return tally
    }

    /// Lets a rule's open slot take query words the rule lacks, at a small price each. The slot's value comes after
    /// the command word, so a strong match must come first; a bare app name or a bare "that" is not a command.
    private static func absorb(into counts: inout Tally, slot: Slot) {
        guard slot != .none, counts.missed > 0,
              let first = counts.kinds.firstIndex(where: { $0 != nil }),
              let kind = counts.kinds[first], kind != .loose else { return }
        var free = Array(counts.kinds.indices.filter { $0 > first && counts.kinds[$0] == nil })
        if slot == .app { free = counts.lastMissed ? Array(free.suffix(1)) : [] }
        guard !free.isEmpty else { return }
        for index in free {
            counts.kinds[index] = .derived
            counts.missed -= 1
            counts.strong += 1
            counts.solid += 1
            counts.total -= slot == .app ? captureCost : wordCaptureCost
        }
        counts.lastMissed = false
        counts.fragmentMissed = zip(counts.kinds, counts.tokens).contains { $0 == nil && $1.count <= 2 }
    }

    private static let missPenalty = 45.0
    private static let synonymPenalty = 10.0
    private static let stemPenalty = 5.0
    private static let hintBonus = 8.0
    private static let captureCost = 20.0
    private static let wordCaptureCost = 12.0

    /// Words people say around a command rather than in it. Dropped from the query unless nothing else is left.
    private static let fillers: Set<String> = [
        "a", "an", "the", "to", "of", "my", "me", "please", "can", "could", "you", "your", "i", "would",
        "like", "want", "for", "this", "that", "it", "and", "then", "just", "hey",
    ]

    static func isFiller(_ word: String) -> Bool { fillers.contains(word) }

    /// Multi-word expressions that mean one command verb. Phrasal verbs and fixed idioms, not command names.
    private static let phrases: [(words: [String], verb: String)] = [
        (["get", "rid", "of"], "remove"), (["take", "away"], "remove"), (["go", "away"], "remove"), (["bring", "back"], "restore"),
        (["bring", "up"], "open"), (["pull", "up"], "open"), (["look", "up"], "search"),
        (["take", "me", "to"], "go"), (["bring", "me", "to"], "go"), (["hang", "up"], "end"), (["throw", "away"], "remove"),
        (["clean", "up"], "clear"), (["tidy", "up"], "format"), (["fire", "up"], "open"),
        (["turn", "on"], "start"), (["switch", "on"], "start"), (["turn", "off"], "stop"), (["switch", "off"], "stop"),
    ]

    /// "turn the camera on": a trailing particle splits the phrasal verb from its verb.
    private static let particles: [String: [String: String]] = [
        "on": ["turn": "start", "switch": "start"], "off": ["turn": "stop", "switch": "stop"],
    ]

    /// Replaces phrasal verbs by their single verb, so "get rid of" is looked up as "remove".
    static func collapsePhrases(_ words: [String]) -> [String] {
        var out = [String]()
        var index = 0
        outer: while index < words.count {
            for phrase in phrases where words[index...].starts(with: phrase.words) {
                out.append(phrase.verb)
                index += phrase.words.count
                continue outer
            }
            out.append(words[index])
            index += 1
        }
        if let particle = out.last, let verbs = particles[particle], out.count >= 3,
           let verbIndex = out.dropLast().prefix(3).firstIndex(where: { verbs[$0] != nil }) {
            out[verbIndex] = verbs[out[verbIndex]] ?? out[verbIndex]
            out.removeLast()
        }
        return out
    }

    /// Significant words of a normalized query: phrasal verbs are collapsed, fillers and bare numbers (they fill
    /// captures) are dropped.
    static func queryTokens(_ query: String) -> [String] {
        let all = collapsePhrases(query.split(separator: " ").map(String.init))
        let kept = all.filter { !fillers.contains($0) && !$0.allSatisfy(\.isNumber) }
        return kept.isEmpty ? all : kept
    }

    /// Plausible base forms of an inflected word, most likely first: plural, -ing, -ed, -er, adverb, re- prefix.
    static func stems(_ token: String) -> [String] {
        var out = [String]()
        func add(_ stem: String) {
            if stem.count >= 3, stem != token, !out.contains(stem) { out.append(stem) }
        }
        if token.count > 3, token.hasSuffix("s"), !token.hasSuffix("ss") {
            add(token.hasSuffix("ies") ? String(token.dropLast(3)) + "y" : String(token.dropLast()))
        }
        for suffix in ["ing", "ed", "er"] where token.count > suffix.count + 3 && token.hasSuffix(suffix) {
            let base = String(token.dropLast(suffix.count))
            add(base)
            add(base + "e")
            if let last = base.last, base.dropLast().last == last { add(String(base.dropLast())) }
        }
        if token.count > 5, token.hasSuffix("ly") {
            add(String(token.dropLast(2)))
        }
        if token.count > 4, token.hasPrefix("re") { add(String(token.dropFirst(2))) }
        return out
    }

    private enum Kind { case whole, prefix, derived, loose }

    /// Best score for one query word and how it matched: a whole word, a word prefix, a synonym or stem
    /// (`derived`), or only `loose` (substring or scattered letters). nil when nothing matches.
    private static func resolve(
        _ token: String, words: [String], full: String, links: [String: [String]]
    ) -> (score: Double, kind: Kind)? {
        if let part = wordScore(token, words: words) { return (part.score, part.whole ? .whole : .prefix) }
        var best: Double?
        var matchedAlts = 0
        for alt in (MatcherLexicon.thesaurus[token] ?? []) + (links[token] ?? []) {
            if let part = wordScore(alt, words: words, prefix: alt.count >= 3) {
                best = max(best ?? 0, part.score - synonymPenalty)
                matchedAlts += 1
            }
        }
        // Stand-ins that come as a set ("louder" -> volume, up) fit a rule better the more of the set it has.
        if matchedAlts > 1, let current = best { best = current + Double(matchedAlts - 1) * hintBonus }
        for stem in stems(token) {
            if let part = wordScore(stem, words: words, prefix: stem.count >= 4) {
                best = max(best ?? 0, part.score - stemPenalty)
            }
            for alt in (MatcherLexicon.thesaurus[stem] ?? []) + (links[stem] ?? []) {
                if let part = wordScore(alt, words: words, prefix: alt.count >= 3) {
                    best = max(best ?? 0, part.score - synonymPenalty - stemPenalty)
                }
            }
        }
        if let best { return (best, .derived) }
        if let part = looseScore(token, full: full) { return (part, .loose) }
        return nil
    }

    private static func wordScore(_ token: String, words: [String], prefix: Bool = true) -> (score: Double, whole: Bool)? {
        var best: (score: Double, whole: Bool)?
        for (index, word) in words.enumerated() {
            let penalty = Double(min(index, 15)) * 2
            if word == token {
                if 100 - penalty > best?.score ?? 0 { best = (100 - penalty, true) }
            } else if prefix, word.hasPrefix(token), 80 - penalty > best?.score ?? 0 {
                best = (80 - penalty, false)
            }
        }
        return best
    }

    private static func looseScore(_ token: String, full: String) -> Double? {
        if full.contains(token) { return 40 }
        return subsequenceScore(token, in: full)
    }

    /// Letters of `token` in order somewhere in `text`; consecutive runs and word starts score more.
    private static func subsequenceScore(_ token: String, in text: String) -> Double? {
        var score = 5.0
        var previous: String.Index?
        var cursor = text.startIndex
        for letter in token {
            guard let hit = text[cursor...].firstIndex(of: letter) else { return nil }
            if let previous, text.index(after: previous) == hit {
                score += 3
            } else if hit == text.startIndex || text[text.index(before: hit)] == " " {
                score += 4
            }
            previous = hit
            cursor = text.index(after: hit)
        }
        return min(score, 30)
    }
}
