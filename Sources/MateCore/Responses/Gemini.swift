import Foundation

public enum GeminiQuota {
    /// UNVERIFIED — confirm in Task 8/11/13. Assumed `retrieveUserQuota` shape:
    /// `{buckets: [{modelId, remainingFraction (0–1), resetTime (ISO-8601)}]}`; quotas are daily.
    public static func windows(from data: Data, now: Date) throws -> [LimitWindow] {
        let root = try J.object(data)
        guard let buckets = try J.array(root, "buckets") else { throw ParseError.malformed("buckets missing") }
        var out: [LimitWindow] = []
        for case let b as [String: Any] in buckets {
            guard let model = try J.string(b, "modelId"), let remaining = try J.double(b, "remainingFraction") else { continue }
            out.append(LimitWindow(kind: .dailyModel(model), usedPercent: (1 - remaining) * 100,
                                   resetsAt: try J.dateValue(b, "resetTime"), duration: 86_400))
        }
        return out
    }
}
