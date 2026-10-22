import Foundation
import MateCore

/// Claude Code. Endpoints, client id, keychain naming and file layout verified against Claude Code 2.1.308.
final class ClaudeProvider: Provider, @unchecked Sendable {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let betaHeader = "oauth-2025-04-20"
    /// Canonical name of the default config dir (used when `CLAUDE_CONFIG_DIR` is unset).
    static let defaultDir = "~/.claude"

    let id = ProviderID.claude
    private let lock = NSLock()
    private var _extraConfigDirs: [String] = []

    var extraConfigDirs: [String] {
        get { lock.withLock { _extraConfigDirs } }
        set { lock.withLock { _extraConfigDirs = newValue.filter { $0 != Self.defaultDir } } }
    }

    private var configDirs: [String] { [Self.defaultDir] + extraConfigDirs }

    var watchedPaths: [String] { configDirs.map { projectsDir($0) } }
    var sessionFiles: [String] { configDirs.map { configFile($0) } }

    // MARK: Layout

    /// Claude Code's `.claude.json`: `~/.claude.json` by default, `<dir>/.claude.json` with `CLAUDE_CONFIG_DIR`.
    private func configFile(_ dir: String) -> String {
        dir == Self.defaultDir ? "~/.claude.json".expandingTilde : (dir.expandingTilde as NSString).appendingPathComponent(".claude.json")
    }

    private func projectsDir(_ dir: String) -> String {
        (dir.expandingTilde as NSString).appendingPathComponent("projects")
    }

    /// Plaintext fallback Claude Code uses when the keychain is unavailable.
    private func credentialsFile(_ dir: String) -> String {
        (dir.expandingTilde as NSString).appendingPathComponent(".credentials.json")
    }

    private func keychainService(_ dir: String) -> String {
        ClaudeCredentials.keychainService(configDir: dir == Self.defaultDir ? nil : dir)
    }

    /// The account of Claude Code's item (nil: no item), found from attributes only (no prompt). Throws when the
    /// keychain cannot be read or the items are ambiguous: neither may look like a logout.
    private func keychainAccount(_ dir: String) throws -> String? {
        switch ClaudeKeychainLookup.classify(names: try Keychain.accountNames(service: keychainService(dir)), userName: NSUserName()) {
        case .found(let account): return account
        case .none: return nil
        case .ambiguous: throw ProviderError.unavailable("ambiguous keychain items")
        }
    }

    // MARK: Sessions

    func observeSessions() async -> SessionScan {
        var sessions: [ObservedSession] = []
        var scanned = Set<String>()
        for dir in configDirs {
            do {
                // Attributes only: no keychain prompt just to know whether the agent is logged in.
                let hasCredentials = try keychainAccount(dir) != nil
                    || FileManager.default.fileExists(atPath: credentialsFile(dir))
                let file = configFile(dir)
                var account: (uuid: String, email: String?)?
                if FileManager.default.fileExists(atPath: file) {
                    account = try ClaudeConfig.oauthAccount(from: Data(contentsOf: URL(fileURLWithPath: file)))
                }
                scanned.insert(dir)
                if hasCredentials, let account {
                    sessions.append(ObservedSession(provider: .claude, configDir: dir, identity: account.uuid,
                                                    email: account.email))
                }
            } catch {
                Log.error("claude: could not read session in \(dir): \(error)")
            }
        }
        return SessionScan(sessions: sessions, scannedDirs: scanned)
    }

    func agentCredentials(configDir: String) async throws -> Data? {
        do {
            if let account = try keychainAccount(configDir),
               let data = try Keychain.readForeign(service: keychainService(configDir), account: account) { return data }
        } catch let e as KeychainError where e.isDenied {
            throw ProviderError.credentialsDenied
        }
        let file = credentialsFile(configDir)
        guard FileManager.default.fileExists(atPath: file) else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: file))
    }

    func decodeCredentials(_ data: Data) throws -> OAuthTokens { try ClaudeCredentials.decode(data) }

    func credentialsIdentity(_ data: Data) async throws -> String? {
        try await Self.profile(accessToken: decodeCredentials(data).accessToken).uuid
    }

    func encodeCredentials(_ tokens: OAuthTokens, preserving original: Data?) throws -> Data {
        try ClaudeCredentials.encode(tokens, preserving: original)
    }

    // MARK: Network (api.anthropic.com and platform.claude.com only)

    func fetchUsage(account: Account, tokens: OAuthTokens) async throws -> [LimitWindow] {
        var req = URLRequest(url: Self.usageURL)
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await HTTP.json(req)
        try ProviderError.check(status: status)
        return try ClaudeUsage.windows(from: data, now: Date())
    }

    func exchangeRefreshToken(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refresh = tokens.refreshToken else { throw ProviderError.unauthorized }
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": Self.clientID,
        ])
        let (data, status) = try await HTTP.json(req)
        // invalid_grant (revoked or already rotated) comes back as 400.
        if status == 400 { throw ProviderError.unauthorized }
        try ProviderError.check(status: status)
        return try ClaudeTokenResponse.tokens(from: data, previous: tokens, now: Date())
    }

    /// The signed-in account of an access token (for "Agregar cuenta…").
    static func profile(accessToken: String) async throws -> (uuid: String, email: String?) {
        var req = URLRequest(url: profileURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await HTTP.json(req)
        try ProviderError.check(status: status)
        return try ClaudeProfile.identity(from: data)
    }

    // MARK: Logs

    func logFiles(in paths: [String]) -> [String] {
        let roots = watchedPaths.flatMap { [$0, URL(fileURLWithPath: $0).resolvingSymlinksInPath().path] }
        let fm = FileManager.default
        var out: [String] = []
        for path in paths where roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if path.hasSuffix(".jsonl") { out.append(path) }
                continue
            }
            guard let e = fm.enumerator(atPath: path) else { continue }
            for case let rel as String in e where rel.hasSuffix(".jsonl") {
                out.append((path as NSString).appendingPathComponent(rel))
            }
        }
        return Array(Set(out)).sorted()
    }

    func configDir(forLogFile path: String) -> String? {
        LogDirs.configDir(forLogFile: path, roots: configDirs.map { (dir: $0, root: projectsDir($0)) })
    }

    func logEvents(changedPaths: [String], cursors: inout [String: FileCursor]) -> (events: [TokenEvent], more: Bool) {
        var events: [TokenEvent] = []
        var more = false
        for path in changedPaths where path.hasSuffix(".jsonl") {
            let url = URL(fileURLWithPath: path)
            guard let r = try? IncrementalReader.read(url: url, cursor: cursors[path]) else {
                cursors[path] = nil
                continue
            }
            cursors[path] = r.cursor
            more = more || !r.atEnd
            let session = url.deletingPathExtension().lastPathComponent
            // Per line: JSONSerialization's autoreleased objects of a whole 8 MB chunk would otherwise pile up.
            for line in r.lines {
                if let e = autoreleasepool(invoking: { ClaudeLog.events(from: line, sessionID: session) }) { events.append(e) }
            }
        }
        return (events, more)
    }
}
