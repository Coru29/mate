import Foundation
import MateCore

/// Gemini CLI. Session in `~/.gemini/oauth_creds.json` (a plain file), identity from its `id_token`. Daily quota per
/// model from Code Assist (`cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` for the project, then
/// `:retrieveUserQuota`). UNVERIFIED: Gemini CLI was not installed on the build Mac, so file, endpoints and shapes
/// follow its public source. Always agent-owned: Mate never refreshes or writes the CLI's tokens.
final class GeminiProvider: Provider, @unchecked Sendable {
    static let baseURL = "https://cloudcode-pa.googleapis.com/v1internal"
    static let defaultDir = "~/.gemini"

    let id = ProviderID.gemini
    var extraConfigDirs: [String] { get { [] } set {} }
    var agentOnly: Bool { true }

    private var credsFile: String { (Self.defaultDir.expandingTilde as NSString).appendingPathComponent("oauth_creds.json") }
    /// Chat and log files of each project live under `tmp/` (they hold no token counts, see `GeminiLog`).
    var watchedPaths: [String] { [(Self.defaultDir.expandingTilde as NSString).appendingPathComponent("tmp")] }
    var sessionFiles: [String] { [credsFile] }

    func observeSessions() async -> SessionScan {
        let dir = Self.defaultDir
        guard FileManager.default.fileExists(atPath: credsFile) else { return SessionScan(sessions: [], scannedDirs: [dir]) }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: credsFile))
            guard let id = try GeminiCredentials.identity(from: data) else { return SessionScan(sessions: [], scannedDirs: [dir]) }
            return SessionScan(sessions: [ObservedSession(provider: .gemini, configDir: dir, identity: id.identity, email: id.email)],
                               scannedDirs: [dir])
        } catch {
            // Half-written file: not a logout.
            Log.error("gemini: could not read the session: \(error)")
            return SessionScan(sessions: [], scannedDirs: [])
        }
    }

    func agentCredentials(configDir: String) async throws -> Data? {
        guard configDir == Self.defaultDir, FileManager.default.fileExists(atPath: credsFile) else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: credsFile))
    }

    func decodeCredentials(_ data: Data) throws -> OAuthTokens { try GeminiCredentials.decode(data) }

    func encodeCredentials(_ tokens: OAuthTokens, preserving original: Data?) throws -> Data {
        throw ProviderError.refreshNotAllowed
    }

    // MARK: Network (cloudcode-pa.googleapis.com only)

    func fetchUsage(account: Account, tokens: OAuthTokens) async throws -> [LimitWindow] {
        let env = ProcessInfo.processInfo.environment
        var project = env["GOOGLE_CLOUD_PROJECT"].flatMap { $0.isEmpty ? nil : $0 }
        if project == nil {
            let load = try await post("loadCodeAssist", tokens: tokens, body: [
                "metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"],
            ])
            project = try GeminiQuota.project(fromLoadCodeAssist: load)
        }
        guard let project else { throw ProviderError.unavailable(String(localized: "sin proyecto de Code Assist")) }
        let quota = try await post("retrieveUserQuota", tokens: tokens, body: ["project": project])
        return try GeminiQuota.windows(from: quota, now: Date())
    }

    private func post(_ method: String, tokens: OAuthTokens, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: URL(string: "\(Self.baseURL):\(method)")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await HTTP.json(req)
        try ProviderError.check(status: status)
        return data
    }

    func exchangeRefreshToken(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        throw ProviderError.refreshNotAllowed
    }

    // MARK: Logs (activity only)

    func logFiles(in paths: [String]) -> [String] {
        let roots = watchedPaths.flatMap { [$0, URL(fileURLWithPath: $0).resolvingSymlinksInPath().path] }
        return paths.filter { p in roots.contains { p.hasPrefix($0 + "/") } && p.hasSuffix(".json") }
    }

    func logEvents(changedPaths: [String], cursors: inout [String: FileCursor]) -> (events: [TokenEvent], more: Bool) {
        ([], false)
    }
}
