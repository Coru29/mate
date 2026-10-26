import Foundation

/// Every preference key stored in the `io.github.coru29.Mate` UserDefaults suite.
public enum PrefKey: String, CaseIterable, Sendable {
    case showPillAlways
    case screenChoice
    case alertThresholds
    case systemNotifications
    case providerOrder
    case disabledProviders
    case language
    case checkUpdates
    /// Grok's monthly API budget in USD; 0 means not configured (Grok is not shown).
    case grokMonthlyBudget
    /// The first-launch guide has been shown.
    case hasOnboarded
    /// Providers whose alerts are off (raw values).
    case alertsDisabledProviders
    /// The mate left of the notch, next to the pill.
    case showMateIcon
    /// Hold a "prevent idle sleep" assertion while agents work.
    case keepAwake
    /// "Mostrar lo que estás escuchando": the Spotify / Music card and the album art next to the notch.
    case showNowPlaying
}

public enum Preferences {
    public static let suiteName = "io.github.coru29.Mate"

    /// Default value of every key, keyed by `PrefKey.rawValue`.
    public static let defaults: [String: Any] = [
        PrefKey.showPillAlways.rawValue: false,
        PrefKey.screenChoice.rawValue: "builtIn",
        PrefKey.alertThresholds.rawValue: [75, 90, 100],
        PrefKey.systemNotifications.rawValue: false,
        PrefKey.providerOrder.rawValue: ["claude", "codex", "cursor", "gemini", "copilot", "grok"],
        PrefKey.disabledProviders.rawValue: [String](),
        PrefKey.language.rawValue: "system",
        PrefKey.checkUpdates.rawValue: true,
        PrefKey.grokMonthlyBudget.rawValue: 0.0,
        PrefKey.hasOnboarded.rawValue: false,
        PrefKey.alertsDisabledProviders.rawValue: [String](),
        PrefKey.showMateIcon.rawValue: true,
        PrefKey.keepAwake.rawValue: false,
        PrefKey.showNowPlaying.rawValue: true,
    ]

    /// Every provider in the stored order (unknown and repeated names dropped), the missing ones appended in their
    /// declaration order.
    public static func providerOrder(_ stored: [String]) -> [ProviderID] {
        var out: [ProviderID] = []
        for name in stored { if let p = ProviderID(rawValue: name), !out.contains(p) { out.append(p) } }
        for p in ProviderID.allCases where !out.contains(p) { out.append(p) }
        return out
    }

    /// The `AppleLanguages` value for the app's own domain for a `language` preference; nil means "follow the
    /// system" (the key is removed). macOS reads it at launch, so a change applies on the next launch.
    public static func appleLanguages(for language: String) -> [String]? {
        language == "es" || language == "en" ? [language] : nil
    }
}

/// The alert thresholds the user can pick: 50 % to 100 % in steps of 5.
public enum AlertThresholds {
    public static let range = 50...100
    public static let step = 5

    /// Snapped to the nearest step inside the range, sorted, without repeats; the defaults when empty.
    public static func normalize(_ values: [Int]) -> [Int] {
        let snapped = values.map { v -> Int in
            let n = Int((Double(v) / Double(step)).rounded()) * step
            return min(max(n, range.lowerBound), range.upperBound)
        }
        let out = Array(Set(snapped)).sorted()
        return out.isEmpty ? Preferences.defaults[PrefKey.alertThresholds.rawValue] as? [Int] ?? [] : out
    }
}
