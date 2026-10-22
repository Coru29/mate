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
