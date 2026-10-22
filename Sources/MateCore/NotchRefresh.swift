import Foundation

/// Which store changes the notch has to look at. Closed, it only shows the pill (account, percent, pace, whether
/// an agent is active), so the token aggregates, which change with every batch of an agent's log, only matter
/// while the panel is open (its live-session row).
public enum NotchRefresh {
    public enum Change: Sendable {
        case accounts, snapshots, activeProvider, selection, paused, aggregates
    }

    public static func needed(for change: Change, panelOpen: Bool) -> Bool {
        change != .aggregates || panelOpen
    }

    /// FSEvents coalescing for the agents' logs: quick while the panel shows the live session, slow otherwise.
    public static func logLatency(panelOpen: Bool) -> TimeInterval { panelOpen ? 1 : 5 }
}
