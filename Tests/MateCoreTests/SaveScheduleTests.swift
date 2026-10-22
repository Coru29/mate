import Foundation
import Testing
@testable import MateCore

@Suite struct SaveScheduleTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func dueAfterDebounceFromLastChange() {
        var s = SaveSchedule(policy: .standard)
        #expect(s.noteChange(at: t0) == t0.addingTimeInterval(2))
        #expect(s.noteChange(at: t0.addingTimeInterval(1.5)) == t0.addingTimeInterval(3.5))
    }

    @Test func steadyChangesStillSaveByMaxDelay() {
        var s = SaveSchedule(policy: .standard)
        _ = s.noteChange(at: t0)
        #expect(s.noteChange(at: t0.addingTimeInterval(59)) == t0.addingTimeInterval(60))
        s.reset()
        #expect(s.noteChange(at: t0.addingTimeInterval(61)) == t0.addingTimeInterval(63))
    }

    /// An agent writing its log every few seconds must not re-encode the whole index after every batch.
    @Test func indexStateSavesRarely() {
        var s = SaveSchedule(policy: .index)
        var due = Date.distantPast
        for i in 0..<100 { due = s.noteChange(at: t0.addingTimeInterval(Double(i) * 3)) }
        #expect(due == t0.addingTimeInterval(SaveSchedule.Policy.index.maxDelay))
        #expect(SaveSchedule.Policy.index.debounce >= 30)
        #expect(SaveSchedule.Policy.index.maxDelay >= 300)
    }

    @Test func cursorsAreWrittenLast() {
        #expect(SaveSchedule.writeOrder(["cursors", "aggregates", "alerts"]) == ["aggregates", "alerts", "cursors"])
    }
}
