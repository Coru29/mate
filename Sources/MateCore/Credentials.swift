import Foundation
import CryptoKit

public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    /// subscriptionType, account_id, id_token, user…
    public var extra: [String: String]

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
                extra: [String: String] = [:]) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.extra = extra
    }
}

public enum JWT {
    /// Claims of an unverified JWT payload, or nil when the token is not a JWT.
    public static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    static func expiry(_ token: String) -> Date? {
        guard let exp = claims(token)?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }
}

public enum ClaudeCredentials {
    public static func decode(_ data: Data) throws -> OAuthTokens {
        let root = try J.object(data)
        guard let o = try J.dict(root, "claudeAiOauth"), let access = try J.string(o, "accessToken") else {
            throw ParseError.malformed("claudeAiOauth.accessToken missing")
        }
        var extra: [String: String] = [:]
        if let s = try J.string(o, "subscriptionType") { extra["subscriptionType"] = s }
        let expires = try J.double(o, "expiresAt").map { Date(timeIntervalSince1970: $0 / 1000) }
        return OAuthTokens(accessToken: access, refreshToken: try J.string(o, "refreshToken"),
                           expiresAt: expires, extra: extra)
    }

    /// Writes the tokens into `original` (when given and valid), leaving every other key untouched.
    public static func encode(_ t: OAuthTokens, preserving original: Data?) throws -> Data {
        var root = try original.map { try J.object($0) } ?? [:]
        var o = (root["claudeAiOauth"] as? [String: Any]) ?? [:]
        o["accessToken"] = t.accessToken
        if let r = t.refreshToken { o["refreshToken"] = r }
        if let e = t.expiresAt { o["expiresAt"] = (e.timeIntervalSince1970 * 1000).rounded() }
        if let s = t.extra["subscriptionType"] { o["subscriptionType"] = s }
        root["claudeAiOauth"] = o
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Keychain service holding Claude Code's credentials.
    /// UNVERIFIED — confirm in Task 8: for a custom config dir the suffix is assumed to be the first 8 lowercase
    /// hex chars of SHA-256 over the UTF-8 config dir path.
    public static func keychainService(configDir: String?) -> String {
        let base = "Claude Code-credentials"
        guard let dir = configDir, !dir.isEmpty else { return base }
        let hex = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
        return base + "-" + hex.prefix(8)
    }
}

public enum CodexCredentials {
    public static func decode(_ data: Data) throws -> OAuthTokens {
        let root = try J.object(data)
        guard let t = try J.dict(root, "tokens"), let access = try J.string(t, "access_token") else {
            throw ParseError.malformed("tokens.access_token missing")
        }
        var extra: [String: String] = [:]
        for k in ["id_token", "account_id"] { if let s = try J.string(t, k) { extra[k] = s } }
        return OAuthTokens(accessToken: access, refreshToken: try J.string(t, "refresh_token"),
                           expiresAt: JWT.expiry(access), extra: extra)
    }

    public static func encode(_ t: OAuthTokens, preserving original: Data?, now: Date = Date()) throws -> Data {
        var root = try original.map { try J.object($0) } ?? [:]
        var o = (root["tokens"] as? [String: Any]) ?? [:]
        o["access_token"] = t.accessToken
        if let r = t.refreshToken { o["refresh_token"] = r }
        for k in ["id_token", "account_id"] { if let v = t.extra[k] { o[k] = v } }
        root["tokens"] = o
        root["last_refresh"] = ISO8601DateFormatter().string(from: now)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

/// `~/.gemini/oauth_creds.json`. UNVERIFIED — confirm in Task 11: `{access_token, refresh_token, expiry_date(ms), id_token}`.
public enum GeminiCredentials {
    public static func decode(_ data: Data) throws -> OAuthTokens {
        let o = try J.object(data)
        guard let access = try J.string(o, "access_token") else { throw ParseError.malformed("access_token missing") }
        var extra: [String: String] = [:]
        if let s = try J.string(o, "id_token") { extra["id_token"] = s }
        return OAuthTokens(accessToken: access, refreshToken: try J.string(o, "refresh_token"),
                           expiresAt: try J.double(o, "expiry_date").map { Date(timeIntervalSince1970: $0 / 1000) },
                           extra: extra)
    }
}

/// GitHub Copilot's `apps.json`. UNVERIFIED — confirm in Task 13:
/// `{"github.com:<client id>": {"user", "oauth_token"}}`; the first entry with an `oauth_token` wins.
public enum CopilotCredentials {
    public static func decode(_ data: Data) throws -> OAuthTokens {
        let root = try J.object(data)
        for key in root.keys.sorted() {
            guard let entry = root[key] as? [String: Any], let token = try? J.string(entry, "oauth_token") else { continue }
            var extra: [String: String] = [:]
            if let u = try? J.string(entry, "user") { extra["user"] = u }
            return OAuthTokens(accessToken: token, extra: extra)
        }
        throw ParseError.malformed("no oauth_token entry")
    }
}
