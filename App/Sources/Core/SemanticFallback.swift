import Accelerate
import Foundation
import NaturalLanguage

/// Word vectors for the semantic fallback. A protocol so tests can use a tiny hand-made table instead of the
/// system model (whose assets differ per OS version and may be missing in a simulator).
protocol WordEmbedding: Sendable {
    func vector(for word: String) -> [Float]?
}

/// Apple's built-in English word embedding (`NLEmbedding`, 300 dimensions). On-device only: the model ships with the
/// OS, there is no network call, and the query never leaves the phone. Loaded on first use; nil model means no fallback.
final class SystemWordEmbedding: WordEmbedding, @unchecked Sendable {
    static let shared = SystemWordEmbedding()

    private let lock = NSLock()
    private var model: NLEmbedding?
    private var loaded = false

    /// False when the OS has no English word embedding; the fallback then returns nothing.
    var isAvailable: Bool { lock.withLock { load() != nil } }

    func vector(for word: String) -> [Float]? {
        lock.withLock { load()?.vector(for: word).map { $0.map(Float.init) } }
    }

    private func load() -> NLEmbedding? {
        if !loaded {
            model = NLEmbedding.wordEmbedding(for: .english)
            loaded = true
        }
        return model
    }
}

/// Meaning-based retrieval for long conversational queries ("get rid of the terminal output"). It only ranks: the
/// rules, the query and the results never leave the device, and it never creates or edits a command.
///
/// Each rule is expanded into its spoken variants ("tab (new|open)" -> "tab new", "tab open"). A variant scores
/// 0.7 x (how well each of its words is covered by the closest query word) + 0.3 x (how well each query word is
/// covered by the closest variant word); word closeness is the cosine of the embedding vectors, 1 for the same word.
/// A rule's score is its best variant. Built lazily on the first fallback query, so typing that the strict matcher
/// answers never pays for it.
final class SemanticRanker: @unchecked Sendable {
    /// Rules whose best variant scores below this are not returned.
    static let minimumScore = 0.4
    static let maxResults = 6
    /// A word the matcher's tables offer for a query word counts this much of an exact match.
    static let synonymWeight: Float = 0.9
    static let maxVariantsPerRule = 16
    private static let ruleWeight = 0.7

    private let rules: [String]
    /// Per rule: words for where it applies (app names and what kind of app, tags, the defining file's name).
    private let contexts: [[String]]
    private let embedding: WordEmbedding
    private let lock = NSLock()
    private var built: Built?

    private struct Built {
        /// Per rule: its variants as vocabulary indices.
        var variants: [[[Int]]] = []
        /// Per rule: its context words as vocabulary indices.
        var contexts: [[Int]] = []
        var vocabulary: [String] = []
        var index: [String: Int] = [:]
        /// Unit vectors of the vocabulary, one row of `dimension` floats per word (zeros for words the embedding lacks).
        var matrix: [Float] = []
        var dimension = 0
    }

    /// `contexts[i]` are context words for `rules[i]` (see `contextWords`); missing entries mean none.
    init(rules: [String], contexts: [[String]] = [], embedding: WordEmbedding) {
        self.rules = rules
        self.contexts = rules.indices.map { $0 < contexts.count ? contexts[$0] : [] }
        self.embedding = embedding
    }

    /// Words that say where a command applies: the app names, what kind of app each is ("WezTerm" is a terminal), the
    /// tags and the name of the defining file. A query about "the terminal" then favours the terminal's commands.
    static func contextWords(apps: [String], tags: [String], context: String) -> [String] {
        var words = [String]()
        func add(_ text: String) {
            for word in FuzzyMatcher.normalize(text).split(separator: " ").map(String.init)
            where word.count >= 3 && !words.contains(word) && !contextNoise.contains(word) {
                words.append(word)
                for kind in MatcherLexicon.appKinds[word] ?? [] where !words.contains(kind) { words.append(kind) }
            }
        }
        apps.forEach(add)
        tags.forEach { add($0.split(separator: ".").last.map(String.init) ?? $0) }
        if !apps.isEmpty { add(((context as NSString).lastPathComponent as NSString).deletingPathExtension) }
        return words
    }

    private static let contextNoise: Set<String> = ["app", "apps", "exe", "the", "user", "com", "org"]
    /// What a matching context word adds to a rule's score at most, when a query word equals it.
    static let contextWeight: Float = 0.15

    /// Loads the model and indexes the rules now, so the first fallback query does not pay for it (about 0.1 s at
    /// 800 rules). Safe from any thread.
    func prepare() {
        _ = lock.withLock { build() }
    }

    /// Rule indices with scores in 0...1, best first, for rules scoring at least `minimumScore`. Empty when the
    /// query has no usable words.
    func rank(_ query: [String], links: [String: [String]] = [:]) -> [(rule: Int, score: Double)] {
        Array(rankAll(query, links: links).filter { $0.score >= Self.minimumScore }.prefix(Self.maxResults))
    }

    /// Every rule with its score, best first, no cut-off. `links` are extra stand-in words per query word.
    func rankAll(_ query: [String], links: [String: [String]] = [:]) -> [(rule: Int, score: Double)] {
        let own = query.filter { !Self.stopwords.contains($0) }
        guard !own.isEmpty else { return [] }
        let model = lock.withLock { build() }
        guard !model.vocabulary.isEmpty else { return [] }
        // The matcher's word tables stand in for words the embedding knows little about ("bigger" -> zoom in).
        var words = own
        var scale = [Float](repeating: 1, count: own.count)
        for word in own {
            for alt in (MatcherLexicon.thesaurus[word] ?? []) + (links[word] ?? []) where !words.contains(alt) {
                words.append(alt)
                scale.append(Self.synonymWeight)
            }
        }
        var closeness = closenessTable(words, model)
        let size = model.vocabulary.count
        for (row, factor) in scale.enumerated() where factor != 1 {
            for entry in 0..<size { closeness[row * size + entry] *= factor }
        }
        var scored = [(rule: Int, score: Double)]()
        for (rule, variants) in model.variants.enumerated() {
            var best = variants.map { Self.score($0, closeness, size: size, words: words.count) }.max() ?? 0
            var context: Float = 0
            for entry in model.contexts[rule] {
                for row in 0..<words.count { context = max(context, closeness[row * size + entry]) }
            }
            best += Self.contextWeight * context
            scored.append((rule, Double(best)))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.rule < $1.rule }
        return scored
    }

    /// `table[word * size + entry]`: every query word against every vocabulary word, one matrix product per word.
    private func closenessTable(_ words: [String], _ model: Built) -> [Float] {
        let size = model.vocabulary.count
        var table = [Float](repeating: 0, count: words.count * size)
        for (row, word) in words.enumerated() {
            if let vector = embed(word), vector.count == model.dimension {
                table.withUnsafeMutableBufferPointer { out in
                    vDSP_mmul(
                        model.matrix, 1, vector, 1, out.baseAddress! + row * size, 1,
                        vDSP_Length(size), 1, vDSP_Length(model.dimension)
                    )
                }
                for entry in 0..<size { table[row * size + entry] = max(0, table[row * size + entry]) }
            }
            if let same = model.index[word] { table[row * size + same] = 1 }
        }
        return table
    }

    /// 0.7 x (mean over the variant's words of the closest query word) + 0.3 x (mean of the variant-sized best share of
    /// query words, each by its closest variant word). Taking only the best few query words keeps a long query's
    /// extra words from diluting a good match.
    private static func score(_ variant: [Int], _ table: [Float], size: Int, words: Int) -> Float {
        var coverage: Float = 0
        for entry in variant {
            var closest: Float = 0
            for row in 0..<words { closest = max(closest, table[row * size + entry]) }
            coverage += closest
        }
        var used = [Float]()
        for row in 0..<words {
            var closest: Float = 0
            for entry in variant { closest = max(closest, table[row * size + entry]) }
            used.append(closest)
        }
        used.sort(by: >)
        let share = used.prefix(max(variant.count, 1))
        return Float(ruleWeight) * coverage / Float(variant.count) + Float(1 - ruleWeight) * share.reduce(0, +) / Float(share.count)
    }

    private func embed(_ word: String) -> [Float]? {
        embedding.vector(for: word).flatMap(Self.unit)
    }

    private func build() -> Built {
        if let built { return built }
        var model = Built()
        var rows = [[Float]?]()
        func intern(_ word: String) -> Int {
            if let known = model.index[word] { return known }
            model.index[word] = model.vocabulary.count
            model.vocabulary.append(word)
            let vector = embed(word)
            rows.append(vector)
            if model.dimension == 0, let vector { model.dimension = vector.count }
            return model.vocabulary.count - 1
        }
        for (position, rule) in rules.enumerated() {
            model.contexts.append(contexts[position].map(intern))
            let variants = Self.variants(of: rule).map { variant in
                variant.map(intern)
            }
            model.variants.append(variants)
        }
        for row in rows {
            if let row, row.count == model.dimension {
                model.matrix.append(contentsOf: row)
            } else {
                model.matrix.append(contentsOf: [Float](repeating: 0, count: model.dimension))
            }
        }
        built = model
        return model
    }

    private static func unit(_ vector: [Float]) -> [Float]? {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : nil
    }

    /// Function words that carry no command meaning, on top of the matcher's own filler list.
    private static let stopwords: Set<String> = [
        "so", "now", "is", "are", "was", "what", "on", "in", "at", "some", "one", "be", "do", "with", "or", "let",
        "us", "than", "as", "into", "from", "by", "its", "our", "there", "how", "of", "if", "when", "while",
        // Light verbs, vague nouns and contraction stubs: they say nothing about which command is meant.
        "make", "makes", "get", "gets", "got", "take", "put", "need", "needs", "use", "using", "used", "have", "has",
        "had", "see", "know", "way", "thing", "things", "something", "anything", "right", "already", "anymore",
        "still", "really", "very", "too", "also", "even", "though", "about", "little", "bit", "here", "where",
        "which", "any", "s", "m", "t", "d", "re", "ll", "ve", "don", "doesn", "didn", "isn", "can", "will",
    ]

    /// The spoken variants of a rule, as lists of words: groups `(a|b)`, optionals `[x]` and `(x)?` expanded,
    /// captures and lists dropped, filler words dropped. A rule with more than `maxVariantsPerRule` variants keeps
    /// the first ones.
    static func variants(of rule: String) -> [[String]] {
        var seen = Set<[String]>()
        var out = [[String]]()
        for text in expand(stripCaptures(rule)) {
            var words = FuzzyMatcher.normalize(text).split(separator: " ").map(String.init)
            let kept = words.filter { !stopwords.contains($0) && !FuzzyMatcher.isFiller($0) }
            if !kept.isEmpty { words = kept }
            if !words.isEmpty, seen.insert(words).inserted { out.append(words) }
        }
        return out
    }

    private static func stripCaptures(_ rule: String) -> String {
        var out = ""
        var depth = 0
        for char in rule {
            switch char {
            case "<", "{": depth += 1
            case ">", "}": depth = max(0, depth - 1)
            default: if depth == 0 { out.append(char) }
            }
        }
        return out
    }

    /// Expands the innermost group first, so nesting works; stops growing at the variant cap.
    private static func expand(_ text: String) -> [String] {
        let chars = Array(text)
        guard let close = chars.firstIndex(where: { $0 == ")" || $0 == "]" }),
              let open = chars[..<close].lastIndex(where: { $0 == "(" || $0 == "[" }) else {
            return [text.replacingOccurrences(of: "[()\\[\\]*+?^$]", with: " ", options: .regularExpression)]
        }
        var after = close + 1
        var optional = chars[close] == "]"
        if after < chars.count, "?*".contains(chars[after]) {
            optional = true
            after += 1
        }
        var options = String(chars[(open + 1)..<close]).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if optional { options.append("") }
        let head = String(chars[..<open])
        let tail = String(chars[after...])
        var out = [String]()
        for option in options {
            out.append(contentsOf: expand(head + option + tail))
            if out.count >= maxVariantsPerRule { break }
        }
        return Array(out.prefix(maxVariantsPerRule))
    }
}
