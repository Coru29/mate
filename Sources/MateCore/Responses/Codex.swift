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

public enum CodexTokenResponse {
    /// `{access_token, refresh_token?, id_token?}` from `auth.openai.com/oauth/token` (exchange or refresh). Missing
    /// fields keep `previous`'s; the expiry comes from the access token's `exp`, the account id from the id_token.
    public static func tokens(from data: Data, previous: OAuthTokens) throws -> OAuthTokens {
        let root = try J.object(data)
        guard let access = try J.string(root, "access_token"), !access.isEmpty else {
            throw ParseError.malformed("access_token missing")
        }
        var t = previous
        t.accessToken = access
        t.expiresAt = JWT.expiry(access)
        if let r = try J.string(root, "refresh_token"), !r.isEmpty { t.refreshToken = r }
        if let id = try J.string(root, "id_token"), !id.isEmpty {
            t.extra["id_token"] = id
            if let identity = CodexIdentity.from(idToken: id) { t.extra["account_id"] = identity.accountID }
        }
        return t
    }
}

public enum CodexLogTail {
    /// The windows of the last `token_count` event with `rate_limits` in `tail` (the end of a rollout file; a
    /// partial first line is ignored). Nil when there is none.
    public static func latestRateLimits(in tail: Data) -> [LimitWindow]? {
        let lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
        for line in lines.reversed() {
            var parser = CodexLogParser()
            if let w = parser.parse(Data(line), sessionID: "").rateLimits, !w.isEmpty { return w }
        }
        return nil
    }

    /// The log's windows as they stand `now`, for the usage endpoint's fallback: a window whose reset time passed is
    /// back at 0 % (with no reset time), and a log last written longer ago than its longest window (7 days when no
    /// window says) describes nothing current, so there is no fallback (nil).
    public static func fallback(_ windows: [LimitWindow], fileModified: Date, now: Date) -> [LimitWindow]? {
        guard !windows.isEmpty else { return nil }
        let longest = windows.compactMap(\.duration).max() ?? 604_800
        guard now.timeIntervalSince(fileModified) <= longest else { return nil }
        return windows.map { w in
            guard let r = w.resetsAt, r <= now else { return w }
            var reset = w
            reset.usedPercent = 0
            reset.resetsAt = nil
            return reset
        }
    }
}
