import Testing
import Foundation
@testable import MateCore

private func codex(_ identity: String, owner: TokenOwner = .agent) -> Account {
    Account(id: "codex:\(identity)", provider: .codex, identity: identity, email: nil, name: identity,
            colorIndex: 0, source: .detected, owner: owner, agentConfigDir: owner == .agent ? "~/.codex" : nil)
}

@Test func oldCodexIDIsRenamedToTheSessionsNewID() {
    let r = CodexAccountMigration.renames(newIdentities: ["acct-1:user-1"], existingIDs: ["codex:acct-1"])
    #expect(r == [CodexAccountMigration.Rename(from: "codex:acct-1", to: "codex:acct-1:user-1", identity: "acct-1:user-1")])
}

@Test func codexRenameNeedsTheOldAndNotTheNewAccount() {
    #expect(CodexAccountMigration.renames(newIdentities: ["acct-1:user-1"], existingIDs: []).isEmpty)
    #expect(CodexAccountMigration.renames(newIdentities: ["acct-1:user-1"],
                                         existingIDs: ["codex:acct-1", "codex:acct-1:user-1"]).isEmpty)
    #expect(CodexAccountMigration.renames(newIdentities: ["acct-1"], existingIDs: ["codex:acct-1"]).isEmpty)
    // Two users of the old merged account: only the first one seen takes it over.
    let two = CodexAccountMigration.renames(newIdentities: ["acct-1:u1", "acct-1:u2"], existingIDs: ["codex:acct-1"])
    #expect(two.map(\.to) == ["codex:acct-1:u1"])
}

@Test func registryRenamesAnAccountInPlace() {
    var r = AccountRegistry(accounts: [codex("acct-1"), codex("acct-2", owner: .mate)])
    r.accounts[0].name = "Work"
    r.rename(CodexAccountMigration.Rename(from: "codex:acct-1", to: "codex:acct-1:u", identity: "acct-1:u"))
    #expect(r.accounts.map(\.id) == ["codex:acct-1:u", "codex:acct-2"])
    #expect(r.accounts[0].identity == "acct-1:u" && r.accounts[0].name == "Work" && r.accounts[0].owner == .agent)
}

@Test func switchHistoryRenamesTheAccount() {
    var h = SwitchHistory()
    let t = Date(timeIntervalSince1970: 100)
    h.record(configDir: "~/.codex", accountID: "codex:acct-1", at: t)
    h.renameAccount(from: "codex:acct-1", to: "codex:acct-1:u")
    #expect(h.account(forConfigDir: "~/.codex", at: t) == "codex:acct-1:u")
}

@Test func alertEngineKeepsItsStateUnderTheNewID() {
    var e = AlertEngine()
    let now = Date(timeIntervalSince1970: 1_000)
    let w = LimitWindow(kind: .session, usedPercent: 80, resetsAt: now.addingTimeInterval(3600))
    _ = e.evaluate(UsageSnapshot(accountID: "codex:acct-1", windows: [w], fetchedAt: now), thresholds: [75])
    e.renameAccount(from: "codex:acct-1", to: "codex:acct-1:u")
    // Already fired at 75 under the old id: the renamed account does not fire it again.
    let again = e.evaluate(UsageSnapshot(accountID: "codex:acct-1:u", windows: [w], fetchedAt: now), thresholds: [75])
    #expect(again.isEmpty)
}

@Test func aggregatesMoveTheAccountSlice() {
    var a = UsageAggregates()
    let now = Date()
    let e = TokenEvent(provider: .codex, at: now, model: "gpt-5", input: 10, output: 0, cacheRead: 0, cacheWrite: 0,
                       project: nil, sessionID: "s", dedupeKey: "k1", logDir: "~/.codex")
    _ = a.add(e, accountID: "codex:acct-1")
    a.renameAccount(from: "codex:acct-1", to: "codex:acct-1:u")
    #expect(a.byModel(last: 1, now: now, account: "codex:acct-1:u").map(\.tokens) == [10])
    #expect(a.byModel(last: 1, now: now, account: "codex:acct-1").isEmpty)
}
