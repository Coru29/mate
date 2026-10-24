import Foundation
import MateCore

/// Preferences the notch reads, with the documented defaults.
enum NotchPrefs {
    private static func value<T>(_ key: PrefKey) -> T? {
        UserDefaults.mate.object(forKey: key.rawValue) as? T ?? Preferences.defaults[key.rawValue] as? T
    }

    static var showPillAlways: Bool { value(.showPillAlways) ?? false }
    static var screenChoice: ScreenChoice { ScreenChoice(rawValue: value(.screenChoice) ?? "") ?? .builtIn }
    static var systemNotifications: Bool { value(.systemNotifications) ?? false }
    static var providerOrder: [String] { value(.providerOrder) ?? [] }
    static var disabledProviders: [String] { value(.disabledProviders) ?? [] }
    static var showMateIcon: Bool { value(.showMateIcon) ?? true }
    static var keepAwake: Bool { value(.keepAwake) ?? false }
}
