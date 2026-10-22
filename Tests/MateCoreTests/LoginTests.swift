import Testing
import Foundation
@testable import MateCore

/// An unsigned JWT with `claims` as its payload.
private func jwt(_ claims: [String: Any]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    return "eyJhbGciOiJub25lIn0." + Base64URL.encode(payload) + ".sig"
}

private func query(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
}

@Test func pkceChallengeIsS256OfVerifier() {
    // RFC 7636 appendix B.
    #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let p = PKCE.random()
    #expect(p.verifier.count == 43)
    #expect(!p.verifier.contains("=") && !p.verifier.contains("+") && !p.verifier.contains("/"))
    #expect(p.challenge == PKCE.challenge(for: p.verifier))
    #expect(PKCE.random().verifier != p.verifier)
}

@Test func claudeAuthorizeURLMatchesClaudeCode() {
    let url = ClaudeLogin.authorizeURL(clientID: "cid", challenge: "ch", state: "st")
    #expect(url.absoluteString.hasPrefix("https://claude.com/cai/oauth/authorize?code=true&"))
    let q = query(url)
    #expect(q["client_id"] == "cid")
    #expect(q["response_type"] == "code")
    #expect(q["redirect_uri"] == "https://platform.claude.com/oauth/code/callback")
    #expect(q["scope"] == "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload user:plugins")
    #expect(q["code_challenge"] == "ch")
    #expect(q["code_challenge_method"] == "S256")
    #expect(q["state"] == "st")
}

@Test func claudePastedCodeNeedsMatchingState() throws {
    #expect(try ClaudeLogin.code(fromPasted: "  abc#st \n", expectedState: "st") == "abc")
    // The whole callback URL works too.
    #expect(try ClaudeLogin.code(fromPasted: "https://platform.claude.com/oauth/code/callback?code=abc&state=st",
                                 expectedState: "st") == "abc")
    #expect(throws: LoginError.invalidCode) { try ClaudeLogin.code(fromPasted: "abc", expectedState: "st") }
    #expect(throws: LoginError.invalidCode) { try ClaudeLogin.code(fromPasted: "#st", expectedState: "st") }
    #expect(throws: LoginError.stateMismatch) { try ClaudeLogin.code(fromPasted: "abc#other", expectedState: "st") }
}

@Test func claudeExchangeBodyMatchesClaudeCode() throws {
    let body = try ClaudeLogin.exchangeBody(code: "abc", state: "st", verifier: "ver", clientID: "cid")
    let o = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(o == ["grant_type": "authorization_code", "code": "abc", "state": "st", "code_verifier": "ver",
                  "client_id": "cid", "redirect_uri": "https://platform.claude.com/oauth/code/callback"])
}

@Test func claudeLoginTokensKeepScopes() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let data = Data(#"{"access_token":"at","refresh_token":"rt","expires_in":3600,"scope":"user:profile user:inference"}"#.utf8)
    let t = try ClaudeTokenResponse.tokens(from: data, previous: OAuthTokens(accessToken: ""), now: now)
    #expect(t.accessToken == "at" && t.refreshToken == "rt")
    #expect(t.expiresAt == now.addingTimeInterval(3600))
    #expect(t.extra["scopes"] == "user:profile user:inference")
    let blob = try ClaudeCredentials.encode(t, preserving: nil)
    let o = try #require((JSONSerialization.jsonObject(with: blob) as? [String: Any])?["claudeAiOauth"] as? [String: Any])
    #expect(o["scopes"] as? [String] == ["user:profile", "user:inference"])
    #expect(try ClaudeCredentials.decode(blob).extra["scopes"] == "user:profile user:inference")
}

@Test func codexAuthorizeURLMatchesCodexCLI() {
    let url = CodexLogin.authorizeURL(challenge: "ch", state: "st")
    #expect(url.absoluteString.hasPrefix("https://auth.openai.com/oauth/authorize?"))
    let q = query(url)
    #expect(q["response_type"] == "code")
    #expect(q["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
    #expect(q["redirect_uri"] == "http://localhost:1455/auth/callback")
    #expect(q["scope"] == "openid profile email offline_access")
    #expect(q["code_challenge"] == "ch" && q["code_challenge_method"] == "S256")
    #expect(q["id_token_add_organizations"] == "true" && q["codex_cli_simplified_flow"] == "true")
    #expect(q["state"] == "st")
}

@Test func codexCallbackParsing() {
    let ok = "GET /auth/callback?code=a%2Bb&scope=x&state=st HTTP/1.1\r\nHost: localhost:1455\r\n\r\n"
    #expect(CodexLogin.callback(requestHead: ok, expectedState: "st") == .code("a+b"))
    #expect(CodexLogin.callback(requestHead: "GET /auth/callback?code=a&state=zz HTTP/1.1\r\n\r\n", expectedState: "st") == .stateMismatch)
    #expect(CodexLogin.callback(requestHead: "GET /auth/callback?error=access_denied&error_description=No&state=st HTTP/1.1\r\n\r\n",
                                expectedState: "st") == .denied("access_denied"))
    #expect(CodexLogin.callback(requestHead: "GET /auth/callback?state=st HTTP/1.1\r\n\r\n", expectedState: "st") == .denied("missing_authorization_code"))
    #expect(CodexLogin.callback(requestHead: "GET /favicon.ico HTTP/1.1\r\n\r\n", expectedState: "st") == .notCallback)
    #expect(CodexLogin.callback(requestHead: "garbage", expectedState: "st") == .notCallback)
}

@Test func codexExchangeBodyIsFormEncoded() {
    let body = String(decoding: CodexLogin.exchangeBody(code: "a+b/c=", verifier: "v-1"), as: UTF8.self)
    #expect(body == "grant_type=authorization_code&code=a%2Bb%2Fc%3D"
        + "&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&client_id=app_EMoamEEZ73f0CkXaXp7hrann&code_verifier=v-1")
}

@Test func codexIdentityFromIdTokenClaims() {
    let id = jwt(["email": "a@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"]])
    #expect(CodexIdentity.from(idToken: id)?.accountID == "acct-1")
    #expect(CodexIdentity.from(idToken: id)?.email == "a@example.com")
    let profileEmail = jwt(["https://api.openai.com/profile": ["email": "p@example.com"],
                            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-2"]])
    #expect(CodexIdentity.from(idToken: profileEmail)?.email == "p@example.com")
    #expect(CodexIdentity.from(idToken: jwt(["email": "a@example.com"])) == nil)
    #expect(CodexIdentity.from(idToken: "nope") == nil)
}

@Test func codexAuthFileSession() throws {
    let s = try #require(try CodexAuthFile.session(from: fixture("codex-auth.json")))
    #expect(s.identity == "acct-TEST" && s.email == "a@example.com")
    // API-key mode or logged out: no ChatGPT session, definitively.
    #expect(try CodexAuthFile.session(from: Data(#"{"OPENAI_API_KEY":"sk-x","tokens":null}"#.utf8)) == nil)
    #expect(try CodexAuthFile.session(from: Data(#"{"OPENAI_API_KEY":"sk-x"}"#.utf8)) == nil)
    // Without an id_token the stored account_id is the identity.
    let bare = try CodexAuthFile.session(from: Data(#"{"tokens":{"access_token":"x","account_id":"acct-9"}}"#.utf8))
    #expect(bare?.identity == "acct-9" && bare?.email == nil)
    // A half-written file throws, so it is never mistaken for a logout.
    #expect(throws: (any Error).self) { try CodexAuthFile.session(from: Data(#"{"tokens":{"access_tok"#.utf8)) }
    #expect(throws: (any Error).self) { try CodexAuthFile.session(from: Data(#"{"tokens":{"access_token":"x"}}"#.utf8)) }
}

@Test func codexTokenResponseUpdatesTokens() throws {
    let access = jwt(["exp": 2_000_000_000])
    let id = jwt(["email": "a@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"]])
    let data = try JSONSerialization.data(withJSONObject: ["access_token": access, "refresh_token": "rt2", "id_token": id])
    let previous = OAuthTokens(accessToken: "old", refreshToken: "rt1", extra: ["account_id": "acct-0", "id_token": "old"])
    let t = try CodexTokenResponse.tokens(from: data, previous: previous)
    #expect(t.accessToken == access && t.refreshToken == "rt2")
    #expect(t.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
    #expect(t.extra["id_token"] == id && t.extra["account_id"] == "acct-1")
    // A refresh that returns only an access token keeps the rest.
    let partial = try JSONSerialization.data(withJSONObject: ["access_token": access])
    let p = try CodexTokenResponse.tokens(from: partial, previous: previous)
    #expect(p.refreshToken == "rt1" && p.extra["id_token"] == "old" && p.extra["account_id"] == "acct-0")
    #expect(throws: (any Error).self) { try CodexTokenResponse.tokens(from: Data("{}".utf8), previous: previous) }
}

@Test func codexLatestRateLimitsFromLogTail() throws {
    let lines = [
        #"{"timestamp":"2026-10-21T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1792870000}}}}"#,
        #"{"timestamp":"2026-10-21T10:05:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":12.0,"window_minutes":10080,"resets_at":1792870400},"secondary":null}}}"#,
        #"{"timestamp":"2026-10-21T10:06:00.000Z","type":"response_item","payload":{"type":"message"}}"#,
    ]
    // The tail starts mid-line: the partial first line is skipped.
    let tail = Data(("ll,\"x\":1}}\n" + lines.joined(separator: "\n") + "\n").utf8)
    let w = try #require(CodexLogTail.latestRateLimits(in: tail))
    #expect(w.count == 1)
    #expect(w[0].kind == .weekly && w[0].usedPercent == 12)
    #expect(w[0].resetsAt == Date(timeIntervalSince1970: 1_792_870_400))
    #expect(CodexLogTail.latestRateLimits(in: Data(lines[2].utf8)) == nil)
}

@Test func configDirPathsKeepTheShellForm() {
    let c = { (p: String) in LogDirs.canonicalConfigDir(p, home: "/Users/u", cwd: "/work") }
    #expect(c("~/.claude-work/") == "/Users/u/.claude-work")
    #expect(c("/private/tmp/x//") == "/private/tmp/x")
    #expect(c("rel/dir") == "/work/rel/dir")
    #expect(c("/") == "/")
}

@Test func logFallbackClampsResetWindows() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let session = LimitWindow(kind: .session, usedPercent: 80, resetsAt: now.addingTimeInterval(-60), duration: 18_000)
    let weekly = LimitWindow(kind: .weekly, usedPercent: 40, resetsAt: now.addingTimeInterval(86_400), duration: 604_800)
    // The session window already reset: 0 % and no reset time; the weekly one is still current.
    let w = CodexLogTail.fallback([session, weekly], fileModified: now.addingTimeInterval(-3600), now: now)
    #expect(w?.count == 2)
    #expect(w?[0].usedPercent == 0 && w?[0].resetsAt == nil)
    #expect(w?[1].usedPercent == 40 && w?[1].resetsAt == weekly.resetsAt)
    // A log older than the longest window says nothing about now.
    #expect(CodexLogTail.fallback([session, weekly], fileModified: now.addingTimeInterval(-604_801), now: now) == nil)
    #expect(CodexLogTail.fallback([], fileModified: now, now: now) == nil)
}
