import Testing
import Foundation
@testable import MateCore

func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(name)
    return try Data(contentsOf: url)
}

@Test func claudeCredentialsDecode() throws {
    let t = try ClaudeCredentials.decode(fixture("claude-credentials.json"))
    #expect(t.accessToken == "sk-ant-oat01-TEST")
    #expect(t.refreshToken == "sk-ant-ort01-TEST")
    #expect(t.expiresAt == Date(timeIntervalSince1970: 1_792_692_000))
    #expect(t.extra["subscriptionType"] == "max")
}

@Test func claudeEncodePreservesUnknownKeys() throws {
    let original = try fixture("claude-credentials.json")
    var t = try ClaudeCredentials.decode(original)
    t.accessToken = "sk-ant-oat01-NEW"
    t.expiresAt = Date(timeIntervalSince1970: 1_792_700_000)
    let out = try ClaudeCredentials.encode(t, preserving: original)
    let root = try #require(JSONSerialization.jsonObject(with: out) as? [String: Any])
    #expect(root["organizationUuid"] as? String == "org-test")
    let oauth = try #require(root["claudeAiOauth"] as? [String: Any])
    #expect(oauth["accessToken"] as? String == "sk-ant-oat01-NEW")
    #expect(oauth["refreshToken"] as? String == "sk-ant-ort01-TEST")
    #expect(oauth["expiresAt"] as? Double == 1_792_700_000_000)
    #expect(oauth["scopes"] as? [String] == ["user:inference", "user:profile"])
    #expect(try ClaudeCredentials.decode(out) == t)
}

@Test func claudeEncodeWithoutOriginalRoundTrips() throws {
    let t = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_792_692_000),
                        extra: ["subscriptionType": "pro"])
    #expect(try ClaudeCredentials.decode(ClaudeCredentials.encode(t, preserving: nil)) == t)
}

@Test func claudeServiceNameForDefaultAndCustomDir() {
    #expect(ClaudeCredentials.keychainService(configDir: nil) == "Claude Code-credentials")
    #expect(ClaudeCredentials.keychainService(configDir: "/tmp/claude-alt") == "Claude Code-credentials-04923786")
}

/// Claude Code hashes `CLAUDE_CONFIG_DIR.normalize("NFC")`, so a decomposed path must hash like its composed form.
@Test func claudeKeychainServiceNormalizesToNFC() {
    let decomposed = "/tmp/cafe\u{301}"
    #expect(ClaudeCredentials.keychainService(configDir: decomposed) == "Claude Code-credentials-0873cca0")
    #expect(ClaudeCredentials.keychainService(configDir: "/tmp/caf\u{e9}") == "Claude Code-credentials-0873cca0")
}

@Test func codexCredentialsDecodeAndEncode() throws {
    let original = try fixture("codex-auth.json")
    var t = try CodexCredentials.decode(original)
    #expect(t.accessToken.hasPrefix("eyJ"))
    #expect(t.refreshToken == "rt-TEST")
    #expect(t.extra["account_id"] == "acct-TEST")
    #expect(t.expiresAt == Date(timeIntervalSince1970: 1_792_692_000))
    t.refreshToken = "rt-NEW"
    let out = try CodexCredentials.encode(t, preserving: original)
    let root = try #require(JSONSerialization.jsonObject(with: out) as? [String: Any])
    #expect(root.keys.contains("OPENAI_API_KEY"))
    #expect(root["last_refresh"] is String)
    let tokens = try #require(root["tokens"] as? [String: Any])
    #expect(tokens["refresh_token"] as? String == "rt-NEW")
    #expect(tokens["account_id"] as? String == "acct-TEST")
}

@Test func jwtEmailFromIdToken() throws {
    let t = try CodexCredentials.decode(fixture("codex-auth.json"))
    let idToken = try #require(t.extra["id_token"])
    let claims = try #require(JWT.claims(idToken))
    #expect(claims["email"] as? String == "a@example.com")
    let auth = claims["https://api.openai.com/auth"] as? [String: Any]
    #expect(auth?["chatgpt_account_id"] as? String == "acct-TEST")
    #expect(JWT.claims("not-a-jwt") == nil)
}

@Test func geminiAndCopilotCredentialsDecode() throws {
    let g = try GeminiCredentials.decode(fixture("gemini-credentials.json"))
    #expect(g.accessToken == "ya29.TEST")
    #expect(g.refreshToken == "1//TEST")
    #expect(g.expiresAt == Date(timeIntervalSince1970: 1_792_692_000))
    let c = try CopilotCredentials.decode(fixture("copilot-apps.json"))
    #expect(c.accessToken == "gho_TEST")
    #expect(c.extra["user"] == "testuser")
}

@Test func malformedCredentialsThrow() {
    let bad: [Data] = [Data("{}".utf8), Data("[]".utf8), Data("{\"claudeAiOauth\":{\"accessToken\":".utf8),
                       Data("{\"claudeAiOauth\":{\"accessToken\":5}}".utf8)]
    for d in bad {
        #expect(throws: (any Error).self) { try ClaudeCredentials.decode(d) }
        #expect(throws: (any Error).self) { try CodexCredentials.decode(d) }
        #expect(throws: (any Error).self) { try GeminiCredentials.decode(d) }
        #expect(throws: (any Error).self) { try CopilotCredentials.decode(d) }
    }
}

@Test func encodeRejectsCorruptOriginal() throws {
    let t = OAuthTokens(accessToken: "a")
    let corrupt = Data("{\"claudeAiOauth\":".utf8)
    #expect(throws: (any Error).self) { try ClaudeCredentials.encode(t, preserving: corrupt) }
    #expect(throws: (any Error).self) { try CodexCredentials.encode(t, preserving: corrupt) }
    _ = try ClaudeCredentials.encode(t, preserving: nil)
}

@Test func codexEncodeStampsGivenNow() throws {
    let out = try CodexCredentials.encode(OAuthTokens(accessToken: "a"), preserving: nil,
                                          now: Date(timeIntervalSince1970: 1_792_670_400))
    let root = try #require(JSONSerialization.jsonObject(with: out) as? [String: Any])
    #expect(root["last_refresh"] as? String == "2026-10-22T12:00:00Z")
}

@Test func copilotDecodeSkipsBadEntry() throws {
    let json = #"{"github.com:a":{"oauth_token":5},"github.com:b":{"oauth_token":"gho_OK"}}"#
    #expect(try CopilotCredentials.decode(Data(json.utf8)).accessToken == "gho_OK")
}

@Test func copilotDecodeOnlyTakesGitHubDotCom() throws {
    // A GitHub Enterprise token must never be sent to api.github.com.
    let json = #"{"ghe.example.com:Iv1.x":{"user":"corp","oauth_token":"gho_GHE"}}"#
    #expect(throws: (any Error).self) { try CopilotCredentials.decode(Data(json.utf8)) }
    let mixed = #"{"aaa.example.com:Iv1.x":{"user":"corp","oauth_token":"gho_GHE"},"github.com:Iv1.y":{"user":"me","oauth_token":"gho_OK"}}"#
    #expect(try CopilotCredentials.decode(Data(mixed.utf8)).accessToken == "gho_OK")
}

@Test func copilotDecodeReadsLegacyHostsFile() throws {
    let t = try CopilotCredentials.decode(fixture("copilot-hosts.json"))
    #expect(t.accessToken == "gho_HOSTS")
    #expect(t.extra["user"] == "hostuser")
}

@Test func ghHostsUserIsGitHubDotComOnly() throws {
    let yaml = try #require(String(data: fixture("gh-hosts.yml"), encoding: .utf8))
    #expect(GhHosts.user(fromYAML: yaml) == "testuser")
    #expect(GhHosts.user(fromYAML: "ghe.example.com:\n    user: corp\n") == nil)
    #expect(GhHosts.user(fromYAML: "github.com:\n    oauth_token: x\n    user: \"quoted\"\n") == "quoted")
    #expect(GhHosts.user(fromYAML: "") == nil)
}

@Test func cursorIdentityFromTokenSubject() {
    // {"sub":"auth0|user_TEST","exp":1792692000}
    let token = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhdXRoMHx1c2VyX1RFU1QiLCJleHAiOjE3OTI2OTIwMDB9.sig"
    #expect(CursorSession.identity(accessToken: token, email: "me@example.com") == "auth0|user_TEST")
    #expect(CursorSession.identity(accessToken: "opaque", email: "me@example.com") == "me@example.com")
    #expect(CursorSession.identity(accessToken: "opaque", email: nil) == nil)
    #expect(CursorSession.identity(accessToken: "", email: "me@example.com") == nil)
    let t = CursorSession.tokens(accessToken: token)
    #expect(t.expiresAt == Date(timeIntervalSince1970: 1_792_692_000))
}

@Test func geminiIdentityFromIdToken() throws {
    // {"sub":"1234","email":"g@example.com"}
    let creds = #"{"access_token":"ya29.x","id_token":"eyJhbGciOiJub25lIn0.eyJzdWIiOiIxMjM0IiwiZW1haWwiOiJnQGV4YW1wbGUuY29tIn0.sig"}"#
    let id = try #require(try GeminiCredentials.identity(from: Data(creds.utf8)))
    #expect(id.identity == "1234")
    #expect(id.email == "g@example.com")
    #expect(try GeminiCredentials.identity(from: Data(#"{"access_token":"ya29.x"}"#.utf8)) == nil)
    #expect(throws: (any Error).self) { try GeminiCredentials.identity(from: Data("{".utf8)) }
}
