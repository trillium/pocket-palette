import Foundation

struct CommandMatch: Equatable, Identifiable, Sendable {
    let command: PaletteCommand
    /// The phrase to send as-is, or nil when the user has to fill in a value.
    let spoken: String?
    /// Text score plus `contextBoost` and `historyBoost`.
    let score: Double
    var contextBoost: Double = 0
    var historyBoost: Double = 0

    var id: String { command.id }
}

/// How `CommandIndex.search` weighs things besides the text. The default is plain text matching.
struct SearchOptions: Sendable {
    /// Rank commands whose context names the frontmost app (or an active tag) above global ones.
    var contextBoost = false
    /// Hard filter: only commands whose context names the frontmost app.
    var appOnly = false
    var history = ExecuteHistory()
    var now = Date.distantPast
}

/// Searchable form of a command list: normalized strings are computed once, not per keystroke.
struct CommandIndex: Sendable {
    private struct Entry: Sendable {
        let command: PaletteCommand
        let spoken: String?
        let candidates: [String]
        /// What the rule leaves open (app name, free text, "that"): query words the rule lacks may fill it.
        let slot: FuzzyMatcher.Slot
    }

    private let entries: [Entry]
    /// Meaning-based fallback for queries the text matcher barely answers; nil (the default) means text matching only.
    private let semantic: SemanticRanker?
    /// Opposites, undo relations and concept words (see `ConceptLinks`); nil (the default) leaves ranking as it was.
    private let links: ConceptLinks?

    /// The fallback is asked for more when the text search finds fewer trusted hits than this.
    static let semanticTrigger = 3
    /// A text hit explaining at least this share of the query's words is trusted: it keeps its place ahead of the
    /// fallback. A hit below it is a guess (one shared word and a slot swallowing the rest) and competes with the
    /// fallback's hits on evidence instead.
    static let trustedCoverage = 0.5

    init(_ commands: [PaletteCommand], embedding: WordEmbedding? = nil, links: ConceptLinks? = nil) {
        self.links = links
        semantic = embedding.map { embedding in
            SemanticRanker(
                rules: commands.map(\.rule),
                contexts: commands.map { SemanticRanker.contextWords(apps: $0.apps, tags: $0.tags, context: $0.context) },
                embedding: embedding
            )
        }
        entries = commands.map { command in
            let spoken = RuleSpeller.spoken(command.rule)
            var candidates = [FuzzyMatcher.normalize(RuleSpeller.searchText(command.rule))]
            if let spoken { candidates.insert(FuzzyMatcher.normalize(spoken), at: 0) }
            return Entry(
                command: command, spoken: spoken, candidates: candidates, slot: Self.slot(of: command.rule, text: candidates.last ?? "")
            )
        }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Builds the semantic fallback's index ahead of the first query that needs it; a no-op without a fallback.
    func prepareSemantic() {
        semantic?.prepare()
    }

    private static func slot(of rule: String, text: String) -> FuzzyMatcher.Slot {
        if rule.trimmingCharacters(in: .whitespaces).hasSuffix("<app>") { return .app }
        if ["<text>", "<prose>", "<raw_prose>"].contains(where: rule.contains) { return .text }
        if let last = text.split(separator: " ").last, last == "that" || last == "this" { return .anaphor }
        return .none
    }

    private struct TextHit {
        var match: CommandMatch
        /// Share of the query's words the rule explains (see `FuzzyMatcher.Match.coverage`).
        var coverage: Double
    }

    /// Best-scoring first; ties go to the shorter rule, then alphabetical. An empty query ranks by boost only
    /// and otherwise keeps server order.
    func search(_ query: String, options: SearchOptions = SearchOptions(), limit: Int = 200) -> [CommandMatch] {
        let normalized = FuzzyMatcher.normalize(query)
        // "the opposite of X" and "put back what I closed" name the wrong rule: search the spelled-out inversion
        // first and keep the literal reading's hits after it.
        guard let rewritten = links?.rewrite(normalized), rewritten != normalized else {
            return rank(normalized, options: options, limit: limit)
        }
        let first = rank(rewritten, options: options, limit: limit)
        let seen = Set(first.map(\.id))
        return Array((first + rank(normalized, options: options, limit: limit).filter { !seen.contains($0.id) }).prefix(limit))
    }

    private func rank(_ normalized: String, options: SearchOptions, limit: Int) -> [CommandMatch] {
        let pool = options.appOnly ? entries.filter { $0.command.scope == .app } : entries
        var hits = textHits(normalized, in: pool, options: options, partial: false)
        // Nothing matched every word: rank by how many words matched instead of returning an empty list.
        if hits.isEmpty, !normalized.isEmpty {
            hits = textHits(normalized, in: pool, options: options, partial: true)
        }
        if normalized.isEmpty {
            // Stable: equal boosts keep server order.
            let ranked = hits.enumerated().sorted {
                $0.element.match.score != $1.element.match.score
                    ? $0.element.match.score > $1.element.match.score : $0.offset < $1.offset
            }
            return ranked.prefix(limit).map(\.element.match)
        }
        hits.sort {
            let (lhs, rhs) = ($0.match, $1.match)
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.command.rule.count != rhs.command.rule.count { return lhs.command.rule.count < rhs.command.rule.count }
            return (lhs.command.rule, lhs.command.id) < (rhs.command.rule, rhs.command.id)
        }
        let trusted = hits.filter { $0.coverage >= Self.trustedCoverage }
        guard semantic != nil, trusted.count < Self.semanticTrigger else { return Array(hits.map(\.match).prefix(limit)) }
        let guesses = hits.filter { $0.coverage < Self.trustedCoverage }
        return Array(blend(trusted: trusted, guesses: guesses, normalized, options).prefix(limit))
    }

    /// Trusted text hits first, then the guesses of both kinds ordered by how much evidence each has: a weak text
    /// hit (`guessEvidence`) against the fallback's similarity. A rule found by both keeps the better figure.
    private func blend(trusted: [TextHit], guesses: [TextHit], _ normalized: String, _ options: SearchOptions) -> [CommandMatch] {
        let taken = Set(trusted.map(\.match.id))
        var pool = [(match: CommandMatch, evidence: Double)]()
        var slot = [String: Int]()
        for guess in guesses where !taken.contains(guess.match.id) {
            slot[guess.match.id] = pool.count
            pool.append((guess.match, Self.guessEvidence(guess.coverage)))
        }
        for (match, similarity) in semanticHits(normalized, excluding: taken, options: options) {
            if let position = slot[match.id] {
                pool[position].evidence = max(pool[position].evidence, similarity)
            } else {
                pool.append((match, similarity))
            }
        }
        let rest = pool.enumerated().sorted {
            let (lhs, rhs) = ($0.element, $1.element)
            if lhs.evidence != rhs.evidence { return lhs.evidence > rhs.evidence }
            if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
            return $0.offset < $1.offset
        }
        return trusted.map(\.match) + rest.map(\.element.match)
    }

    /// Evidence for a text hit that explains little of the query: always below a real semantic match.
    private static func guessEvidence(_ coverage: Double) -> Double { 0.45 + 0.3 * coverage }

    /// Fallback hits with their similarity (0...1). Context and history boosts order equals but never lift a hit
    /// over a better-matching one.
    private func semanticHits(
        _ normalized: String, excluding taken: Set<String>, options: SearchOptions
    ) -> [(match: CommandMatch, similarity: Double)] {
        guard let semantic else { return [] }
        var out = [(match: CommandMatch, similarity: Double)]()
        for (rule, score) in semantic.rank(FuzzyMatcher.queryTokens(normalized), links: links?.alternatives ?? [:]) {
            let entry = entries[rule]
            if taken.contains(entry.command.id) || (options.appOnly && entry.command.scope != .app) { continue }
            let context = options.contextBoost ? Self.contextBoost(entry.command.scope) : 0
            let history = options.history.boost(for: entry.command.rule, now: options.now)
            out.append((CommandMatch(
                command: entry.command, spoken: entry.spoken, score: score * 50 + context + history,
                contextBoost: context, historyBoost: history
            ), score))
        }
        return out.sorted { $0.match.score > $1.match.score }
    }

    private func textHits(_ normalized: String, in pool: [Entry], options: SearchOptions, partial: Bool) -> [TextHit] {
        var hits = [TextHit]()
        for entry in pool {
            let text: Double
            var coverage = 1.0
            if normalized.isEmpty {
                text = 0
            } else {
                let best = entry.candidates
                    .compactMap {
                        FuzzyMatcher.match(
                            normalizedQuery: normalized, inNormalized: $0,
                            slot: entry.slot, partial: partial, links: links?.alternatives ?? [:]
                        )
                    }
                    .max { $0.score < $1.score }
                guard let best else { continue }
                text = best.score
                coverage = best.coverage
            }
            let context = options.contextBoost ? Self.contextBoost(entry.command.scope) : 0
            let history = options.history.boost(for: entry.command.rule, now: options.now)
            hits.append(TextHit(match: CommandMatch(
                command: entry.command, spoken: entry.spoken, score: text + context + history,
                contextBoost: context, historyBoost: history
            ), coverage: coverage))
        }
        return hits
    }

    private static func contextBoost(_ scope: PaletteCommand.Scope) -> Double {
        switch scope {
        case .app: RankingBoost.app
        case .tag: RankingBoost.tag
        case .global: 0
        }
    }
}
