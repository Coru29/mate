import Foundation

public enum ClaudeUsage {
    /// `five_hour`/`seven_day`/`seven_day_opus`/`seven_day_sonnet` `{utilization (percent), resets_at}`.
    /// `extra_usage {used_credits, monthly_limit}` (assumed to be cents) goes into the weekly window's `detail`
    /// (the session window when there is no weekly one).
    public static func windows(from data: Data, now: Date) throws -> [LimitWindow] {
        let root = try J.object(data)
        let specs: [(String, WindowKind, TimeInterval)] = [
            ("five_hour", .session, 18_000), ("seven_day", .weekly, 604_800),
            ("seven_day_opus", .weeklyModel("Opus"), 604_800), ("seven_day_sonnet", .weeklyModel("Sonnet"), 604_800),
        ]
        guard specs.contains(where: { root[$0.0] != nil }) else { throw ParseError.malformed("no usage windows") }
        var out: [LimitWindow] = []
        for (key, kind, duration) in specs {
            guard let o = try J.dict(root, key), let used = try J.double(o, "utilization") else { continue }
            out.append(LimitWindow(kind: kind, usedPercent: used, resetsAt: try J.dateValue(o, "resets_at"),
                                   duration: duration))
        }
        if let extra = try J.dict(root, "extra_usage"), try J.bool(extra, "is_enabled") != false,
           let spent = try J.double(extra, "used_credits"), let limit = try J.double(extra, "monthly_limit"),
           let i = out.firstIndex(where: { $0.kind == .weekly }) ?? out.indices.first {
            out[i].detail = "USD \(J.amount(spent / 100)) de \(J.amount(limit / 100, trim: true))"
        }
        return out
    }
}

public enum ClaudeProfile {
    /// `{account: {uuid, email}}` from the OAuth profile endpoint.
    public static func identity(from data: Data) throws -> (uuid: String, email: String?) {
        let root = try J.object(data)
        guard let account = try J.dict(root, "account"), let uuid = try J.string(account, "uuid") else {
            throw ParseError.malformed("account.uuid missing")
        }
        return (uuid, try J.string(account, "email"))
    }
}
