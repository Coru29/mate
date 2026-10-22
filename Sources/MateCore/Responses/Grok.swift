import Foundation

public enum GrokSpend {
    /// `GET management-api.x.ai/v1/billing/teams/{team_id}/postpaid/invoice/preview` (xAI docs, Billing
    /// Management): `{coreInvoice: {amountBeforeVat: "<USD cents>", totalWithCorr: {val: "<USD cents>"}, …},
    /// billingCycle: {year, month}}`. Spend is `amountBeforeVat`, else `totalWithCorr.val`. UNVERIFIED against a
    /// live response. The budget is user-provided (USD); the window runs to the start of the next UTC month.
    public static func windows(from data: Data, budget: Double, now: Date) throws -> [LimitWindow] {
        let root = try J.object(data)
        guard budget > 0 else { throw ParseError.malformed("budget must be positive") }
        guard let invoice = try J.dict(root, "coreInvoice") else { throw ParseError.malformed("coreInvoice missing") }
        let cents: Double
        if let v = try centsValue(invoice["amountBeforeVat"], "amountBeforeVat") {
            cents = v
        } else if let corr = try J.dict(invoice, "totalWithCorr"), let v = try centsValue(corr["val"], "totalWithCorr.val") {
            cents = v
        } else {
            throw ParseError.malformed("no spend")
        }
        let spent = cents / 100
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let month = cal.dateInterval(of: .month, for: now)
        return [LimitWindow(kind: .monthlyBudget, usedPercent: spent / budget * 100, resetsAt: month?.end,
                            duration: month?.duration,
                            detail: "USD \(J.amount(spent)) de \(J.amount(budget, trim: true))")]
    }

    /// A cents amount sent as a string (xAI's int64) or a number; absent or null is nil.
    private static func centsValue(_ v: Any?, _ name: String) throws -> Double? {
        guard let v, !(v is NSNull) else { return nil }
        if let s = v as? String, let d = Double(s), d.isFinite { return d }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        throw ParseError.malformed("\(name) is not a number")
    }
}
