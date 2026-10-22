import Foundation
import Testing
@testable import MateCore

@Suite struct SchedulingTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func writeKeepsProviderActiveForTwoMinutes() {
        var a = ActivityTracker()
        a.noteWrite(.claude, at: t0)
        #expect(a.activeProviders(now: t0.addingTimeInterval(119)) == [.claude])
        #expect(a.activeProviders(now: t0.addingTimeInterval(120)).isEmpty)
    }

    @Test func cursorFrontmostIsActive() {
        var a = ActivityTracker()
        a.setFrontmostCursor(true, at: t0)
        #expect(a.activeProviders(now: t0.addingTimeInterval(3600)) == [.cursor])
        a.setFrontmostCursor(false, at: t0.addingTimeInterval(3600))
        #expect(a.activeProviders(now: t0.addingTimeInterval(3600 + 119)) == [.cursor])
        #expect(a.activeProviders(now: t0.addingTimeInterval(3600 + 120)).isEmpty)
    }

    @Test func mostRecentFirst() {
        var a = ActivityTracker()
        a.noteWrite(.claude, at: t0)
        a.noteWrite(.codex, at: t0.addingTimeInterval(10))
        a.noteWrite(.gemini, at: t0.addingTimeInterval(5))
        #expect(a.activeProviders(now: t0.addingTimeInterval(20)) == [.codex, .gemini, .claude])
    }

    @Test func nextExpiryIsEarliestActiveEnd() {
        var a = ActivityTracker()
        #expect(a.nextExpiry(now: t0) == nil)
        a.noteWrite(.claude, at: t0)
        a.noteWrite(.codex, at: t0.addingTimeInterval(30))
        a.setFrontmostCursor(true, at: t0.addingTimeInterval(40))
        #expect(a.nextExpiry(now: t0.addingTimeInterval(50)) == t0.addingTimeInterval(120))
        #expect(a.nextExpiry(now: t0.addingTimeInterval(125)) == t0.addingTimeInterval(150))
        #expect(a.nextExpiry(now: t0.addingTimeInterval(200)) == nil)
    }

    let s = FetchSchedule()

    @Test func activeFetchEveryFiveMinutes() {
        let now = t0.addingTimeInterval(100)
        #expect(s.nextFetch(lastSuccess: t0, failures: 0, active: true, panelOpen: false, now: now) == t0.addingTimeInterval(300))
        #expect(s.nextFetch(lastSuccess: t0, failures: 0, active: false, panelOpen: true, now: now) == t0.addingTimeInterval(300))
        // Never in the past.
        let late = t0.addingTimeInterval(1000)
        #expect(s.nextFetch(lastSuccess: t0, failures: 0, active: true, panelOpen: false, now: late) == late)
        #expect(s.nextFetch(lastSuccess: nil, failures: 0, active: true, panelOpen: false, now: now) == now.addingTimeInterval(300))
    }

    @Test func idleFetchEveryThirtyMinutes() {
        #expect(s.nextFetch(lastSuccess: t0, failures: 0, active: false, panelOpen: false, now: t0) == t0.addingTimeInterval(1800))
    }

    @Test func backoffDoublesAfterFailureUpToCap() {
        let expected: [Int: TimeInterval] = [1: 300, 2: 600, 3: 1200, 4: 2400, 5: 3600, 9: 3600, 100: 3600]
        for (failures, delay) in expected {
            #expect(s.nextFetch(lastSuccess: t0, failures: failures, active: false, panelOpen: false, now: t0) == t0.addingTimeInterval(delay))
        }
    }

    @Test func panelOpenFetchesWhenOlderThanOneMinute() {
        #expect(s.shouldFetchOnPanelOpen(lastSuccess: nil, now: t0))
        #expect(!s.shouldFetchOnPanelOpen(lastSuccess: t0, now: t0.addingTimeInterval(60)))
        #expect(s.shouldFetchOnPanelOpen(lastSuccess: t0, now: t0.addingTimeInterval(61)))
    }
}
