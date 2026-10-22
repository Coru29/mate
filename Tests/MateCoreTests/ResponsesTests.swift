import Testing
import Foundation
@testable import MateCore

private let now = Date(timeIntervalSince1970: 1_792_670_400) // 2026-10-22T12:00:00Z
private func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

@Test func claudeUsageWindows() throws {
    let w = try ClaudeUsage.windows(from: fixture("claude-usage.json"), now: now)
    #expect(w.map(\.kind) == [.session, .weekly, .weeklyModel("Sonnet")])
    #expect(w[0] == LimitWindow(kind: .session, usedPercent: 37, resetsAt: at(1_792_692_000), duration: 18_000))
    #expect(w[1].usedPercent == 12.5)
    #expect(w[1].duration == 604_800)
    // Fractional seconds are parsed (…09:00:00.123456Z).
    #expect(abs(w[1].resetsAt!.timeIntervalSince1970 - 1_793_091_600.123) < 0.01)
    #expect(w[1].detail == "USD 12,40 de 20")
    #expect(w[0].detail == nil)
}

@Test func claudeResetsAtAcceptsOffset() throws {
    let json = #"{"five_hour":{"utilization":1,"resets_at":"2026-10-22T15:00:00-03:00"}}"#
    let w = try ClaudeUsage.windows(from: Data(json.utf8), now: now)
    #expect(w[0].resetsAt == at(1_792_692_000))
}

@Test func claudeProfileIdentity() throws {
    let id = try ClaudeProfile.identity(from: fixture("claude-profile.json"))
    #expect(id.uuid == "11111111-2222-3333-4444-555555555555")
    #expect(id.email == "a@example.com")
}

@Test func codexUsageWindows() throws {
    let w = try CodexUsage.windows(from: fixture("codex-usage.json"), now: now)
    #expect(w == [
        LimitWindow(kind: .session, usedPercent: 22, resetsAt: at(1_792_674_000), duration: 18_000),
        LimitWindow(kind: .weekly, usedPercent: 40, resetsAt: at(1_792_870_400), duration: 604_800),
    ])
}

@Test func codexWindowLengthPicksKind() throws {
    func kind(_ seconds: Int) throws -> WindowKind {
        let json = #"{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":\#(seconds),"reset_after_seconds":60}}}"#
        let w = try CodexUsage.windows(from: Data(json.utf8), now: now)
        #expect(w[0].resetsAt == now.addingTimeInterval(60))
        return w[0].kind
    }
    #expect(try kind(21_600) == .session)
    #expect(try kind(21_601) == .weekly)
    #expect(try kind(604_800) == .weekly)
}

@Test func codexLogRateLimits() throws {
    let w = try CodexUsage.windows(fromLogRateLimits: fixture("codex-log-rate-limits.json"), now: now)
    #expect(w == [
        LimitWindow(kind: .session, usedPercent: 15, resetsAt: now.addingTimeInterval(7200), duration: 18_000),
        LimitWindow(kind: .weekly, usedPercent: 33, resetsAt: at(1_792_870_400), duration: 604_800),
    ])
}

@Test func cursorUsageWindow() throws {
    let w = try CursorUsage.windows(from: fixture("cursor-usage.json"), now: now)
    #expect(w.count == 1)
    #expect(w[0].kind == .billingCycle)
    #expect(w[0].usedPercent == 60)
    #expect(w[0].resetsAt == at(1_793_491_200)) // 2026-11-01T00:00:00Z
    #expect(abs(w[0].duration! - 31 * 86_400) < 0.01)
    #expect(w[0].detail == "USD 5,23 a demanda")
}

@Test func cursorUsageWithoutPercentUsesIncludedSpend() throws {
    // proto3 JSON: int64 as numbers or strings, zero fields omitted.
    let w = try CursorUsage.windows(from: fixture("cursor-usage-no-percent.json"), now: now)
    #expect(w == [LimitWindow(kind: .billingCycle, usedPercent: 25, resetsAt: at(1_793_491_200), duration: 31 * 86_400)])
}

@Test func cursorUsageWithoutPlanIsNoWindow() throws {
    let json = #"{"billingCycleStart":"1790812800000","billingCycleEnd":"1793491200000","enabled":false}"#
    #expect(try CursorUsage.windows(from: Data(json.utf8), now: now).isEmpty)
}

@Test func geminiQuotaWindows() throws {
    let w = try GeminiQuota.windows(from: fixture("gemini-quota.json"), now: now)
    #expect(w == [
        LimitWindow(kind: .dailyModel("gemini-2.5-pro"), usedPercent: 25, resetsAt: at(1_792_713_600), duration: 86_400),
        LimitWindow(kind: .dailyModel("gemini-2.5-flash"), usedPercent: 0, resetsAt: at(1_792_713_600), duration: 86_400),
    ])
}

@Test func copilotUsageWindow() throws {
    let w = try CopilotUsage.windows(from: fixture("copilot-usage.json"), now: now)
    #expect(w == [LimitWindow(kind: .premiumRequests, usedPercent: 60, resetsAt: at(1_793_491_200),
                              duration: nil, detail: "180 de 300")])
}

@Test func copilotFreePlanUsesChatQuota() throws {
    let w = try CopilotUsage.windows(from: fixture("copilot-usage-free.json"), now: now)
    #expect(w == [LimitWindow(kind: .premiumRequests, usedPercent: 80, resetsAt: at(1_793_491_200),
                              duration: nil, detail: "40 de 50")])
}

@Test func copilotUnlimitedIsNoWindow() throws {
    #expect(try CopilotUsage.windows(from: fixture("copilot-usage-unlimited.json"), now: now).isEmpty)
}

@Test func grokSpendWindow() throws {
    let w = try GrokSpend.windows(from: fixture("grok-spend.json"), budget: 20, now: now)
    #expect(w.count == 1)
    #expect(w[0].kind == .monthlyBudget)
    #expect(w[0].usedPercent == 62)
    #expect(w[0].detail == "USD 12,40 de 20")
    #expect(w[0].resetsAt == at(1_793_491_200)) // start of next month, UTC
    #expect(throws: (any Error).self) { try GrokSpend.windows(from: fixture("grok-spend.json"), budget: 0, now: now) }
}

@Test func grokSpendFallsBackToTotalWithCorrection() throws {
    let json = #"{"coreInvoice":{"totalWithCorr":{"val":"500"}},"billingCycle":{"year":2026,"month":10}}"#
    let w = try GrokSpend.windows(from: Data(json.utf8), budget: 10, now: now)
    #expect(w.map(\.usedPercent) == [50])
    #expect(w[0].detail == "USD 5,00 de 10")
}

@Test func malformedResponsesThrowNotCrash() throws {
    let bad: [String] = ["{}", "[]", #"{"five_hour":{"utilization":"#, "", "null"]
    let wrongType: [String: String] = [
        "claude": #"{"five_hour":{"utilization":"high","resets_at":"2026-10-22T18:00:00Z"}}"#,
        "codex": #"{"rate_limit":{"primary_window":{"used_percent":"x"}}}"#,
        "cursor": #"{"billingCycleEnd":"1793491200000","planUsage":{"limit":"x"}}"#,
        "gemini": #"{"buckets":[{"modelId":"m","remainingFraction":"x"}]}"#,
        "copilot": #"{"quota_snapshots":{"premium_interactions":{"percent_remaining":"x"}}}"#,
        "grok": #"{"coreInvoice":{"amountBeforeVat":{"a":1}}}"#,
    ]
    func all(_ s: String) -> [() throws -> Any] {
        let d = Data(s.utf8)
        return [
            { try ClaudeUsage.windows(from: d, now: now) },
            { try CodexUsage.windows(from: d, now: now) },
            { try CodexUsage.windows(fromLogRateLimits: d, now: now) },
            { try CursorUsage.windows(from: d, now: now) },
            { try GeminiQuota.windows(from: d, now: now) },
            { try CopilotUsage.windows(from: d, now: now) },
            { try GrokSpend.windows(from: d, budget: 20, now: now) },
            { try ClaudeProfile.identity(from: d) },
        ]
    }
    for s in bad { for f in all(s) { #expect(throws: (any Error).self) { try f() } } }
    let fns: [String: () throws -> Any] = [
        "claude": { try ClaudeUsage.windows(from: Data(wrongType["claude"]!.utf8), now: now) },
        "codex": { try CodexUsage.windows(from: Data(wrongType["codex"]!.utf8), now: now) },
        "cursor": { try CursorUsage.windows(from: Data(wrongType["cursor"]!.utf8), now: now) },
        "gemini": { try GeminiQuota.windows(from: Data(wrongType["gemini"]!.utf8), now: now) },
        "copilot": { try CopilotUsage.windows(from: Data(wrongType["copilot"]!.utf8), now: now) },
        "grok": { try GrokSpend.windows(from: Data(wrongType["grok"]!.utf8), budget: 20, now: now) },
    ]
    for (_, f) in fns { #expect(throws: (any Error).self) { try f() } }
}

@Test func hugeNumbersThrowNotTrap() {
    let copilot = #"{"quota_snapshots":{"premium_interactions":{"entitlement":1e30,"remaining":5,"percent_remaining":40}}}"#
    #expect(throws: (any Error).self) { try CopilotUsage.windows(from: Data(copilot.utf8), now: now) }
    let claude = #"{"five_hour":{"utilization":1e300},"extra_usage":{"used_credits":1e300,"monthly_limit":1e30}}"#
    _ = try? ClaudeUsage.windows(from: Data(claude.utf8), now: now)
    let grok = #"{"coreInvoice":{"amountBeforeVat":"1e300"}}"#
    _ = try? GrokSpend.windows(from: Data(grok.utf8), budget: 1e30, now: now)
}

@Test func geminiPercentIsClamped() throws {
    let json = #"{"buckets":[{"modelId":"m","remainingFraction":1.5},{"modelId":"n","remainingFraction":-1}]}"#
    let w = try GeminiQuota.windows(from: Data(json.utf8), now: now)
    #expect(w.map(\.usedPercent) == [0, 100])
}

@Test func claudeConfigOAuthAccount() throws {
    let data = Data(#"{"numStartups":3,"oauthAccount":{"accountUuid":"uuid-TEST","emailAddress":"me@example.com","organizationUuid":"org"}}"#.utf8)
    let account = try #require(try ClaudeConfig.oauthAccount(from: data))
    #expect(account.uuid == "uuid-TEST")
    #expect(account.email == "me@example.com")
}

@Test func claudeConfigWithoutOAuthAccountIsLoggedOut() throws {
    #expect(try ClaudeConfig.oauthAccount(from: Data(#"{"numStartups":3}"#.utf8)) == nil)
    #expect(try ClaudeConfig.oauthAccount(from: Data(#"{"oauthAccount":null}"#.utf8)) == nil)
}

/// A half-written file must throw (dir not scanned), not look like a logout.
@Test func claudeConfigTruncatedThrows() {
    #expect(throws: ParseError.self) { try ClaudeConfig.oauthAccount(from: Data(#"{"oauthAccount":{"accountUu"#.utf8)) }
    #expect(throws: ParseError.self) { try ClaudeConfig.oauthAccount(from: Data(#"{"oauthAccount":{"emailAddress":"x"}}"#.utf8)) }
}

@Test func claudeTokenRefreshResponse() throws {
    let previous = OAuthTokens(accessToken: "old", refreshToken: "rt-old", expiresAt: now, extra: ["subscriptionType": "max"])
    let rotated = try ClaudeTokenResponse.tokens(
        from: Data(#"{"access_token":"new","refresh_token":"rt-new","expires_in":28800,"token_type":"Bearer"}"#.utf8),
        previous: previous, now: now)
    #expect(rotated == OAuthTokens(accessToken: "new", refreshToken: "rt-new", expiresAt: now.addingTimeInterval(28_800),
                                   extra: ["subscriptionType": "max"]))
    // Claude Code keeps the old refresh token when the response omits it.
    let kept = try ClaudeTokenResponse.tokens(from: Data(#"{"access_token":"new","expires_in":60}"#.utf8),
                                              previous: previous, now: now)
    #expect(kept.refreshToken == "rt-old")
    #expect(throws: ParseError.self) { try ClaudeTokenResponse.tokens(from: Data(#"{"error":"invalid_grant"}"#.utf8), previous: previous, now: now) }
}

@Test func geminiProjectFromLoadCodeAssist() throws {
    #expect(try GeminiQuota.project(fromLoadCodeAssist: Data(#"{"cloudaicompanionProject":"proj-1"}"#.utf8)) == "proj-1")
    #expect(try GeminiQuota.project(fromLoadCodeAssist: Data(#"{"cloudaicompanionProject":{"id":"proj-2"}}"#.utf8)) == "proj-2")
    #expect(try GeminiQuota.project(fromLoadCodeAssist: Data(#"{"currentTier":{"id":"free-tier"}}"#.utf8)) == nil)
    #expect(throws: (any Error).self) { try GeminiQuota.project(fromLoadCodeAssist: Data("[]".utf8)) }
}
