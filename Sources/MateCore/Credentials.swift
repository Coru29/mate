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
        if let scopes = try J.array(o, "scopes") { extra["scopes"] = scopes.compactMap { $0 as? String }.joined(separator: " ") }
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
        if let s = t.extra["scopes"] { o["scopes"] = s.split(separator: " ").map(String.init) }
        root["claudeAiOauth"] = o
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Keychain service holding Claude Code's credentials (keychain account = `$USER`).
    /// Verified against Claude Code 2.1.308: with `CLAUDE_CONFIG_DIR` set (to anything non-empty, even `~/.claude`)
    /// the suffix is `-` + the first 8 lowercase hex chars of SHA-256 over the variable's exact value, NFC-normalized;
    /// unset, there is no suffix. Pass `nil` for the default dir and the raw `CLAUDE_CONFIG_DIR` value otherwise.
    public static func keychainService(configDir: String?) -> String {
        let base = "Claude Code-credentials"
        guard let dir = configDir, !dir.isEmpty else { return base }
        let nfc = dir.precomposedStringWithCanonicalMapping
        let hex = SHA256.hash(data: Data(nfc.utf8)).map { String(format: "%02x", $0) }.joined()
        return base + "-" + hex.prefix(8)
    }
}

/// Which of the items of Claude Code's keychain service is its session.
public enum ClaudeKeychainLookup: Equatable, Sendable {
    /// The item's account attribute.
    case found(String)
    /// No item: no keychain session.
    case none
    /// Items exist but none can be told to be Claude Code's: not a logout, the dir counts as unread.
    case ambiguous

    /// The item named after the macOS user (what Claude Code writes), else the only one. A stray item of the same
    /// service is never read as the session.
    public static func classify(names: [String], userName: String) -> Self {
        if names.contains(userName) { return .found(userName) }
        if names.isEmpty { return .none }
        return names.count == 1 ? .found(names[0]) : .ambiguous
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

/// The ChatGPT identity in a Codex `id_token`: the workspace (`https://api.openai.com/auth.chatgpt_account_id`,
/// what the usage request names) and the user in it (`chatgpt_user_id`, else `sub`), so two users of one Team
/// workspace are two accounts. The identity is "<accountID>:<userID>" (just the account id when the token names no
/// user); the email comes from `email` (or `https://api.openai.com/profile.email`).
public enum CodexIdentity {
    public static func from(idToken: String) -> (accountID: String, identity: String, email: String?)? {
        guard let claims = JWT.claims(idToken),
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let account = auth["chatgpt_account_id"] as? String, !account.isEmpty else { return nil }
        let email = claims["email"] as? String
            ?? (claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String
        let user = [auth["chatgpt_user_id"] as? String, claims["sub"] as? String].compactMap { $0 }.first { !$0.isEmpty }
        return (account, user.map { "\(account):\($0)" } ?? account, email)
    }

    /// The identity Mate used before the user part existed (the workspace id alone), or nil when `identity` has no
    /// user part.
    public static func legacyIdentity(of identity: String) -> String? {
        guard let colon = identity.firstIndex(of: ":") else { return nil }
        return String(identity[..<colon])
    }
}

/// Codex's `auth.json` (a plain file: reading it never prompts).
public enum CodexAuthFile {
    /// The ChatGPT session, or nil when there is none (logged out, or API-key mode). Throws when the file is not
    /// valid JSON or holds tokens without an identity, so a half-written file is never mistaken for a logout.
    public static func session(from data: Data) throws -> (identity: String, email: String?)? {
        let root = try J.object(data)
        guard let t = try J.dict(root, "tokens"), try J.string(t, "access_token") != nil else { return nil }
        if let id = try J.string(t, "id_token"), let identity = CodexIdentity.from(idToken: id) {
            return (identity.identity, identity.email)
        }
        guard let account = try J.string(t, "account_id"), !account.isEmpty else {
            throw ParseError.malformed("tokens without an account id")
        }
        return (account, nil)
    }
}

/// `~/.gemini/oauth_creds.json`. UNVERIFIED (Gemini CLI is not installed on the build Mac):
/// `{access_token, refresh_token, expiry_date(ms), id_token}`. Mate never refreshes it.
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

    /// The Google account of the session (`sub` and `email` of the `id_token`), or nil when there is none.
    /// Throws when the file is not valid JSON, so a half-written file is not taken as a logout.
    public static func identity(from data: Data) throws -> (identity: String, email: String?)? {
        let o = try J.object(data)
        guard try J.string(o, "access_token") != nil, let id = try J.string(o, "id_token"),
              let claims = JWT.claims(id), let sub = claims["sub"] as? String, !sub.isEmpty else { return nil }
        return (sub, claims["email"] as? String)
    }
}

/// GitHub Copilot's token files in `~/.config/github-copilot` (or `$XDG_CONFIG_HOME/github-copilot`). Verified
/// against @github/copilot-language-server 1.462.0: `apps.json` is `{"<host>:<app id>": {user, oauth_token,
/// githubAppId}}`; the legacy `hosts.json` is `{"<host>": {user, oauth_token}}` (migrated into `apps.json`).
/// Only `github.com` entries are used: their token goes to api.github.com, never an Enterprise host's.
public enum CopilotCredentials {
    public static func decode(_ data: Data) throws -> OAuthTokens {
        let root = try J.object(data)
        for key in root.keys.sorted() where key == "github.com" || key.hasPrefix("github.com:") {
            guard let entry = root[key] as? [String: Any], let token = try? J.string(entry, "oauth_token"),
                  !token.isEmpty else { continue }
            var extra: [String: String] = [:]
            if let u = try? J.string(entry, "user") { extra["user"] = u }
            return OAuthTokens(accessToken: token, extra: extra)
        }
        throw ParseError.malformed("no github.com oauth_token entry")
    }
}

/// The `gh` CLI's `hosts.yml`: only the `user:` of the `github.com` block is read (never a token).
public enum GhHosts {
    public static func user(fromYAML yaml: String) -> String? {
        var inGitHub = false
        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let first = line.first, first != " ", first != "\t", first != "#" {
                inGitHub = line.trimmingCharacters(in: .whitespaces) == "github.com:"
                continue
            }
            guard inGitHub else { continue }
            // Direct children only (4 spaces in gh's own output; 2 tolerated), not the nested `users:` map.
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)
            guard indent <= 4, body.hasPrefix("user:") else { continue }
            var value = body.dropFirst("user:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// Cursor's session in `state.vscdb` (`cursorAuth/accessToken`, `cursorAuth/cachedEmail`). The identity is the
/// token's JWT `sub` (stable across email changes), else the email.
public enum CursorSession {
    public static func identity(accessToken: String, email: String?) -> String? {
        guard !accessToken.isEmpty else { return nil }
        if let sub = JWT.claims(accessToken)?["sub"] as? String, !sub.isEmpty { return sub }
        if let email, !email.isEmpty { return email }
        return nil
    }

    public static func tokens(accessToken: String) -> OAuthTokens {
        OAuthTokens(accessToken: accessToken, expiresAt: JWT.expiry(accessToken))
    }
}
