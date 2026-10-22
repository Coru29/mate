import Foundation

public enum CopilotUsage {
    /// `quota_snapshots.premium_interactions {percent_remaining, unlimited, entitlement, remaining}` and `quota_reset_date`.
    /// An unlimited plan yields no window.
    public static func windows(from data: Data, now: Date) throws -> [LimitWindow] {
        let root = try J.object(data)
        guard let snaps = try J.dict(root, "quota_snapshots") else { throw ParseError.malformed("quota_snapshots missing") }
        guard let p = try J.dict(snaps, "premium_interactions") else { return [] }
        if try J.bool(p, "unlimited") == true { return [] }
        let entitlement = try J.double(p, "entitlement")
        let remaining = try J.double(p, "remaining")
        let percent: Double
        if let r = try J.double(p, "percent_remaining") {
            percent = 100 - r
        } else if let e = entitlement, let r = remaining, e > 0 {
            percent = (e - r) / e * 100
        } else {
            throw ParseError.malformed("no premium quota")
        }
        var detail: String?
        if let e = entitlement, let r = remaining { detail = "\(Int(e - r)) de \(Int(e))" }
        return [LimitWindow(kind: .premiumRequests, usedPercent: percent,
                            resetsAt: try J.dateValue(root, "quota_reset_date"), duration: nil, detail: detail)]
    }
}
