import Foundation
import MateCore

/// Codex CLI. Sessions in `<dir>/auth.json` (a plain file: reading it never prompts), logs in
/// `<dir>/sessions/**/rollout-*.jsonl`. Usage on chatgpt.com, tokens on auth.openai.com; client id and token
/// endpoint verified against codex-cli 0.153.0-alpha.5 (see `CodexLogin`).
final class CodexProvider: Provider, @unchecked Sendable {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    /// The default config dir: `$CODEX_HOME` when Mate itself was started with it, else `~/.codex`.
    static let defaultDir: String = {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty { return home }
        return "~/.codex"
    }()
    /// Bytes read from the end of the newest rollout file for the log fallback.
    private static let tailBytes = 256 * 1024

    let id = ProviderID.codex
    private let lock = NSLock()
    private var _extraConfigDirs: [String] = []
    /// Per rollout file, the parser carrying the model and cwd of the latest `turn_context` (index queue only).
    private var parsers: [String: CodexLogParser] = [:]

    var extraConfigDirs: [String] {
        get { lock.withLock { _extraConfigDirs } }
        set { lock.withLock { _extraConfigDirs = newValue.filter { $0 != Self.defaultDir } } }
    }

    private var configDirs: [String] { [Self.defaultDir] + extraConfigDirs }

    var watchedPaths: [String] { configDirs.map { sessionsDir($0) } }
    var sessionFiles: [String] { configDirs.map { authFile($0) } }

    private func authFile(_ dir: String) -> String { (dir.expandingTilde as NSString).appendingPathComponent("auth.json") }
    private func sessionsDir(_ dir: String) -> String { (dir.expandingTilde as NSString).appendingPathComponent("sessions") }

    // MARK: Sessions

    func observeSessions() async -> SessionScan {
        var sessions: [ObservedSession] = []
        var scanned = Set<String>()
        for dir in configDirs {
            let file = authFile(dir)
            guard FileManager.default.fileExists(atPath: file) else {
                scanned.insert(dir) // definitively logged out
                continue
            }
            do {
                // A parse failure (Codex mid-write) leaves the dir out of `scanned`, so it is not taken as a logout.
                if let s = try CodexAuthFile.session(from: Data(contentsOf: URL(fileURLWithPath: file))) {
                    sessions.append(ObservedSession(provider: .codex, configDir: dir, identity: s.identity, email: s.email))
                }
                scanned.insert(dir)
            } catch {
                Log.error("codex: could not read session in \(dir): \(error)")
            }
        }
        return SessionScan(sessions: sessions, scannedDirs: scanned)
    }

    func agentCredentials(configDir: String) async throws -> Data? {
        let file = authFile(configDir)
        guard FileManager.default.fileExists(atPath: file) else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: file))
    }

    func decodeCredentials(_ data: Data) throws -> OAuthTokens { try CodexCredentials.decode(data) }

    func encodeCredentials(_ tokens: OAuthTokens, preserving original: Data?) throws -> Data {
        try CodexCredentials.encode(tokens, preserving: original)
    }

    // MARK: Network (chatgpt.com and auth.openai.com only)

    func fetchUsage(account: Account, tokens: OAuthTokens) async throws -> [LimitWindow] {
        do {
            var req = URLRequest(url: Self.usageURL)
            req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            if let acct = tokens.extra["account_id"] ?? tokens.extra["id_token"].flatMap({ CodexIdentity.from(idToken: $0)?.accountID }) {
                req.setValue(acct, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            let (data, status) = try await HTTP.json(req)
            try ProviderError.check(status: status)
            return try CodexUsage.windows(from: data, now: Date())
        } catch ProviderError.unauthorized {
            throw ProviderError.unauthorized
        } catch {
            // The logs only describe the account the agent holds in that dir.
            guard account.owner == .agent, let dir = account.agentConfigDir,
                  var windows = latestLogRateLimits(configDir: dir) else { throw error }
            Log.info("\(account.id): usage endpoint failed (\(error)); using the session log's rate limits")
            let mark = String(localized: "desde el log")
            for i in windows.indices { windows[i].detail = windows[i].detail.map { "\($0) · \(mark)" } ?? mark }
            return windows
        }
    }

    func exchangeRefreshToken(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refresh = tokens.refreshToken else { throw ProviderError.unauthorized }
        var req = URLRequest(url: CodexLogin.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try CodexLogin.refreshBody(refreshToken: refresh)
        let (data, status) = try await HTTP.json(req)
        // invalid_grant (revoked or already rotated) comes back as 400.
        if status == 400 { throw ProviderError.unauthorized }
        try ProviderError.check(status: status)
        return try CodexTokenResponse.tokens(from: data, previous: tokens)
    }

    /// The rate limits of the last `token_count` event of the newest rollout file under `configDir`.
    private func latestLogRateLimits(configDir: String) -> [LimitWindow]? {
        let files = logFiles(in: [sessionsDir(configDir)])
        let newest = files.max { modified($0) < modified($1) }
        guard let path = newest, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(Self.tailBytes) ? size - UInt64(Self.tailBytes) : 0)
        guard let tail = try? handle.readToEnd() else { return nil }
        return CodexLogTail.latestRateLimits(in: tail)
    }

    private func modified(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: Logs

    private static func isRollout(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    func logFiles(in paths: [String]) -> [String] {
        let roots = watchedPaths.flatMap { [$0, URL(fileURLWithPath: $0).resolvingSymlinksInPath().path] }
        let fm = FileManager.default
        var out: [String] = []
        for path in paths where roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if Self.isRollout(path) { out.append(path) }
                continue
            }
            guard let e = fm.enumerator(atPath: path) else { continue }
            for case let rel as String in e where Self.isRollout(rel) {
                out.append((path as NSString).appendingPathComponent(rel))
            }
        }
        return Array(Set(out)).sorted()
    }

    func configDir(forLogFile path: String) -> String? {
        LogDirs.configDir(forLogFile: path, roots: configDirs.map { (dir: $0, root: sessionsDir($0)) })
    }

    func logEvents(changedPaths: [String], cursors: inout [String: FileCursor]) -> (events: [TokenEvent], more: Bool) {
        var events: [TokenEvent] = []
        var more = false
        for path in changedPaths where Self.isRollout(path) {
            let url = URL(fileURLWithPath: path)
            let previous = cursors[path]
            guard let r = try? IncrementalReader.read(url: url, cursor: previous) else {
                cursors[path] = nil
                parsers[path] = nil
                continue
            }
            cursors[path] = r.cursor
            more = more || !r.atEnd
            guard !r.lines.isEmpty else { continue }
            // Read from the start (new, replaced or truncated file): forget the old turn context.
            let fromStart = previous.map { r.cursor.inode != $0.inode || r.cursor.offset < $0.offset } ?? true
            var parser = (fromStart ? nil : parsers[path]) ?? primedParser(url: url, before: previous?.offset ?? 0, fromStart: fromStart)
            let session = url.deletingPathExtension().lastPathComponent
            for line in r.lines {
                if let e = autoreleasepool(invoking: { parser.parse(line, sessionID: session).0 }) { events.append(e) }
            }
            parsers[path] = parser
        }
        return (events, more)
    }

    /// A parser for a file resumed mid-way after a relaunch: the latest `turn_context` before `offset` (looked for in
    /// the preceding 1 MB) sets the model and project of the events that follow.
    private func primedParser(url: URL, before offset: UInt64, fromStart: Bool) -> CodexLogParser {
        var parser = CodexLogParser()
        guard !fromStart, offset > 0, let handle = try? FileHandle(forReadingFrom: url) else { return parser }
        defer { try? handle.close() }
        let start = offset > 1_048_576 ? offset - 1_048_576 : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(offset - start)) else { return parser }
        let marker = Data(#""type":"turn_context""#.utf8)
        if let line = data.split(separator: 0x0A).last(where: { $0.range(of: marker) != nil }) {
            _ = parser.parse(Data(line), sessionID: "")
        }
        return parser
    }
}
