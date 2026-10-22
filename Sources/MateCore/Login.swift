import Foundation
import CryptoKit
import Security

public enum LoginError: Error, Equatable, Sendable {
    /// The pasted text is not a "code#state".
    case invalidCode
    /// The code belongs to another sign-in.
    case stateMismatch
    /// The provider refused (the user cancelled on its page) or the callback had no code.
    case denied(String)
    case timedOut
    case cancelled
    /// The loopback port is taken (another sign-in is open).
    case portInUse
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// RFC 7636 proof key, S256.
public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        challenge = Self.challenge(for: verifier)
    }

    /// 32 random bytes: a 43-character verifier.
    public static func random() -> PKCE { PKCE(verifier: randomToken()) }

    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// 32 random bytes, base64url (also used for `state`).
    public static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var g = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &g) }
        }
        return Base64URL.encode(Data(bytes))
    }
}

/// `application/x-www-form-urlencoded` with only unreserved characters left as they are.
enum FormEncoding {
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ pairs: [(String, String)]) -> Data {
        Data(pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&").utf8)
    }

    static func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
}

/// Claude Code's claude.ai sign-in with the manual redirect (Anthropic shows a "code#state" to paste).
/// Verified against Claude Code 2.1.308: `CLAUDE_AI_AUTHORIZE_URL`, `MANUAL_REDIRECT_URL`, the scope list and the
/// JSON body of the authorization-code exchange.
public enum ClaudeLogin {
    public static let authorizeBase = "https://claude.com/cai/oauth/authorize"
    public static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    public static let scopes = ["org:create_api_key", "user:profile", "user:inference", "user:sessions:claude_code",
                                "user:mcp_servers", "user:file_upload", "user:plugins"]

    public static func authorizeURL(clientID: String, challenge: String, state: String) -> URL {
        var c = URLComponents(string: authorizeBase)!
        c.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return c.url!
    }

    /// The authorization code from what the user pasted: "code#state" as Anthropic shows it, or the callback URL.
    public static func code(fromPasted text: String, expectedState: String) throws -> String {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let code: String, state: String
        if s.contains("code="), let items = URLComponents(string: s)?.queryItems {
            code = items.first { $0.name == "code" }?.value ?? ""
            state = items.first { $0.name == "state" }?.value ?? ""
        } else {
            let parts = s.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw LoginError.invalidCode }
            code = String(parts[0])
            state = String(parts[1])
        }
        guard !code.isEmpty, !state.isEmpty else { throw LoginError.invalidCode }
        guard state == expectedState else { throw LoginError.stateMismatch }
        return code
    }

    public static func exchangeBody(code: String, state: String, verifier: String, clientID: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": clientID, "code_verifier": verifier, "state": state,
        ], options: [.sortedKeys])
    }
}

/// Codex CLI's ChatGPT sign-in: PKCE with a loopback callback. Client id, issuer, callback path, the extra
/// authorize parameters and the form-encoded exchange verified against codex-cli 0.153.0-alpha.5; the port (a
/// numeric constant, not visible in the binary's strings) is the one Codex documents.
public enum CodexLogin {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let issuer = "https://auth.openai.com"
    public static let tokenURL = URL(string: issuer + "/oauth/token")!
    public static let port: UInt16 = 1455
    public static let redirectURI = "http://localhost:1455/auth/callback"
    public static let scope = "openid profile email offline_access"

    public static func authorizeURL(challenge: String, state: String) -> URL {
        var c = URLComponents(string: issuer + "/oauth/authorize")!
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
        ]
        return c.url!
    }

    public enum Callback: Equatable, Sendable {
        case code(String)
        case denied(String)
        case stateMismatch
        /// Another request (favicon…): answer 404 and keep waiting.
        case notCallback
    }

    /// Interprets the head of an HTTP request that reached the loopback listener.
    public static func callback(requestHead: String, expectedState: String) -> Callback {
        let line = requestHead.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET",
              let c = URLComponents(string: "http://localhost" + parts[1]), c.path == "/auth/callback" else {
            return .notCallback
        }
        func value(_ name: String) -> String? { c.queryItems?.first { $0.name == name }?.value }
        guard value("state") == expectedState else { return .stateMismatch }
        if let error = value("error") { return .denied(error) }
        guard let code = value("code"), !code.isEmpty else { return .denied("missing_authorization_code") }
        return .code(code)
    }

    public static func exchangeBody(code: String, verifier: String) -> Data {
        FormEncoding.encode([("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
                             ("client_id", clientID), ("code_verifier", verifier)])
    }

    /// Refresh body (JSON) as the brief specifies.
    public static func refreshBody(refreshToken: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken,
            "scope": "openid profile email",
        ], options: [.sortedKeys])
    }
}
