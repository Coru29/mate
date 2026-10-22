import Testing
import Foundation
@testable import MateCore

@Test func thresholdsSnapToFivesInsideTheRangeSortedAndUnique() {
    #expect(AlertThresholds.normalize([90, 75, 100]) == [75, 90, 100])
    #expect(AlertThresholds.normalize([42, 101, 77, 78, 90, 90]) == [50, 75, 80, 90, 100])
    #expect(AlertThresholds.range == 50...100)
    #expect(AlertThresholds.step == 5)
}

@Test func emptyThresholdsFallBackToTheDefaults() {
    #expect(AlertThresholds.normalize([]) == [75, 90, 100])
}

@Test func providerOrderKeepsTheStoredOrderAndAppendsMissingProviders() {
    #expect(Preferences.providerOrder(["codex", "grok", "nope", "codex", "claude"])
            == [.codex, .grok, .claude, .cursor, .gemini, .copilot])
    #expect(Preferences.providerOrder([]) == ProviderID.allCases)
}

@Test func languageMapsToAppleLanguages() {
    #expect(Preferences.appleLanguages(for: "es") == ["es"])
    #expect(Preferences.appleLanguages(for: "en") == ["en"])
    #expect(Preferences.appleLanguages(for: "system") == nil)
    #expect(Preferences.appleLanguages(for: "xx") == nil)
}

@Test func onboardingAndPerProviderAlertDefaults() {
    #expect(Preferences.defaults[PrefKey.hasOnboarded.rawValue] as? Bool == false)
    #expect(Preferences.defaults[PrefKey.alertsDisabledProviders.rawValue] as? [String] == [])
}
