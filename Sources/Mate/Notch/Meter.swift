import AppKit
import SwiftUI
import MateCore

/// Colors of the notch UI, shared with the website's demo.
enum NotchPalette {
    static let onNotch = Color(red: 0xf1 / 255, green: 0xf3 / 255, blue: 0xea / 255)
    static let muted = Color(red: 0xa9 / 255, green: 0xb0 / 255, blue: 0xa1 / 255)
    static let accountColors: [NSColor] = [
        NSColor(srgbRed: 0x6f / 255, green: 0xd0 / 255, blue: 0x8a / 255, alpha: 1),
        NSColor(srgbRed: 0x7a / 255, green: 0xa7 / 255, blue: 0xff / 255, alpha: 1),
        NSColor(srgbRed: 0xf3 / 255, green: 0xb4 / 255, blue: 0x43 / 255, alpha: 1),
        NSColor(srgbRed: 0xc5 / 255, green: 0x8c / 255, blue: 0xff / 255, alpha: 1),
        NSColor(srgbRed: 0xff / 255, green: 0x8a / 255, blue: 0x65 / 255, alpha: 1),
        NSColor(srgbRed: 0x4d / 255, green: 0xd0 / 255, blue: 0xe1 / 255, alpha: 1),
    ]

    static func accountColor(_ index: Int) -> NSColor {
        accountColors[((index % accountColors.count) + accountColors.count) % accountColors.count]
    }
}

/// Pace state as a color: green on track, amber ahead, red when it runs out or is at the limit.
enum Tone {
    case ok, warn, hot

    init(_ pace: PaceState?) {
        switch pace {
        case .ahead: self = .warn
        case .runsOut, .limitReached: self = .hot
        case .onTrack, nil: self = .ok
        }
    }

    var nsColor: NSColor {
        switch self {
        case .ok: NSColor(srgbRed: 0x3c / 255, green: 0xcf / 255, blue: 0x7a / 255, alpha: 1)
        case .warn: NSColor(srgbRed: 0xf3 / 255, green: 0xb4 / 255, blue: 0x43 / 255, alpha: 1)
        case .hot: NSColor(srgbRed: 0xff / 255, green: 0x6b / 255, blue: 0x5d / 255, alpha: 1)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// The texts of the pill, panel and alerts. Spanish literals are the localization keys.
enum NotchText {
    static func percent(_ value: Double) -> String {
        let n = Int(max(0, value).rounded(.down))
        return String(localized: "\(n) %")
    }

    static func windowLabel(_ kind: WindowKind) -> String {
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

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// "2 h 10 min", "25 min".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int((interval / 60).rounded(.up)))
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return String(localized: "\(m) min") }
        if m == 0 { return String(localized: "\(h) h") }
        return String(localized: "\(h) h \(m) min")
    }

    /// "en 2 h 10 min" within 3 hours, "se reinicia 18:00" the same day, "se reinicia jue 09:00" later.
    static func reset(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let left = date.timeIntervalSince(now)
        if left <= 60 { return String(localized: "se reinicia ahora") }
        if left < 3 * 3600 { return String(localized: "en \(duration(left))") }
        if Calendar.current.isDate(date, inSameDayAs: now) { return String(localized: "se reinicia \(time(date))") }
        let day = date.formatted(.dateTime.weekday(.abbreviated))
        return String(localized: "se reinicia \(day) \(time(date))")
    }

    static func pace(_ state: PaceState?) -> String? {
        switch state {
        case .onTrack: String(localized: "Al día")
        case .ahead: String(localized: "Vas rápido")
        case .runsOut(let at): String(localized: "Se acaba a las \(time(at))")
        case .limitReached: String(localized: "Límite alcanzado")
        case nil: nil
        }
    }

    /// "hace 12 min", "hace 2 h", "hace un momento".
    static func age(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return String(localized: "hace un momento") }
        if minutes < 60 { return String(localized: "hace \(minutes) min") }
        return String(localized: "hace \(minutes / 60) h")
    }

    /// "182 k tokens", "1,2 M tokens".
    static func tokens(_ n: Int) -> String {
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

    /// One-line alert: "Claude · Personal: 90 % de la sesión · se acaba 16:40".
    static func alert(_ e: AlertEvent, title: String, pace state: PaceState?) -> String {
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

/// One limit window: label and percent, a bar, the reset and the pace.
struct Meter: View {
    let window: LimitWindow
    let pace: PaceState?
    let now: Date

    var body: some View {
        let tone = Tone(pace)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: NotchText.windowLabel(window.kind))
                    .font(.system(size: 12.5))
                    .foregroundStyle(NotchPalette.muted)
                Spacer(minLength: 8)
                Text(verbatim: NotchText.percent(window.usedPercent))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(NotchPalette.onNotch)
            }
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(tone.color)
                            .frame(width: geo.size.width * min(max(window.usedPercent, 0), 100) / 100)
                    }
                }
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: footnote)
                    .foregroundStyle(NotchPalette.muted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let text = NotchText.pace(pace) {
                    Text(verbatim: text)
                        .fontWeight(.semibold)
                        .foregroundStyle(tone.color)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 12))
        }
    }

    private var footnote: String {
        [NotchText.reset(window.resetsAt, now: now), window.detail].compactMap { $0 }.joined(separator: " · ")
    }
}
