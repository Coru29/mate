import Foundation

public enum CursorUsage {
    /// Verified against Cursor 3.6.21's bundle (`aiserver.v1.DashboardService/GetCurrentPeriodUsage`, Connect JSON):
    /// `{billingCycleStart, billingCycleEnd (int64 ms, string or number), planUsage: {totalSpend, includedSpend,
    /// remaining, limit (cents), autoPercentUsed?, apiPercentUsed?, totalPercentUsed?}, spendLimitUsage:
    /// {individualUsed, individualLimit? (cents), …}, enabled}`. Zero-valued fields are omitted (proto3 JSON).
    /// Percent is `totalPercentUsed`, else `includedSpend / limit` like Cursor's own usage bar. No plan → no window.
    public static func windows(from data: Data, now: Date) throws -> [LimitWindow] {
        let root = try J.object(data)
        let start = try millis(root, "billingCycleStart")
        let end = try millis(root, "billingCycleEnd")
        guard let plan = try J.dict(root, "planUsage") else {
            // A plan-less account still has a billing cycle; an object with neither is not this response.
            if end == nil { throw ParseError.malformed("not a usage response") }
            return []
        }
        let percent: Double
        if let p = try J.double(plan, "totalPercentUsed") {
            percent = p
        } else if let limit = try J.double(plan, "limit"), limit > 0 {
            percent = min((try J.double(plan, "includedSpend") ?? 0) / limit * 100, 100)
        } else {
            return []
        }
        var detail: String?
        if let od = try J.dict(root, "spendLimitUsage"), let spent = try J.double(od, "individualUsed"), spent > 0 {
            detail = "USD \(J.amount(spent / 100)) a demanda"
        }
        let duration = start.flatMap { s in end.map { $0.timeIntervalSince(s) } }
        return [LimitWindow(kind: .billingCycle, usedPercent: percent, resetsAt: end, duration: duration, detail: detail)]
    }

    /// A protobuf int64 of epoch milliseconds (JSON string or number); 0 or absent is nil.
    private static func millis(_ d: [String: Any], _ k: String) throws -> Date? {
        let ms: Double?
        if let s = d[k] as? String {
            guard let v = Double(s) else { throw ParseError.malformed("\(k) is not a number") }
            ms = v
        } else {
            ms = try J.double(d, k)
        }
        guard let ms, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
