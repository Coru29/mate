import Foundation

public enum GrokSpend {
    /// UNVERIFIED — confirm in Task 8/11/13. Assumed management-API billing shape: `{spend: {val: "1240"}}` with
    /// the amount in cents (string or number), or a plain `spend_usd` in dollars. The budget is user-provided (USD).
    /// The window runs to the start of the next UTC month.
    public static func windows(from data: Data, budget: Double, now: Date) throws -> [LimitWindow] {
        let root = try J.object(data)
        guard budget > 0 else { throw ParseError.malformed("budget must be positive") }
        let spent: Double
        if let usd = try J.double(root, "spend_usd") {
            spent = usd
        } else if let s = root["spend"], !(s is NSNull) {
            guard let o = s as? [String: Any], let v = o["val"] else { throw ParseError.malformed("spend.val missing") }
            if let str = v as? String, let cents = Double(str) { spent = cents / 100 }
            else if let n = v as? NSNumber { spent = n.doubleValue / 100 }
            else { throw ParseError.malformed("spend.val is not a number") }
        } else {
            throw ParseError.malformed("no spend")
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let monthStart = cal.dateInterval(of: .month, for: now)
        return [LimitWindow(kind: .monthlyBudget, usedPercent: spent / budget * 100, resetsAt: monthStart?.end,
                            duration: monthStart?.duration,
                            detail: "USD \(J.amount(spent)) de \(J.amount(budget, trim: true))")]
    }
}
