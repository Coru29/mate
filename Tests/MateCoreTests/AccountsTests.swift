import Testing
import Foundation
@testable import MateCore

private func obs(_ identity: String, _ dir: String = "~/.claude", email: String? = nil,
                 _ p: ProviderID = .claude) -> ObservedSession {
    ObservedSession(provider: p, configDir: dir, identity: identity, email: email)
}

@Test func firstObservationCreatesAgentOwnedAccount() {
    var r = AccountRegistry()
    let actions = r.reconcile(provider: .claude, observed: [obs("a")], scannedDirs: ["~/.claude", "~/.claude-work", "~/.codex"])
    #expect(r.accounts.count == 1)
    #expect(r.accounts[0].id == "claude:a")
    #expect(r.accounts[0].owner == .agent)
    #expect(r.accounts[0].agentConfigDir == "~/.claude")
    #expect(actions == [.storeShadow(accountID: "claude:a", configDir: "~/.claude")])
}

@Test func everyObservationRefreshesShadow() {
    var r = AccountRegistry()
    _ = r.reconcile(provider: .claude, observed: [obs("a")], scannedDirs: ["~/.claude", "~/.claude-work", "~/.codex"])
    let again = r.reconcile(provider: .claude, observed: [obs("a")], scannedDirs: ["~/.claude", "~/.claude-work", "~/.codex"])
    #expect(again == [.storeShadow(accountID: "claude:a", configDir: "~/.claude")])
}

@Test func agentOwnedAccountIsNeverRefreshable() {
    var r = AccountRegistry()
    _ = r.reconcile(provider: .claude, observed: [obs("a")], scannedDirs: ["~/.claude", "~/.claude-work", "~/.codex"])
    r.addLogin(provider: .claude, identity: "b", email: nil)
    #expect(!r.canRefresh("claude:a"))
    #expect(r.canRefresh("claude:b"))
    #expect(!r.canRefresh("claude:missing"))
}

@Test func loginToOtherAccountHandsPreviousToMate() {
    var r = AccountRegistry()
    _ = r.reconcile(provider: .claude, observed: [obs("a")], scannedDirs: ["~/.claude", "~/.claude-work", "~/.codex"])
    _ = r.reconcile(provider: .claude, observed: [obs("b")], scannedDirs: ["~/.claude"])
    let a = r.accounts.first { $0.identity == "a" }!
    let b = r.accounts.first { $0.identity == "b" }!
    #expect(a.owner == .mate && a.agentConfigDir == nil)
    #expect(b.owner == .agent)
}

@Test func reloginTransfersOwnershipToAgent() {
    var r = AccountRegistry()
    r.addLogin(provider: .claude, identity: "a", email: nil)
    let actions = r.reconcile(provider: .claude, observed: [obs("a")], scannedDirs: ["~/.claude", "~/.claude-work", "~/.codex"])
    #expect(r.accounts[0].owner == .agent)
    #expect(actions.contains(.storeShadow(accountID: "claude:a", configDir: "~/.claude")))
    #expect(!r.canRefresh("claude:a"))
}

@Test func sameIdentityInTwoConfigDirsIsOneAccount() {
    var r = AccountRegistry()
    let both = [obs("a", "~/.claude"), obs("a", "~/.claude-work")]
    let actions = r.reconcile(provider: .claude, observed: both, scannedDirs: [])
    #expect(r.accounts.count == 1)
    #expect(r.accounts[0].agentConfigDir == "~/.claude")
    #expect(actions == [.storeShadow(accountID: "claude:a", configDir: "~/.claude")])
    _ = r.reconcile(provider: .claude, observed: both, scannedDirs: [])
    #expect(r.accounts[0].owner == .agent && r.accounts[0].agentConfigDir == "~/.claude")
    // First dir gone: moves to the remaining one, still agent-owned.
    _ = r.reconcile(provider: .claude, observed: [obs("a", "~/.claude-work")], scannedDirs: ["~/.claude", "~/.claude-work"])
    #expect(r.accounts[0].owner == .agent && r.accounts[0].agentConfigDir == "~/.claude-work")
    // Seen again in both: keeps the dir where it is still observed.
    _ = r.reconcile(provider: .claude, observed: both, scannedDirs: [])
    #expect(r.accounts[0].agentConfigDir == "~/.claude-work")
}

@Test func loggedOutDirLeavesAccountWithMate() {
    var r = AccountRegistry()
    _ = r.reconcile(provider: .claude, observed: [obs("a")], scannedDirs: ["~/.claude", "~/.claude-work", "~/.codex"])
    let actions = r.reconcile(provider: .claude, observed: [], scannedDirs: ["~/.claude"])
    #expect(actions.isEmpty)
    #expect(r.accounts[0].owner == .mate && r.accounts[0].agentConfigDir == nil)
}

@Test func reconcileNeverTouchesOtherProviders() {
    var r = AccountRegistry()
    _ = r.reconcile(provider: .codex, observed: [obs("x", "~/.codex", .codex)], scannedDirs: ["~/.claude", "~/.claude-work", "~/.codex"])
    let actions = r.reconcile(provider: .claude, observed: [obs("a")], scannedDirs: ["~/.claude", "~/.claude-work", "~/.codex"])
    #expect(r.accounts.first { $0.provider == .codex }?.owner == .agent)
    #expect(actions.allSatisfy { if case .storeShadow(let id, _) = $0 { id.hasPrefix("claude:") } else { false } })
}

@Test func switchPlanSwapsOwners() {
    var r = AccountRegistry()
    r.addLogin(provider: .claude, identity: "a", email: nil)
    _ = r.reconcile(provider: .claude, observed: [obs("b")], scannedDirs: ["~/.claude"])
    let plan = r.switchPlan(to: "claude:a", configDir: "~/.claude")
    #expect(plan == SwitchPlan(incoming: "claude:a", outgoing: "claude:b", configDir: "~/.claude"))
    r.apply(plan!)
    let a = r.accounts.first { $0.identity == "a" }!
    let b = r.accounts.first { $0.identity == "b" }!
    #expect(a.owner == .agent && a.agentConfigDir == "~/.claude")
    #expect(b.owner == .mate && b.agentConfigDir == nil)
}

@Test func switchPlanNilForAgentOwnedOrOtherProvider() {
    var r = AccountRegistry()
    _ = r.reconcile(provider: .claude, observed: [obs("a")], scannedDirs: ["~/.claude", "~/.claude-work", "~/.codex"])
    r.addLogin(provider: .codex, identity: "x", email: nil)
    #expect(r.switchPlan(to: "claude:a", configDir: "~/.claude") == nil)
    #expect(r.switchPlan(to: "gemini:nope", configDir: "~/.claude") == nil)
    // A codex account never displaces the claude account held in that dir.
    let plan = r.switchPlan(to: "codex:x", configDir: "~/.claude")
    #expect(plan?.outgoing == nil)
}

@Test func newAccountsGetNextColorAndEmailAsName() {
    var r = AccountRegistry()
    _ = r.reconcile(provider: .claude, observed: [obs("a", email: "a@x.com")], scannedDirs: ["~/.claude", "~/.claude-work", "~/.codex"])
    let b = r.addLogin(provider: .claude, identity: "b", email: nil)
    let c = r.addLogin(provider: .claude, identity: "c", email: "c@x.com")
    let x = r.addLogin(provider: .codex, identity: "x", email: nil)
    #expect(r.accounts[0].colorIndex == 0 && r.accounts[0].name == "a@x.com")
    #expect(b.colorIndex == 1 && b.name == "b")
    #expect(c.colorIndex == 2 && c.name == "c@x.com")
    #expect(x.colorIndex == 0)
}

@Test func refreshDecisionRespectsOwnership() {
    var r = AccountRegistry()
    _ = r.reconcile(provider: .claude, observed: [obs("a")], scannedDirs: ["~/.claude", "~/.claude-work", "~/.codex"])
    r.addLogin(provider: .claude, identity: "m", email: nil)
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(r.refreshDecision(for: "claude:a", expiresAt: now, now: now) == .stale)
    #expect(r.refreshDecision(for: "claude:a", expiresAt: now.addingTimeInterval(60), now: now) == .useAsIs)
    #expect(r.refreshDecision(for: "claude:m", expiresAt: now.addingTimeInterval(299), now: now) == .refresh)
    #expect(r.refreshDecision(for: "claude:m", expiresAt: now.addingTimeInterval(300), now: now) == .useAsIs)
    #expect(r.refreshDecision(for: "claude:m", expiresAt: nil, now: now) == .useAsIs)
    #expect(r.refreshDecision(for: "claude:a", expiresAt: nil, now: now) == .useAsIs)
}

@Test func registryCodableRoundTrip() throws {
    var r = AccountRegistry()
    _ = r.reconcile(provider: .claude, observed: [obs("a", email: "a@x.com")], scannedDirs: ["~/.claude", "~/.claude-work", "~/.codex"])
    r.addLogin(provider: .codex, identity: "x", email: nil)
    r.accounts[0].status = .error("boom")
    r.accounts[1].source = .configDir("~/.codex")
    let back = try JSONDecoder().decode(AccountRegistry.self, from: JSONEncoder().encode(r))
    #expect(back == r)
}

@Test func removingMateOwnedAccountDropsCopy() {
    var r = AccountRegistry()
    _ = r.reconcile(provider: .claude, observed: [obs("a")], scannedDirs: ["~/.claude", "~/.claude-work", "~/.codex"])
    r.addLogin(provider: .claude, identity: "m", email: nil)
    let dropped = r.remove("claude:m")
    let agentOwned = r.remove("claude:a")
    let unknown = r.remove("claude:zzz")
    #expect(dropped == [.dropMateCopy(accountID: "claude:m")])
    #expect(agentOwned.isEmpty)
    #expect(unknown.isEmpty)
    #expect(r.accounts.isEmpty)
}

@Test func unreadableDirDoesNotDemoteAgentAccount() {
    var r = AccountRegistry()
    _ = r.reconcile(provider: .claude, observed: [obs("a")], scannedDirs: ["~/.claude"])
    let actions = r.reconcile(provider: .claude, observed: [], scannedDirs: [])
    #expect(actions.isEmpty)
    #expect(r.accounts[0].owner == .agent && r.accounts[0].agentConfigDir == "~/.claude")
}

@Test func staleSwitchPlanIsRefused() {
    var r = AccountRegistry()
    r.addLogin(provider: .claude, identity: "a", email: nil)
    _ = r.reconcile(provider: .claude, observed: [obs("b")], scannedDirs: ["~/.claude"])
    let plan = r.switchPlan(to: "claude:a", configDir: "~/.claude")!
    // The agent moved on to c before the plan was applied.
    _ = r.reconcile(provider: .claude, observed: [obs("c")], scannedDirs: ["~/.claude"])
    let before = r
    let refused = r.apply(plan)
    #expect(refused == false)
    #expect(r == before)
    // Incoming no longer Mate-owned.
    var r2 = AccountRegistry()
    r2.addLogin(provider: .claude, identity: "a", email: nil)
    let p2 = r2.switchPlan(to: "claude:a", configDir: "~/.claude")!
    let first = r2.apply(p2)
    let second = r2.apply(p2)
    #expect(first)
    #expect(second == false)
}

@Test func renameSurvivesReconcile() {
    var r = AccountRegistry()
    _ = r.reconcile(provider: .claude, observed: [obs("a")], scannedDirs: ["~/.claude"])
    r.accounts[0].name = "Work"
    _ = r.reconcile(provider: .claude, observed: [obs("a", email: "a@x.com")], scannedDirs: ["~/.claude"])
    #expect(r.accounts[0].name == "Work" && r.accounts[0].email == "a@x.com")
    r.addLogin(provider: .claude, identity: "a", email: "new@x.com")
    #expect(r.accounts[0].name == "Work" && r.accounts[0].email == "new@x.com")
}

@Test func colorDoesNotRepeatAfterRemove() {
    var r = AccountRegistry()
    r.addLogin(provider: .claude, identity: "a", email: nil)
    r.addLogin(provider: .claude, identity: "b", email: nil)
    r.remove("claude:a")
    let c = r.addLogin(provider: .claude, identity: "c", email: nil)
    #expect(c.colorIndex == 2)
}

@Test func mateOwnedLoginStaysMateWhenNotObserved() {
    var r = AccountRegistry()
    r.addLogin(provider: .claude, identity: "m", email: nil)
    let actions = r.reconcile(provider: .claude, observed: [], scannedDirs: ["~/.claude"])
    #expect(actions.isEmpty)
    #expect(r.accounts[0].owner == .mate && r.accounts[0].agentConfigDir == nil)
}
