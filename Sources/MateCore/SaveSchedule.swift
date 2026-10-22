import Foundation

/// When a debounced save is due: `debounce` after the last change, but never later than `maxDelay` after the first
/// unsaved one. The index state (aggregates and log cursors, megabytes of JSON) has its own, much slower policy, so
/// an agent writing its log every few seconds does not re-encode the whole index after every batch; a crash then
/// loses at most a few minutes of indexing, which the saved cursors make Mate read again.
public struct SaveSchedule: Sendable {
    public struct Policy: Equatable, Sendable {
        public var debounce: TimeInterval
        public var maxDelay: TimeInterval
        public static let standard = Policy(debounce: 2, maxDelay: 60)
        public static let index = Policy(debounce: 30, maxDelay: 300)
    }

    public let policy: Policy
    public private(set) var firstPending: Date?

    public init(policy: Policy) {
        self.policy = policy
    }

    /// Notes an unsaved change at `now` and returns when the save is due.
    public mutating func noteChange(at now: Date) -> Date {
        let first = firstPending ?? now
        firstPending = first
        return min(now.addingTimeInterval(policy.debounce), first.addingTimeInterval(policy.maxDelay))
    }

    /// Everything pending was written.
    public mutating func reset() {
        firstPending = nil
    }

    /// Cursors last: a crash between writes must never leave cursors ahead of the aggregates they produced.
    public static func writeOrder(_ names: [String]) -> [String] {
        names.sorted { ($0 == "cursors" ? 1 : 0, $0) < ($1 == "cursors" ? 1 : 0, $1) }
    }
}
