import Foundation

public enum CodexUsage {
    /// A window of 6 h or less is the session window, anything longer the weekly one.
    private static let sessionMax: TimeInterval = 21_600

    private static func kind(duration: TimeInterval?, fallback: WindowKind) -> WindowKind {
        guard let d = duration else { return fallback }
        return d <= sessionMax ? .session : .weekly
    }

    /// `rate_limit.primary_window`/`secondary_window` `{used_percent, limit_window_seconds, reset_at | reset_after_seconds}`.
    public static func windows(from data: Data, now: Date) throws -> [LimitWindow] {
        let root = try J.object(data)
        guard let rl = try J.dict(root, "rate_limit") else { throw ParseError.malformed("rate_limit missing") }
        var out: [LimitWindow] = []
        for (key, fallback) in [("primary_window", WindowKind.session), ("secondary_window", .weekly)] {
            guard let w = try J.dict(rl, key), let used = try J.double(w, "used_percent") else { continue }
            let duration = try J.double(w, "limit_window_seconds")
            let resets = try J.double(w, "reset_at").map { Date(timeIntervalSince1970: $0) }
                ?? J.double(w, "reset_after_seconds").map { now.addingTimeInterval($0) }
            out.append(LimitWindow(kind: kind(duration: duration, fallback: fallback), usedPercent: used,
                                   resetsAt: resets, duration: duration))
        }
        return out
    }

    /// The `rate_limits` object of a `token_count` event in the session logs:
    /// `primary`/`secondary` `{used_percent, window_minutes, resets_at (epoch s) | resets_in_seconds}`.
    public static func windows(fromLogRateLimits data: Data, now: Date) throws -> [LimitWindow] {
        let root = try J.object(data)
        guard root["primary"] != nil || root["secondary"] != nil else { throw ParseError.malformed("no rate limits") }
        var out: [LimitWindow] = []
        for (key, fallback) in [("primary", WindowKind.session), ("secondary", .weekly)] {
            guard let w = try J.dict(root, key), let used = try J.double(w, "used_percent") else { continue }
            let duration = try J.double(w, "window_minutes").map { $0 * 60 }
            let resets = try J.double(w, "resets_at").map { Date(timeIntervalSince1970: $0) }
                ?? J.double(w, "resets_in_seconds").map { now.addingTimeInterval($0) }
            out.append(LimitWindow(kind: kind(duration: duration, fallback: fallback), usedPercent: used,
                                   resetsAt: resets, duration: duration))
        }
        return out
    }
}
