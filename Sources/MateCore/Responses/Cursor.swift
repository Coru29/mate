import Foundation

public enum CursorUsage {
    /// UNVERIFIED — confirm in Task 8/11/13. Assumed usage-summary shape (money in cents):
    /// `{billingCycleStart, billingCycleEnd (ISO-8601), individualUsage: {plan: {used, limit, totalPercentUsed},
    /// onDemand: {used, limit}}}`. Percent is `totalPercentUsed`, else `used / limit`.
    public static func windows(from data: Data, now: Date) throws -> [LimitWindow] {
        let root = try J.object(data)
        let start = try J.dateValue(root, "billingCycleStart")
        let end = try J.dateValue(root, "billingCycleEnd")
        guard let usage = try J.dict(root, "individualUsage") else { throw ParseError.malformed("individualUsage missing") }
        guard let plan = try J.dict(usage, "plan") else { throw ParseError.malformed("plan missing") }
        let percent: Double
        if let p = try J.double(plan, "totalPercentUsed") {
            percent = p
        } else if let used = try J.double(plan, "used"), let limit = try J.double(plan, "limit"), limit > 0 {
            percent = used / limit * 100
        } else {
            throw ParseError.malformed("no included usage")
        }
        var detail: String?
        if let od = try J.dict(usage, "onDemand"), let spent = try J.double(od, "used"), spent > 0 {
            detail = "USD \(J.amount(spent / 100)) a demanda"
        }
        let duration = start.flatMap { s in end.map { $0.timeIntervalSince(s) } }
        return [LimitWindow(kind: .billingCycle, usedPercent: percent, resetsAt: end, duration: duration, detail: detail)]
    }
}
