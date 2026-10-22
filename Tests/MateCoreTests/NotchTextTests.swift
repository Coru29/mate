import Testing
import Foundation
@testable import MateCore

// The test bundle has no translations: texts come back in Spanish, the source language.
private let now = Date(timeIntervalSince1970: 1_792_670_400)

@Test func durationRoundsUpToWholeMinutes() {
    #expect(NotchText.duration(25 * 60) == "25 min")
    #expect(NotchText.duration(25 * 60 + 1) == "26 min")
    #expect(NotchText.duration(2 * 3600) == "2 h")
    #expect(NotchText.duration(2 * 3600 + 10 * 60) == "2 h 10 min")
    #expect(NotchText.duration(-5) == "0 min")
}

@Test func resetIsRelativeWithinThreeHours() {
    #expect(NotchText.reset(nil, now: now) == nil)
    #expect(NotchText.reset(now.addingTimeInterval(30), now: now) == "se reinicia ahora")
    #expect(NotchText.reset(now.addingTimeInterval(2 * 3600 + 600), now: now) == "en 2 h 10 min")
    let later = now.addingTimeInterval(4 * 86_400)
    #expect(NotchText.reset(later, now: now)?.hasPrefix("se reinicia ") == true)
    #expect(NotchText.reset(later, now: now)?.hasSuffix(NotchText.time(later)) == true)
}

@Test func ageInMinutesThenHours() {
    #expect(NotchText.age(now.addingTimeInterval(-20), now: now) == "hace un momento")
    #expect(NotchText.age(now.addingTimeInterval(-12 * 60), now: now) == "hace 12 min")
    #expect(NotchText.age(now.addingTimeInterval(-150 * 60), now: now) == "hace 2 h")
}

@Test func tokensUseThousandsAndMillions() {
    #expect(NotchText.tokens(950) == "950 tokens")
    #expect(NotchText.tokens(182_400) == "182 k tokens")
    #expect(NotchText.tokens(1_250_000).hasSuffix(" M tokens"))
    // From 10 M the decimal is noise: "71 M tokens", not "71,1 M tokens".
    #expect(NotchText.tokens(71_100_000) == "71 M tokens")
}

@Test func alertLineNamesAccountWindowAndRunOut() {
    let e = AlertEvent(kind: .threshold(90), accountID: "a", window: .session, percent: 91, resetsAt: nil)
    let at = now.addingTimeInterval(1800)
    #expect(NotchText.alert(e, title: "Claude · Personal", pace: .runsOut(at: at))
            == "Claude · Personal: 90 % de la sesión · se acaba \(NotchText.time(at))")
    let r = AlertEvent(kind: .reset, accountID: "a", window: .session, percent: 2, resetsAt: nil)
    #expect(NotchText.alert(r, title: "Claude · Personal", pace: nil) == "Claude · Personal: se reinició la sesión")
}

@Test func tokensShortUsesKAndM() {
    #expect(NotchText.tokensShort(950) == "950")
    #expect(NotchText.tokensShort(182_400) == "182 k")
    #expect(NotchText.tokensShort(1_240_000).hasSuffix(" M"))
    #expect(NotchText.tokensShort(25_000_000) == "25 M")
}

@Test func usdHasTwoDecimals() {
    #expect(NotchText.usd(12.3) == "$12.30")
    #expect(NotchText.usd(0) == "$0.00")
}
