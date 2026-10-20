import Foundation

/// Poll delay that doubles after each failure up to `maximum` and snaps back on success.
struct Backoff: Equatable, Sendable {
    let base: TimeInterval
    let maximum: TimeInterval
    private(set) var current: TimeInterval

    init(base: TimeInterval = 1.5, maximum: TimeInterval = 20) {
        self.base = base
        self.maximum = maximum
        current = base
    }

    mutating func success() {
        current = base
    }

    /// Returns the delay to wait now, then grows the next one.
    mutating func failure() -> TimeInterval {
        let delay = current
        current = min(maximum, current * 2)
        return delay
    }
}
