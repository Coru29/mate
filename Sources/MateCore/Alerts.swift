import Foundation

public struct AlertEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case threshold(Int)
        case reset
    }

    public var kind: Kind
    public var accountID: String
    public var window: WindowKind
    public var percent: Double
    public var resetsAt: Date?

    public init(kind: Kind, accountID: String, window: WindowKind, percent: Double, resetsAt: Date?) {
        self.kind = kind
        self.accountID = accountID
        self.window = window
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// Decides which alerts a new snapshot triggers. Remembers, per (account, window), the highest
/// threshold fired in the current period so each crossing alerts once.
public struct AlertEngine: Codable, Sendable {
    private struct Entry: Codable, Sendable {
        var highestFired: Int
        var resetsAt: Date?
        var lastPercent: Double
        var peakPercent: Double
    }

    /// Lowest usage a period must have reached for its reset to be worth an alert.
    private static let resetAlertFloor = 75.0
    private static let periodShift: TimeInterval = 60
    private static let dropWithoutResetDate = 30.0

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func evaluate(_ snapshot: UsageSnapshot, thresholds: [Int]) -> [AlertEvent] {
        var events: [AlertEvent] = []
        let sorted = thresholds.sorted()
        for window in snapshot.windows {
            let key = "\(snapshot.accountID)|\(Self.label(window.kind))"
            var entry = entries[key] ?? Entry(highestFired: 0, resetsAt: window.resetsAt,
                                              lastPercent: window.usedPercent, peakPercent: 0)
            func event(_ kind: AlertEvent.Kind) -> AlertEvent {
                AlertEvent(kind: kind, accountID: snapshot.accountID, window: window.kind,
                           percent: window.usedPercent, resetsAt: window.resetsAt)
            }

            if entries[key] != nil, Self.periodChanged(entry, window) {
                if entry.peakPercent >= Self.resetAlertFloor { events.append(event(.reset)) }
                entry.highestFired = 0
                entry.peakPercent = 0
            }

            if let top = sorted.last(where: { Double($0) <= window.usedPercent && $0 > entry.highestFired }) {
                events.append(event(.threshold(top)))
                entry.highestFired = top
            }

            entry.resetsAt = window.resetsAt
            entry.lastPercent = window.usedPercent
            entry.peakPercent = max(entry.peakPercent, window.usedPercent)
            entries[key] = entry
        }
        return events
    }

    /// Forgets every window of a deleted account, so the state does not outlive it. Keys are
    /// "<account>|<window key>" and window keys hold no "|", so another account whose id merely starts with
    /// `accountID` keeps its entries.
    public mutating func prune(accountID: String) {
        let prefix = accountID + "|"
        entries = entries.filter { key, _ in
            !(key.hasPrefix(prefix) && !key.dropFirst(prefix.count).contains("|"))
        }
    }

    private static func periodChanged(_ entry: Entry, _ window: LimitWindow) -> Bool {
        if let old = entry.resetsAt, let new = window.resetsAt {
            return new.timeIntervalSince(old) > periodShift
        }
        if window.resetsAt == nil {
            return entry.lastPercent - window.usedPercent > dropWithoutResetDate
        }
        return false
    }

    private static func label(_ kind: WindowKind) -> String { kind.key }
}
