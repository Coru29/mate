import Foundation
import MateCore

/// GitHub Copilot. Token from the Copilot apps' `apps.json` (or legacy `hosts.json`) in
/// `$XDG_CONFIG_HOME/github-copilot` (else `~/.config/github-copilot`), falling back to the `gh` CLI (`gh auth token`,
/// run only when `gh` is installed, at most once per fetch, 5 s timeout, output never logged). Quota from
/// `GET api.github.com/copilot_internal/user` with `Authorization: token …` and `X-GitHub-Api-Version: 2025-04-01`,
/// as VS Code's Copilot Chat 0.65.0 calls it. Only github.com tokens are used. Always agent-owned.
final class CopilotProvider: Provider, @unchecked Sendable {
    static let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!
    static let apiVersion = "2025-04-01"
    private static let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    private static let ghTimeout: TimeInterval = 5

    let id = ProviderID.copilot
    var extraConfigDirs: [String] { get { [] } set {} }
    var agentOnly: Bool { true }

    private static func xdg(_ sub: String, default def: String) -> String {
        if let x = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], x.hasPrefix("/") {
            return (x as NSString).appendingPathComponent(sub)
        }
        return def.expandingTilde
    }

    /// The account's `agentConfigDir`.
    static let sessionDir = "~/.config/github-copilot"
    private var copilotDir: String { Self.xdg("github-copilot", default: Self.sessionDir) }
    private var tokenFiles: [String] {
        ["apps.json", "hosts.json"].map { (copilotDir as NSString).appendingPathComponent($0) }
    }

    private var ghHostsFile: String {
        if let d = ProcessInfo.processInfo.environment["GH_CONFIG_DIR"], !d.isEmpty {
            return (d as NSString).appendingPathComponent("hosts.yml")
        }
        return (Self.xdg("gh", default: "~/.config/gh") as NSString).appendingPathComponent("hosts.yml")
    }

    private var ghPath: String? { Self.ghCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    var watchedPaths: [String] { [] }
    var sessionFiles: [String] { tokenFiles + [ghHostsFile] }

    // MARK: Sessions

    /// The first token file holding a github.com token, decoded (nil when there is none).
    private func appsSession() -> (data: Data, tokens: OAuthTokens)? {
        for file in tokenFiles where FileManager.default.fileExists(atPath: file) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
                  let tokens = try? CopilotCredentials.decode(data) else { continue }
            return (data, tokens)
        }
        return nil
    }

    /// The github.com user `gh` is logged in as (from `hosts.yml`, user field only), when `gh` is installed.
    private func ghUser() -> String? {
        guard ghPath != nil, let data = FileManager.default.contents(atPath: ghHostsFile),
              let yaml = String(data: data, encoding: .utf8) else { return nil }
        return GhHosts.user(fromYAML: yaml)
    }

    func observeSessions() async -> SessionScan {
        let dir = Self.sessionDir
        let user = appsSession()?.tokens.extra["user"] ?? ghUser()
        guard let user, !user.isEmpty else { return SessionScan(sessions: [], scannedDirs: [dir]) }
        return SessionScan(sessions: [ObservedSession(provider: .copilot, configDir: dir, identity: user, email: nil)],
                           scannedDirs: [dir])
    }

    func agentCredentials(configDir: String) async throws -> Data? {
        guard configDir == Self.sessionDir else { return nil }
        if let s = appsSession() { return s.data }
        guard let gh = ghPath, let token = await Self.ghToken(gh) else { return nil }
        var entry: [String: String] = ["oauth_token": token]
        if let u = ghUser() { entry["user"] = u }
        return try JSONSerialization.data(withJSONObject: ["github.com": entry])
    }

    /// `gh auth token --hostname github.com`; nil on failure or after the timeout. The output is never logged.
    private static func ghToken(_ gh: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gh)
            p.arguments = ["auth", "token", "--hostname", "github.com"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            let lock = NSLock()
            var resumed = false
            func finish(_ value: String?) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: value)
            }
            do { try p.run() } catch { finish(nil); return }
            DispatchQueue.global(qos: .utility).async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                finish(p.terminationStatus == 0 && token?.isEmpty == false ? token : nil)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ghTimeout) {
                if p.isRunning {
                    Log.error("copilot: gh auth token timed out")
                    p.terminate()
                }
                finish(nil)
            }
        }
    }

    func decodeCredentials(_ data: Data) throws -> OAuthTokens { try CopilotCredentials.decode(data) }

    func encodeCredentials(_ tokens: OAuthTokens, preserving original: Data?) throws -> Data {
        throw ProviderError.refreshNotAllowed
    }

    // MARK: Network (api.github.com only)

    func fetchUsage(account: Account, tokens: OAuthTokens) async throws -> [LimitWindow] {
        var req = URLRequest(url: Self.usageURL)
        req.setValue("token \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, status) = try await HTTP.json(req)
        try ProviderError.check(status: status)
        return try CopilotUsage.windows(from: data, now: Date())
    }

    func exchangeRefreshToken(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        throw ProviderError.refreshNotAllowed
    }

    // MARK: Logs (none)

    func logFiles(in paths: [String]) -> [String] { [] }

    func logEvents(changedPaths: [String], cursors: inout [String: FileCursor]) -> (events: [TokenEvent], more: Bool) {
        ([], false)
    }
}
