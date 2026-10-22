import Testing
import Foundation
@testable import MateCore

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

// 2026-10-22 12:00:00 UTC
private let now = Date(timeIntervalSince1970: 1_792_670_400)

private func event(_ provider: ProviderID = .claude, at: Date, model: String = "claude-sonnet-4-5", tokens: Int = 100,
                   session: String = "s", project: String? = "p", key: String? = nil) -> TokenEvent {
    TokenEvent(provider: provider, at: at, model: model, input: tokens, output: 0, cacheRead: 0, cacheWrite: 0,
               project: project, sessionID: session, dedupeKey: key)
}

private func days(_ n: Int) -> TimeInterval { TimeInterval(n) * 86_400 }

@Test func dailyBucketsLastSevenDaysIncludeEmptyDays() {
    var agg = UsageAggregates()
    agg.add(event(at: now), calendar: cal)
    agg.add(event(.codex, at: now.addingTimeInterval(-days(2)), tokens: 50), calendar: cal)
    let d = agg.daily(last: 7, now: now, calendar: cal)
    #expect(d.count == 7)
    #expect(d[0].day == cal.startOfDay(for: now.addingTimeInterval(-days(6))))
    #expect(d[6].day == cal.startOfDay(for: now))
    #expect(d[6].perProvider == [.claude: 100])
    #expect(d[4].perProvider == [.codex: 50])
    #expect(d[5].perProvider.isEmpty)
    #expect(d[0].perProvider.isEmpty)
}

@Test func byModelSumsThirtyDays() {
    var agg = UsageAggregates()
    agg.add(event(at: now, model: "claude-sonnet-4-5", tokens: 1_000_000), calendar: cal)
    agg.add(event(at: now.addingTimeInterval(-days(10)), model: "claude-sonnet-4-5", tokens: 1_000_000), calendar: cal)
    agg.add(event(.codex, at: now.addingTimeInterval(-days(20)), model: "gpt-5-codex", tokens: 10), calendar: cal)
    agg.add(event(at: now.addingTimeInterval(-days(40)), model: "claude-sonnet-4-5", tokens: 5), calendar: cal)
    let m = agg.byModel(last: 30, now: now, calendar: cal)
    #expect(m.map(\.model) == ["claude-sonnet-4-5", "gpt-5-codex"])
    #expect(m[0].tokens == 2_000_000)
    #expect(abs(m[0].cost - 6.0) < 1e-9)   // 2 M input tokens at 3 USD / M
    #expect(m[1].tokens == 10)
}

@Test func liveSessionOnlyWithinTwoMinutes() {
    var agg = UsageAggregates()
    agg.add(event(at: now.addingTimeInterval(-300), session: "a", project: "old"), calendar: cal)
    agg.add(event(at: now.addingTimeInterval(-90), session: "a", project: "proj"), calendar: cal)
    agg.add(event(at: now.addingTimeInterval(-30), session: "a", project: "proj"), calendar: cal)
    let live = agg.liveSession(provider: .claude, now: now)
    #expect(live?.project == "proj")
    #expect(live?.tokens == 300)
    #expect(live?.startedAt == now.addingTimeInterval(-300))
    #expect(agg.liveSession(provider: .claude, now: now.addingTimeInterval(200)) == nil)
    #expect(agg.liveSession(provider: .codex, now: now) == nil)
}

@Test func aggregatesCompactOldEvents() {
    var agg = UsageAggregates()
    let old = event(at: now.addingTimeInterval(-days(3)), key: "k-old")
    agg.add(old, calendar: cal)
    #expect(agg.rawEventCount == 1)
    agg.add(event(at: now, key: "k-new"), calendar: cal)
    #expect(agg.rawEventCount == 1)
    #expect(agg.seenKeyCount == 1)
    let d = agg.daily(last: 7, now: now, calendar: cal)
    #expect(d[3].perProvider == [.claude: 100])
    #expect(d[6].perProvider == [.claude: 100])
}

@Test func aggregatesRoundTripThroughCodable() throws {
    var agg = UsageAggregates()
    agg.add(event(at: now, key: "k"), calendar: cal)
    let back = try JSONDecoder().decode(UsageAggregates.self, from: JSONEncoder().encode(agg))
    #expect(back.today(now: now, calendar: cal) == [.claude: 100])
    #expect(back.rawEventCount == 1)
}

@Test func pricingKnownAndUnknownModels() {
    func c(_ m: String, _ i: Int = 0, _ o: Int = 0, r: Int = 0, w: Int = 0) -> Double {
        Pricing.cost(model: m, input: i, output: o, cacheRead: r, cacheWrite: w)
    }
    let M = 1_000_000
    #expect(abs(c("claude-opus-4-5-20251101", M, M, r: M, w: M) - (5 + 25 + 0.5 + 6.25)) < 1e-9)
    #expect(abs(c("claude-opus-4-1-20250805", M) - 15) < 1e-9)
    #expect(abs(c("claude-opus-4-20250514", 0, M) - 75) < 1e-9)
    #expect(abs(c("claude-sonnet-4-5", M, M) - 18) < 1e-9)
    #expect(abs(c("claude-haiku-4-5", M, M, r: M, w: M) - (1 + 5 + 0.1 + 1.25)) < 1e-9)
    #expect(abs(c("gpt-5-codex", M, M, r: M) - (1.25 + 10 + 0.125)) < 1e-9)
    #expect(abs(c("gemini-2.5-pro", M, M, r: M) - (1.25 + 10 + 0.31)) < 1e-9)
    #expect(abs(c("gemini-2.5-flash", M, M) - 2.8) < 1e-9)
    #expect(c("mystery-model", M, M) == 0)
}
