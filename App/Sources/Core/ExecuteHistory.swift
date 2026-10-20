import Foundation

/// Which commands the user ran, how often and when. Local only: it never leaves the device and holds no
/// token, just rule text and counters. Keyed by rule text (unique in the feed) rather than command id, so
/// history survives a command-file edit that shifts line numbers. Pure value type; the clock is a parameter.
struct ExecuteHistory: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var count: Int
        var last: Date
    }

    /// Entries kept; the least recently run are dropped beyond this.
    static let maxEntries = 500

    private(set) var entries: [String: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    func entry(for rule: String) -> Entry? { entries[rule] }

    mutating func record(rule: String, at date: Date) {
        var entry = entries[rule] ?? Entry(count: 0, last: date)
        entry.count += 1
        entry.last = max(entry.last, date)
        entries[rule] = entry
        if entries.count > Self.maxEntries {
            let stale = entries.sorted { ($0.value.last, $0.key) < ($1.value.last, $1.key) }
                .prefix(entries.count - Self.maxEntries)
            for (key, _) in stale { entries.removeValue(forKey: key) }
        }
    }

    mutating func clear() {
        entries.removeAll()
    }

    /// Bounded ranking boost for `rule` at `now`: 0 for never run, at most `RankingBoost.maxHistory`.
    /// Recency halves every `halfLife`; frequency grows with log2(count) and saturates.
    func boost(for rule: String, now: Date) -> Double {
        guard let entry = entries[rule] else { return 0 }
        let age = max(0, now.timeIntervalSince(entry.last))
        let recency = RankingBoost.maxRecency * pow(0.5, age / RankingBoost.halfLife)
        let frequency = min(RankingBoost.maxFrequency, RankingBoost.frequencyStep * log2(1 + Double(entry.count)))
        return recency + frequency
    }
}

/// Ranking boosts, in the same units as `FuzzyMatcher.score`. Text tiers differ by 20 or more (whole word
/// 100, prefix 80, substring 40), so the sum of every boost stays under that: a boost reorders near-equal
/// matches and an empty query, but never lifts a worse text tier over a clearly better one.
enum RankingBoost {
    static let maxRecency = 4.0
    static let maxFrequency = 3.0
    static let frequencyStep = 1.0
    static let halfLife: TimeInterval = 3 * 24 * 3600
    static let app = 8.0
    static let tag = 4.0

    static var maxHistory: Double { maxRecency + maxFrequency }
    static var maxTotal: Double { app + maxHistory }
}

protocol ExecuteHistoryStoring: Sendable {
    func load() -> ExecuteHistory
    func save(_ history: ExecuteHistory)
}

struct UserDefaultsHistoryStore: ExecuteHistoryStoring, @unchecked Sendable {
    static let key = "executeHistory"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ExecuteHistory {
        guard let data = defaults.data(forKey: Self.key),
              let history = try? JSONDecoder().decode(ExecuteHistory.self, from: data) else { return ExecuteHistory() }
        return history
    }

    func save(_ history: ExecuteHistory) {
        if history.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
