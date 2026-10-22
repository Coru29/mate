import Foundation
import MateCore

/// Cursor. The app's session lives in `state.vscdb` (`ItemTable`: `cursorAuth/accessToken`,
/// `cursorAuth/cachedEmail`), read read-only per fetch. Usage from `aiserver.v1.DashboardService/GetCurrentPeriodUsage`
/// on api2.cursor.sh (Connect protocol, JSON, `Authorization: Bearer <access token>`), the call Cursor 3.6.21's own
/// usage panel makes. Always agent-owned: Mate never refreshes or writes Cursor's session.
/// Activity: Cursor frontmost (`UsageStore` watches `NSWorkspace`) or `cursor-agent` writing its chats.
final class CursorProvider: Provider, @unchecked Sendable {
    static let bundleID = "com.todesktop.230313mzl4w4u92"
    static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    /// Pseudo config dir naming the Cursor app's session (accounts' `agentConfigDir`).
    static let sessionDir = "~/Library/Application Support/Cursor"
    private static let tokenKey = "cursorAuth/accessToken"
    private static let emailKey = "cursorAuth/cachedEmail"

    let id = ProviderID.cursor
    var extraConfigDirs: [String] { get { [] } set {} }
    var agentOnly: Bool { true }

    private var database: URL {
        URL(fileURLWithPath: (Self.sessionDir.expandingTilde as NSString)
            .appendingPathComponent("User/globalStorage/state.vscdb"))
    }

    /// `cursor-agent` keeps each chat in `$CURSOR_CONFIG_DIR` (else `~/.cursor`)`/chats/<md5 of cwd>/<id>/store.db`.
    private var chatsDir: String {
        let env = ProcessInfo.processInfo.environment
        let base: String
        if let d = env["CURSOR_CONFIG_DIR"], !d.trimmingCharacters(in: .whitespaces).isEmpty { base = d }
        else if let x = env["XDG_CONFIG_HOME"], !x.trimmingCharacters(in: .whitespaces).isEmpty {
            base = (x as NSString).appendingPathComponent("cursor")
        } else { base = "~/.cursor".expandingTilde }
        return (base as NSString).appendingPathComponent("chats")
    }

    var watchedPaths: [String] { [chatsDir] }
    /// A login or logout reaches the main database file when Cursor checkpoints its WAL, which is also when an
    /// `immutable` read can see it.
    var sessionFiles: [String] { [database.path] }

    // MARK: Sessions

    private enum Read { case unreadable, loggedOut, session(token: String, email: String?) }

    private func readSession() -> Read {
        guard let values = Sqlite.readValues(db: database, table: "ItemTable", keys: [Self.tokenKey, Self.emailKey]) else {
            return .unreadable
        }
        guard let token = values[Self.tokenKey].map(Self.unquoted), !token.isEmpty else { return .loggedOut }
        return .session(token: token, email: values[Self.emailKey].map(Self.unquoted).flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func unquoted(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 2 && t.hasPrefix("\"") && t.hasSuffix("\"") ? String(t.dropFirst().dropLast()) : t
    }

    func observeSessions() async -> SessionScan {
        let dir = Self.sessionDir
        guard FileManager.default.fileExists(atPath: database.path) else {
            return SessionScan(sessions: [], scannedDirs: [dir])
        }
        switch readSession() {
        case .unreadable:
            return SessionScan(sessions: [], scannedDirs: []) // not a logout
        case .loggedOut:
            return SessionScan(sessions: [], scannedDirs: [dir])
        case .session(let token, let email):
            guard let identity = CursorSession.identity(accessToken: token, email: email) else {
                return SessionScan(sessions: [], scannedDirs: [dir])
            }
            return SessionScan(sessions: [ObservedSession(provider: .cursor, configDir: dir, identity: identity, email: email)],
                               scannedDirs: [dir])
        }
    }

    func agentCredentials(configDir: String) async throws -> Data? {
        guard configDir == Self.sessionDir, FileManager.default.fileExists(atPath: database.path) else { return nil }
        switch readSession() {
        case .unreadable: throw ProviderError.unavailable(String(localized: "no se pudo leer la sesión"))
        case .loggedOut: return nil
        case .session(let token, _): return Data(token.utf8)
        }
    }

    func decodeCredentials(_ data: Data) throws -> OAuthTokens {
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw ParseError.malformed("empty Cursor token")
        }
        return CursorSession.tokens(accessToken: token)
    }

    func encodeCredentials(_ tokens: OAuthTokens, preserving original: Data?) throws -> Data {
        throw ProviderError.refreshNotAllowed
    }

    // MARK: Network (api2.cursor.sh only)

    func fetchUsage(account: Account, tokens: OAuthTokens) async throws -> [LimitWindow] {
        var req = URLRequest(url: Self.usageURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.httpBody = Data("{}".utf8)
        let (data, status) = try await HTTP.json(req)
        try ProviderError.check(status: status)
        return try CursorUsage.windows(from: data, now: Date())
    }

    func exchangeRefreshToken(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        throw ProviderError.refreshNotAllowed
    }

    // MARK: Logs (activity only: the chat stores hold no token counts Mate reads)

    func logFiles(in paths: [String]) -> [String] {
        let roots = [chatsDir, URL(fileURLWithPath: chatsDir).resolvingSymlinksInPath().path]
        // Only paths FSEvents reported: a full scan of the chats tree would find nothing to read anyway.
        return paths.filter { p in
            let name = (p as NSString).lastPathComponent
            return roots.contains { p.hasPrefix($0 + "/") } && name.hasPrefix("store.db")
        }
    }

    func logEvents(changedPaths: [String], cursors: inout [String: FileCursor]) -> (events: [TokenEvent], more: Bool) {
        ([], false)
    }
}
