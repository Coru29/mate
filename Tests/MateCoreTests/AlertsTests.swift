import Testing
import Foundation
@testable import MateCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let reset1 = t0.addingTimeInterval(3 * 3600)
private let reset2 = reset1.addingTimeInterval(5 * 3600)
private let thresholds = [75, 90, 100]

private func snap(_ percent: Double, resetsAt: Date? = reset1, account: String = "acc") -> UsageSnapshot {
    UsageSnapshot(accountID: account,
                  windows: [LimitWindow(kind: .session, usedPercent: percent, resetsAt: resetsAt,
                                        duration: 5 * 3600, detail: nil)],
                  fetchedAt: t0)
}

private func kinds(_ events: [AlertEvent]) -> [AlertEvent.Kind] { events.map(\.kind) }

@Test func firesOncePerCrossing() {
    var engine = AlertEngine()
    #expect(engine.evaluate(snap(70), thresholds: thresholds).isEmpty)
    let crossing = engine.evaluate(snap(80), thresholds: thresholds)
    #expect(kinds(crossing) == [.threshold(75)])
    #expect(crossing.first?.accountID == "acc")
    #expect(crossing.first?.window == .session)
    #expect(crossing.first?.percent == 80)
    #expect(crossing.first?.resetsAt == reset1)
    #expect(engine.evaluate(snap(85), thresholds: thresholds).isEmpty)
}

@Test func jumpFiresOnlyHighest() {
    var engine = AlertEngine()
    _ = engine.evaluate(snap(50), thresholds: thresholds)
    #expect(kinds(engine.evaluate(snap(95), thresholds: thresholds)) == [.threshold(90)])
}

@Test func resetFiresWhenPeriodChangesAfterSeventyFive() {
    var engine = AlertEngine()
    _ = engine.evaluate(snap(80), thresholds: thresholds)
    let events = engine.evaluate(snap(5, resetsAt: reset2), thresholds: thresholds)
    #expect(kinds(events) == [.reset])
    #expect(events.first?.resetsAt == reset2)
}

@Test func resetFiresWithoutResetDateWhenUsageDrops() {
    var engine = AlertEngine()
    _ = engine.evaluate(snap(80, resetsAt: nil), thresholds: thresholds)
    #expect(kinds(engine.evaluate(snap(10, resetsAt: nil), thresholds: thresholds)) == [.reset])
}

@Test func noResetAlertBelowSeventyFive() {
    var engine = AlertEngine()
    _ = engine.evaluate(snap(60), thresholds: thresholds)
    #expect(engine.evaluate(snap(5, resetsAt: reset2), thresholds: thresholds).isEmpty)
}

@Test func smallResetsAtJitterIsNotANewPeriod() {
    var engine = AlertEngine()
    _ = engine.evaluate(snap(80), thresholds: thresholds)
    #expect(engine.evaluate(snap(82, resetsAt: reset1.addingTimeInterval(30)), thresholds: thresholds).isEmpty)
}

@Test func newPeriodRearmsThresholds() {
    var engine = AlertEngine()
    _ = engine.evaluate(snap(80), thresholds: thresholds)
    _ = engine.evaluate(snap(5, resetsAt: reset2), thresholds: thresholds)
    #expect(kinds(engine.evaluate(snap(76, resetsAt: reset2), thresholds: thresholds)) == [.threshold(75)])
}

@Test func firstSnapshotDoesNotAlertBelowLowest() {
    var engine = AlertEngine()
    #expect(engine.evaluate(snap(74), thresholds: thresholds).isEmpty)
}

@Test func accountsAndWindowsAreTrackedSeparately() {
    var engine = AlertEngine()
    _ = engine.evaluate(snap(80, account: "a"), thresholds: thresholds)
    #expect(kinds(engine.evaluate(snap(80, account: "b"), thresholds: thresholds)) == [.threshold(75)])
}

@Test func codableRoundTrip() throws {
    var engine = AlertEngine()
    _ = engine.evaluate(snap(80), thresholds: thresholds)
    let data = try JSONEncoder().encode(engine)
    var restored = try JSONDecoder().decode(AlertEngine.self, from: data)
    // The restored engine remembers 75 already fired, but still fires 90.
    #expect(restored.evaluate(snap(85), thresholds: thresholds).isEmpty)
    #expect(kinds(restored.evaluate(snap(91), thresholds: thresholds)) == [.threshold(90)])
}

@Test func windowKindKeysAreStableAndDistinct() {
    let kinds: [WindowKind] = [.session, .weekly, .weeklyModel("Opus"), .weeklyModel("Sonnet"), .billingCycle,
                               .monthlyBudget, .dailyModel("gemini-2.5-pro"), .premiumRequests]
    #expect(Set(kinds.map(\.key)).count == kinds.count)
    #expect(WindowKind.weeklyModel("Opus").key == "weeklyModel:Opus")
    #expect(WindowKind.session.key == "session")
}

@Test func pruneForgetsOnlyThatAccount() {
    var engine = AlertEngine()
    _ = engine.evaluate(snap(80, account: "a"), thresholds: thresholds)
    _ = engine.evaluate(snap(80, account: "b"), thresholds: thresholds)
    engine.prune(accountID: "a")
    // "a" starts over: the same crossing alerts again; "b" still remembers it fired.
    #expect(kinds(engine.evaluate(snap(80, account: "a"), thresholds: thresholds)) == [.threshold(75)])
    #expect(engine.evaluate(snap(80, account: "b"), thresholds: thresholds).isEmpty)
}

@Test func pruneDoesNotTouchAnAccountWhoseIdIsAPrefix() {
    var engine = AlertEngine()
    _ = engine.evaluate(snap(80, account: "claude:a|x"), thresholds: thresholds)
    engine.prune(accountID: "claude:a")
    #expect(engine.evaluate(snap(80, account: "claude:a|x"), thresholds: thresholds).isEmpty)
}
