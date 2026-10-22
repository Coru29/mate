import Foundation

public enum GeminiQuota {
    /// UNVERIFIED (Gemini CLI is not installed on the build Mac). Assumed `retrieveUserQuota` shape:
    /// `{buckets: [{modelId, remainingFraction (0–1), resetTime (ISO-8601)}]}`; quotas are daily.
    public static func windows(from data: Data, now: Date) throws -> [LimitWindow] {
        let root = try J.object(data)
        guard let buckets = try J.array(root, "buckets") else { throw ParseError.malformed("buckets missing") }
        var out: [LimitWindow] = []
        for case let b as [String: Any] in buckets {
            guard let model = try J.string(b, "modelId"), let remaining = try J.double(b, "remainingFraction") else { continue }
            out.append(LimitWindow(kind: .dailyModel(model), usedPercent: min(100, max(0, (1 - remaining) * 100)),
                                   resetsAt: try J.dateValue(b, "resetTime"), duration: 86_400))
        }
        return out
    }

    /// UNVERIFIED. The Code Assist project from a `loadCodeAssist` response: `cloudaicompanionProject` as a string
    /// or as `{id}`; nil when the account has none yet.
    public static func project(fromLoadCodeAssist data: Data) throws -> String? {
        let root = try J.object(data)
        guard let v = root["cloudaicompanionProject"], !(v is NSNull) else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let o = v as? [String: Any], let id = try J.string(o, "id") { return id.isEmpty ? nil : id }
        throw ParseError.malformed("cloudaicompanionProject has an unknown shape")
    }
}
