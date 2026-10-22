import Testing
import Foundation
@testable import MateCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600

/// A 5 h session window that resets in 3 h (40 % elapsed).
private func session(used: Double, resetsIn: TimeInterval = 3 * hour) -> LimitWindow {
    LimitWindow(kind: .session, usedPercent: used, resetsAt: now.addingTimeInterval(resetsIn),
                duration: 5 * hour, detail: nil)
}

@Test func onTrackWithinFivePoints() {
    #expect(pace(for: session(used: 45), samples: [], now: now) == .onTrack)
}

@Test func aheadButNotRunningOut() {
    let samples = [Sample(at: now.addingTimeInterval(-hour), percent: 49), Sample(at: now, percent: 50)]
    #expect(pace(for: session(used: 50), samples: samples, now: now) == .ahead)
}

@Test func runsOutProjectsFromLastHour() {
    let samples = [
        Sample(at: now.addingTimeInterval(-2 * hour), percent: 10),  // outside the last hour: ignored
        Sample(at: now.addingTimeInterval(-hour), percent: 60),
        Sample(at: now, percent: 80),
    ]
    guard case .runsOut(let at)? = pace(for: session(used: 80), samples: samples, now: now) else {
        Issue.record("expected runsOut"); return
    }
    #expect(abs(at.timeIntervalSince(now.addingTimeInterval(hour))) < 1)
}

@Test func usesWholeWindowWhenLessThanAnHourOfSamples() {
    // One sample only: rate = 60 pts / 2 h elapsed = 30 pts/h, so the remaining 40 pts last 80 min.
    let samples = [Sample(at: now, percent: 60)]
    guard case .runsOut(let at)? = pace(for: session(used: 60), samples: samples, now: now) else {
        Issue.record("expected runsOut"); return
    }
    #expect(abs(at.timeIntervalSince(now.addingTimeInterval(80 * 60))) < 1)
}

@Test func limitReachedAtHundred() {
    let w = session(used: 100)
    #expect(pace(for: w, samples: [], now: now) == .limitReached(resetsAt: w.resetsAt))
}

@Test func limitReachedWithoutResetDate() {
    let w = LimitWindow(kind: .monthlyBudget, usedPercent: 100, resetsAt: nil, duration: nil, detail: nil)
    #expect(pace(for: w, samples: [], now: now) == .limitReached(resetsAt: nil))
}

@Test func nilWithoutDurationOrResetBelowHundred() {
    let noDuration = LimitWindow(kind: .session, usedPercent: 50, resetsAt: now.addingTimeInterval(hour), duration: nil, detail: nil)
    let noReset = LimitWindow(kind: .session, usedPercent: 50, resetsAt: nil, duration: 5 * hour, detail: nil)
    #expect(pace(for: noDuration, samples: [], now: now) == nil)
    #expect(pace(for: noReset, samples: [], now: now) == nil)
}

@Test func tightestPrefersRelativeOverAbsolute() {
    // Session: 30 % used at 10 % elapsed (ratio 3). Weekly: 60 % used at 70 % elapsed (ratio < 1).
    let sess = LimitWindow(kind: .session, usedPercent: 30, resetsAt: now.addingTimeInterval(4.5 * hour),
                           duration: 5 * hour, detail: nil)
    let week = LimitWindow(kind: .weekly, usedPercent: 60, resetsAt: now.addingTimeInterval(0.3 * 7 * 24 * hour),
                           duration: 7 * 24 * hour, detail: nil)
    #expect(tightestWindow([week, sess], now: now)?.kind == .session)
    #expect(tightestWindow([], now: now) == nil)
}

@Test func tightestRanksWindowsWithoutDurationByUsedPercent() {
    let a = LimitWindow(kind: .monthlyBudget, usedPercent: 40, resetsAt: nil, duration: nil, detail: nil)
    let b = LimitWindow(kind: .premiumRequests, usedPercent: 20, resetsAt: nil, duration: nil, detail: nil)
    #expect(tightestWindow([b, a], now: now)?.kind == .monthlyBudget)
}

@Test func untimedBudgetDoesNotOutrankHotSession() {
    let budget = LimitWindow(kind: .monthlyBudget, usedPercent: 40, resetsAt: nil, duration: nil, detail: nil)
    let sess = LimitWindow(kind: .session, usedPercent: 30, resetsAt: now.addingTimeInterval(4.5 * hour),
                           duration: 5 * hour, detail: nil)
    #expect(tightestWindow([budget, sess], now: now)?.kind == .session)
}

@Test func limitReachedAlwaysTightest() {
    let sess = LimitWindow(kind: .session, usedPercent: 100, resetsAt: now.addingTimeInterval(hour),
                           duration: 5 * hour, detail: nil)
    // Weekly: 90 % used at 1 % elapsed, a far higher ratio but still below the limit.
    let week = LimitWindow(kind: .weekly, usedPercent: 90, resetsAt: now.addingTimeInterval(0.99 * 7 * 24 * hour),
                           duration: 7 * 24 * hour, detail: nil)
    #expect(tightestWindow([week, sess], now: now)?.kind == .session)
}

private func week(used: Double, kind: WindowKind = .weekly) -> LimitWindow {
    LimitWindow(kind: kind, usedPercent: used, resetsAt: now.addingTimeInterval(3 * 24 * hour),
                duration: 7 * 24 * hour, detail: nil)
}

@Test func pillDefaultsToSession() {
    #expect(pillWindow([week(used: 40), session(used: 18)], now: now)?.kind == .session)
}

@Test func pillShowsWeeklyFromEighty() {
    #expect(pillWindow([session(used: 30), week(used: 85)], now: now)?.kind == .weekly)
    // The highest weekly window wins.
    let opus = week(used: 92, kind: .weeklyModel("opus"))
    #expect(pillWindow([session(used: 30), week(used: 85), opus], now: now)?.kind == .weeklyModel("opus"))
    #expect(pillWindow([session(used: 30), week(used: 79.9)], now: now)?.kind == .session)
}

@Test func pillLimitReachedWins() {
    let early = session(used: 100, resetsIn: hour)
    let later = LimitWindow(kind: .weekly, usedPercent: 100, resetsAt: now.addingTimeInterval(2 * hour),
                            duration: 7 * 24 * hour, detail: nil)
    #expect(pillWindow([later, early], now: now)?.kind == .session)
    // A full session beats a weekly window at 95 %.
    #expect(pillWindow([week(used: 95), early], now: now)?.kind == .session)
    // A full weekly window beats the session.
    #expect(pillWindow([session(used: 20), later], now: now)?.kind == .weekly)
}

@Test func pillFallsBackWithoutSession() {
    let budget = LimitWindow(kind: .monthlyBudget, usedPercent: 40, resetsAt: nil, duration: nil, detail: nil)
    let premium = LimitWindow(kind: .premiumRequests, usedPercent: 20, resetsAt: nil, duration: nil, detail: nil)
    #expect(pillWindow([premium, budget], now: now)?.kind == .monthlyBudget)
    #expect(pillWindow([], now: now) == nil)
}
