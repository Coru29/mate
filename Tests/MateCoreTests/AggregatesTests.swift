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

@Test func duplicateOfOldEventCountedOnce() {
    var agg = UsageAggregates()
    agg.add(event(at: now, key: "k-new"), calendar: cal)
    let old = event(at: now.addingTimeInterval(-days(10)), model: "claude-sonnet-4-5", key: "K")
    let a = agg.add(old, calendar: cal)
    let b = agg.add(old, calendar: cal)
    #expect(a && !b)
    #expect(agg.daily(last: 14, now: now, calendar: cal)[3].perProvider == [.claude: 100])
    #expect(agg.byModel(last: 30, now: now, calendar: cal).first?.tokens == 200)
}

@Test func duplicateAcrossCodableRoundTripCountedOnce() throws {
    var agg = UsageAggregates()
    let e = event(at: now.addingTimeInterval(-days(5)), key: "K")
    agg.add(e, calendar: cal)
    var back = try JSONDecoder().decode(UsageAggregates.self, from: JSONEncoder().encode(agg))
    let again = back.add(e, calendar: cal)
    #expect(!again)
    #expect(back.byModel(last: 30, now: now, calendar: cal).first?.tokens == 100)
}

/// The first-launch scan adds events in file order, not time order: old events arriving after newer ones must not
/// be kept as raw events (they would bloat memory and aggregates.json), though they still count in their day.
@Test func oldEventsAddedAfterNewerAreNotKeptRaw() {
    var agg = UsageAggregates()
    agg.add(event(at: now, key: "new"), calendar: cal)
    for i in 0..<50 { agg.add(event(at: now.addingTimeInterval(-days(10) - TimeInterval(i)), key: "old\(i)"), calendar: cal) }
    #expect(agg.rawEventCount == 1)
    let tenDaysAgo = agg.daily(last: 11, now: now, calendar: cal).first!
    #expect(tenDaysAgo.perProvider[.claude] == 5000)
}

@Test func lastProjectIsTheNewestEventsProjectEvenWhenNotLive() {
    var agg = UsageAggregates()
    agg.add(event(at: now.addingTimeInterval(-3600), project: "old"), calendar: cal)
    agg.add(event(at: now.addingTimeInterval(-600), project: "rambla"), calendar: cal)
    agg.add(event(.codex, at: now.addingTimeInterval(-60), project: "other"), calendar: cal)
    #expect(agg.liveSession(provider: .claude, now: now) == nil)
    #expect(agg.lastProject(provider: .claude, now: now) == "rambla")
    #expect(agg.lastProject(provider: .gemini, now: now) == nil)
}

@Test func providerFilterSlicesModelsAndAccountFilterSlicesBoth() {
    var agg = UsageAggregates()
    agg.add(event(.claude, at: now, model: "claude-sonnet-4-5", tokens: 100), accountID: "claude:a", calendar: cal)
    agg.add(event(.claude, at: now, model: "claude-opus-4-1", tokens: 40), accountID: "claude:b", calendar: cal)
    agg.add(event(.claude, at: now, model: "claude-sonnet-4-5", tokens: 7), calendar: cal)
    agg.add(event(.codex, at: now, model: "gpt-5-codex", tokens: 10), calendar: cal)
    #expect(agg.byModel(last: 30, now: now, calendar: cal).map(\.tokens).reduce(0, +) == 157)
    let claude = agg.byModel(last: 30, now: now, provider: .claude, calendar: cal)
    #expect(claude.map(\.model) == ["claude-sonnet-4-5", "claude-opus-4-1"])
    #expect(claude.first?.tokens == 107)
    let a = agg.byModel(last: 30, now: now, account: "claude:a", calendar: cal)
    #expect(a.count == 1 && a[0].tokens == 100)
    #expect(agg.daily(last: 1, now: now, account: "claude:b", calendar: cal)[0].perProvider == [.claude: 40])
    #expect(agg.daily(last: 1, now: now, account: "claude:zzz", calendar: cal)[0].perProvider.isEmpty)
}

@Test func bucketsWithoutAccountSlicesStillDecode() throws {
    var agg = UsageAggregates()
    agg.add(event(at: now, tokens: 100), accountID: "claude:a", calendar: cal)
    var json = try #require(String(data: JSONEncoder().encode(agg), encoding: .utf8))
    #expect(json.contains("accountModels"))
    // Strip the two new keys the way an older file would lack them.
    let obj = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    var buckets = try #require(obj["buckets"] as? [[String: Any]])
    for i in buckets.indices { buckets[i]["providerModels"] = nil; buckets[i]["accountModels"] = nil }
    var old = obj
    old["buckets"] = buckets
    json = String(decoding: try JSONSerialization.data(withJSONObject: old), as: UTF8.self)
    let back = try JSONDecoder().decode(UsageAggregates.self, from: Data(json.utf8))
    #expect(back.byModel(last: 30, now: now, calendar: cal).first?.tokens == 100)
}

/// The dedupe hashes are most of the index: saved as one packed string per day, not thousands of JSON numbers.
@Test func dedupeKeysArePackedAndSurviveARoundTrip() throws {
    var agg = UsageAggregates()
    for i in 0..<500 { agg.add(event(at: now, tokens: 1, key: "k\(i)"), calendar: cal) }
    let data = try JSONEncoder().encode(agg)
    let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let bucket = try #require((obj["buckets"] as? [[String: Any]])?.first)
    #expect(bucket["keys"] == nil)
    #expect(bucket["packedKeys"] is String)
    #expect(try JSONSerialization.data(withJSONObject: bucket).count < 500 * 12)
    var back = try JSONDecoder().decode(UsageAggregates.self, from: data)
    #expect(back.byModel(last: 1, now: now, calendar: cal).first?.tokens == 500)
    let dup = back.add(event(at: now, tokens: 1, key: "k7"), calendar: cal)
    let fresh = back.add(event(at: now, tokens: 1, key: "new"), calendar: cal)
    #expect(!dup && fresh)
}

@Test func unpackedDedupeKeysStillDecode() throws {
    var agg = UsageAggregates()
    agg.add(event(at: now, tokens: 100, key: "k1"), calendar: cal)
    let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(agg)) as? [String: Any])
    var buckets = try #require(obj["buckets"] as? [[String: Any]])
    for i in buckets.indices {
        buckets[i]["packedKeys"] = nil
        buckets[i]["keys"] = [NSNumber(value: UsageAggregates.fnv1a("k1"))]
    }
    var old = obj
    old["buckets"] = buckets
    var back = try JSONDecoder().decode(UsageAggregates.self, from: JSONSerialization.data(withJSONObject: old))
    let dup = back.add(event(at: now, tokens: 100, key: "k1"), calendar: cal)
    #expect(!dup)
}
