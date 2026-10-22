import Testing
import Foundation
@testable import MateCore

private let t0 = Date(timeIntervalSince1970: 1_792_000_000)

@Test func switchHistoryAppendsOnlyWhenTheAccountChanges() {
    var h = SwitchHistory()
    h.record(configDir: "~/.claude", accountID: "claude:a", at: t0)
    h.record(configDir: "~/.claude", accountID: "claude:a", at: t0 + 100)
    #expect(h.entries.count == 1)
    h.record(configDir: "~/.claude", accountID: "claude:b", at: t0 + 200)
    h.record(configDir: "~/.claude", accountID: "claude:a", at: t0 + 300)
    #expect(h.entries.count == 3)
}

@Test func switchHistoryAttributesByTime() {
    var h = SwitchHistory()
    h.record(configDir: "~/.claude", accountID: "claude:a", at: t0)
    h.record(configDir: "~/.claude", accountID: "claude:b", at: t0 + 200)
    h.record(configDir: "~/.other", accountID: "claude:c", at: t0 + 50)
    #expect(h.account(forConfigDir: "~/.claude", at: t0 + 199) == "claude:a")
    #expect(h.account(forConfigDir: "~/.claude", at: t0 + 200) == "claude:b")
    #expect(h.account(forConfigDir: "~/.claude", at: t0 + 9999) == "claude:b")
    // Older than the first record: the first account is the best guess.
    #expect(h.account(forConfigDir: "~/.claude", at: t0 - 5000) == "claude:a")
    #expect(h.account(forConfigDir: "~/.other", at: t0 + 100) == "claude:c")
    #expect(h.account(forConfigDir: "~/.unknown", at: t0) == nil)
}

@Test func switchHistoryRoundTripsThroughJSON() throws {
    var h = SwitchHistory()
    h.record(configDir: "~/.claude", accountID: "claude:a", at: t0)
    let back = try JSONDecoder().decode(SwitchHistory.self, from: JSONEncoder().encode(h))
    #expect(back == h)
}
