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
    ]
}
