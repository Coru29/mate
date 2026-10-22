import Foundation

/// The texts of the pill, panel and alerts. Spanish literals are the localization keys.
public enum NotchText {
    public static func percent(_ value: Double) -> String {
        let n = Int(max(0, value).rounded(.down))
        return String(localized: "\(n) %")
    }

    public static func windowLabel(_ kind: WindowKind) -> String {
        switch kind {
        case .session: String(localized: "Sesión")
        case .weekly: String(localized: "Semanal")
        case .weeklyModel(let m): String(localized: "Semanal \(m)")
        case .billingCycle: String(localized: "Ciclo de facturación")
        case .monthlyBudget: String(localized: "Presupuesto mensual")
        case .dailyModel(let m): String(localized: "Diario \(m)")
        case .premiumRequests: String(localized: "Pedidos premium")
        }
    }

    public static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// "2 h 10 min", "25 min".
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int((interval / 60).rounded(.up)))
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return String(localized: "\(m) min") }
        if m == 0 { return String(localized: "\(h) h") }
        return String(localized: "\(h) h \(m) min")
    }

    /// "en 2 h 10 min" within 3 hours, "se reinicia 18:00" the same day, "se reinicia jue 09:00" later.
    public static func reset(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let left = date.timeIntervalSince(now)
        if left <= 60 { return String(localized: "se reinicia ahora") }
        if left < 3 * 3600 { return String(localized: "en \(duration(left))") }
        if Calendar.current.isDate(date, inSameDayAs: now) { return String(localized: "se reinicia \(time(date))") }
        let day = date.formatted(.dateTime.weekday(.abbreviated))
        return String(localized: "se reinicia \(day) \(time(date))")
    }

    public static func pace(_ state: PaceState?) -> String? {
        switch state {
        case .onTrack: String(localized: "Al día")
        case .ahead: String(localized: "Vas rápido")
        case .runsOut(let at): String(localized: "Se acaba a las \(time(at))")
        case .limitReached: String(localized: "Límite alcanzado")
        case nil: nil
        }
    }

    /// "hace 12 min", "hace 2 h", "hace un momento".
    public static func age(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return String(localized: "hace un momento") }
        if minutes < 60 { return String(localized: "hace \(minutes) min") }
        return String(localized: "hace \(minutes / 60) h")
    }

    /// "182 k tokens", "1,2 M tokens".
    public static func tokens(_ n: Int) -> String {
        let amount: String
        if n >= 1_000_000 {
            amount = (Double(n) / 1_000_000).formatted(.number.precision(.fractionLength(1))) + " M"
        } else if n >= 1000 {
            amount = "\(n / 1000) k"
        } else {
            amount = "\(n)"
        }
        return String(localized: "\(amount) tokens")
    }

    /// Compact count for chart axes and tables: "950", "182 k", "1,2 M".
    public static func tokensShort(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return m.formatted(.number.precision(.fractionLength(m >= 10 ? 0 : 1))) + " M"
        }
        if n >= 1000 { return "\(n / 1000) k" }
        return "\(n)"
    }

    /// "$12.34" (US dollars, 2 decimals, whatever the locale).
    public static func usd(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(2)))
    }

    /// One-line alert: "Claude · Personal: 90 % de la sesión · se acaba 16:40".
    public static func alert(_ e: AlertEvent, title: String, pace state: PaceState?) -> String {
        let body: String
        switch e.kind {
        case .threshold(let n): body = threshold(n, e.window)
        case .reset: body = reset(e.window)
        }
        var suffix = ""
        if case .threshold = e.kind {
            if case .runsOut(let at) = state {
                suffix = " · " + String(localized: "se acaba \(time(at))")
            } else if e.percent >= 100, let r = e.resetsAt {
                suffix = " · " + String(localized: "se reinicia \(time(r))")
            }
        }
        return "\(title): \(body)\(suffix)"
    }

    private static func threshold(_ n: Int, _ kind: WindowKind) -> String {
        switch kind {
        case .session: String(localized: "\(n) % de la sesión")
        case .weekly: String(localized: "\(n) % del límite semanal")
        case .weeklyModel(let m): String(localized: "\(n) % del límite semanal de \(m)")
        case .billingCycle: String(localized: "\(n) % del ciclo de facturación")
        case .monthlyBudget: String(localized: "\(n) % del presupuesto mensual")
        case .dailyModel(let m): String(localized: "\(n) % del cupo diario de \(m)")
        case .premiumRequests: String(localized: "\(n) % de los pedidos premium")
        }
    }

    private static func reset(_ kind: WindowKind) -> String {
        switch kind {
        case .session: String(localized: "se reinició la sesión")
        case .weekly: String(localized: "se reinició el límite semanal")
        case .weeklyModel(let m): String(localized: "se reinició el límite semanal de \(m)")
        case .billingCycle: String(localized: "se reinició el ciclo de facturación")
        case .monthlyBudget: String(localized: "se reinició el presupuesto mensual")
        case .dailyModel(let m): String(localized: "se reinició el cupo diario de \(m)")
        case .premiumRequests: String(localized: "se reinició el cupo de pedidos premium")
        }
    }
}
