import Foundation

public enum CopilotUsage {
    /// `GET api.github.com/copilot_internal/user`. Verified against VS Code's Copilot Chat 0.65.0 (it reads the same
    /// fields): `quota_snapshots.premium_interactions {entitlement, remaining, percent_remaining, unlimited,
    /// overage_count, overage_permitted}` and `quota_reset_date`; a free plan (`copilot_plan == "free"` or
    /// `access_type_sku == "free_limited_copilot"`) is limited by `quota_snapshots.chat` instead.
    /// An unlimited plan yields no window.
    public static func windows(from data: Data, now: Date) throws -> [LimitWindow] {
        let root = try J.object(data)
        guard let snaps = try J.dict(root, "quota_snapshots") else { throw ParseError.malformed("quota_snapshots missing") }
        let free = (try? J.string(root, "copilot_plan")) == "free"
            || (try? J.string(root, "access_type_sku")) == "free_limited_copilot"
        let snapshot = free ? (try J.dict(snaps, "chat") ?? J.dict(snaps, "premium_interactions"))
                            : (try J.dict(snaps, "premium_interactions") ?? J.dict(snaps, "chat"))
        guard let p = snapshot else { return [] }
        if try J.bool(p, "unlimited") == true { return [] }
        let entitlement = try J.double(p, "entitlement")
        let remaining = try J.double(p, "remaining")
        let percent: Double
        if let e = entitlement, let r = remaining, e > 0 {
            percent = (e - r) / e * 100
        } else if let r = try J.double(p, "percent_remaining") {
            percent = 100 - r
        } else {
            throw ParseError.malformed("no premium quota")
        }
        var detail: String?
        if let e = entitlement, let r = remaining {
            guard let used = Int(exactly: (e - r).rounded()), let total = Int(exactly: e.rounded()) else {
                throw ParseError.malformed("entitlement out of range")
            }
            detail = "\(used) de \(total)"
        }
        return [LimitWindow(kind: .premiumRequests, usedPercent: percent,
                            resetsAt: try J.dateValue(root, "quota_reset_date"), duration: nil, detail: detail)]
    }
}
