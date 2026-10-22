import Foundation

/// Tracks which providers are being used right now, from log writes and the frontmost Cursor window.
public struct ActivityTracker: Sendable {
    public static let window: TimeInterval = 120

    private var lastWrite: [ProviderID: Date] = [:]
    private var cursorFrontmost = false
    private var cursorSince: Date?

    public init() {}

    public mutating func noteWrite(_ p: ProviderID, at: Date) {
        lastWrite[p] = max(lastWrite[p] ?? .distantPast, at)
    }

    /// While on, Cursor stays active; when turned off it expires 120 s after that moment.
    public mutating func setFrontmostCursor(_ on: Bool, at: Date) {
        if on {
            cursorFrontmost = true
            cursorSince = at
        } else {
            if cursorFrontmost { noteWrite(.cursor, at: at) }
            cursorFrontmost = false
            cursorSince = nil
        }
    }

    /// Active providers, most recent first.
    public func activeProviders(now: Date) -> [ProviderID] {
        var stamps: [(ProviderID, Date)] = lastWrite.compactMap { p, d in
            p == .cursor && cursorFrontmost ? nil : (d.addingTimeInterval(Self.window) > now ? (p, d) : nil)
        }
        if cursorFrontmost {
            stamps.append((.cursor, max(now, cursorSince ?? now)))
        }
        return stamps.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Earliest moment an active provider stops being active; an open-ended frontmost Cursor is ignored.
    public func nextExpiry(now: Date) -> Date? {
        lastWrite.compactMap { p, d -> Date? in
            if p == .cursor && cursorFrontmost { return nil }
            let end = d.addingTimeInterval(Self.window)
            return end > now ? end : nil
        }.min()
    }
}

public struct FetchSchedule: Sendable {
    public static let activeInterval: TimeInterval = 300
    public static let idleInterval: TimeInterval = 1800
    public static let panelFreshness: TimeInterval = 60
    public static let maxBackoff: TimeInterval = 3600

    public init() {}

    /// After failures the retry is `lastFailure + backoff` (from `now` when `lastFailure` is nil), so recomputing
    /// the schedule later never pushes a pending retry further out.
    public func nextFetch(lastSuccess: Date?, failures: Int, active: Bool, panelOpen: Bool, now: Date,
                          lastFailure: Date? = nil) -> Date {
        if failures >= 1 {
            let exponent = min(failures - 1, 20)
            let delay = min(Self.activeInterval * pow(2, Double(exponent)), Self.maxBackoff)
            return max((lastFailure ?? now).addingTimeInterval(delay), now)
        }
        let interval = active || panelOpen ? Self.activeInterval : Self.idleInterval
        return max((lastSuccess ?? now).addingTimeInterval(interval), now)
    }

    public func shouldFetchOnPanelOpen(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) > Self.panelFreshness
    }
}
