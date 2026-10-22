import Foundation
import MateCore

enum ProviderError: Error, Equatable, CustomStringConvertible {
    case unauthorized
    case rateLimited
    case unavailable(String)
    case refreshNotAllowed
    /// The user denied macOS's keychain prompt for the agent's credentials.
    case credentialsDenied

    var description: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .rateLimited: "rate limited"
        case .unavailable(let why): why
        case .refreshNotAllowed: "refresh not allowed (agent-owned account)"
        case .credentialsDenied: "keychain access denied"
        }
    }

    /// 401/403 → unauthorized, 429 → rateLimited, anything else non-2xx → unavailable.
    static func check(status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw ProviderError.unauthorized
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.unavailable("HTTP \(status)")
        }
    }
}

/// Result of looking at every config dir of a provider. `scannedDirs` lists only the dirs whose read fully
/// succeeded (credentials store answered, definitively or with an item, and the identity file parsed); a dir whose
/// read failed is left out so `AccountRegistry.reconcile` does not mistake it for a logout.
struct SessionScan: Sendable {
    var sessions: [ObservedSession]
    var scannedDirs: Set<String>
}

/// One AI agent. Methods that touch the disk, the keychain or the network are async and run off the main actor.
/// `logEvents` and `logFiles` are called only from `LogIndexer`'s queue.
protocol Provider: AnyObject, Sendable {
    var id: ProviderID { get }
    /// Session-log directories: their writes mean "active" and feed the log indexer.
    var watchedPaths: [String] { get }
    /// Files whose change can mean a login or logout (Claude's `.claude.json`): they trigger a reconcile.
    var sessionFiles: [String] { get }
    /// Extra config dirs (`CLAUDE_CONFIG_DIR` / `CODEX_HOME` sources) besides the default one.
    var extraConfigDirs: [String] { get set }
    /// Scripted providers (`--fake`) count as always active.
    var alwaysActive: Bool { get }

    func observeSessions() async -> SessionScan
    /// The agent's current credential blob for `configDir`, read fresh (nil when there is none).
    func agentCredentials(configDir: String) async throws -> Data?
    func decodeCredentials(_ data: Data) throws -> OAuthTokens
    /// Writes `tokens` into the provider's native blob, keeping every other key of `original`.
    func encodeCredentials(_ tokens: OAuthTokens, preserving original: Data?) throws -> Data
    func fetchUsage(account: Account, tokens: OAuthTokens) async throws -> [LimitWindow]
    /// The raw token exchange. Never call it directly: use `refresh(_:accountID:registry:)`, which enforces the
    /// single-owner rule.
    func exchangeRefreshToken(_ tokens: OAuthTokens) async throws -> OAuthTokens
    /// The provider's log files among (or, for directories, under) `paths`.
    func logFiles(in paths: [String]) -> [String]
    /// The config dir the log file belongs to (account attribution); nil when the provider has no per-dir logs.
    func configDir(forLogFile path: String) -> String?
    /// Reads at most one bounded chunk per file; `more` is true while some file has unread bytes left.
    func logEvents(changedPaths: [String], cursors: inout [String: FileCursor]) -> (events: [TokenEvent], more: Bool)
}

extension Provider {
    func configDir(forLogFile path: String) -> String? { nil }
    var alwaysActive: Bool { false }

    /// Refreshes only an account Mate owns; an agent-owned account throws `.refreshNotAllowed` before any request.
    func refresh(_ tokens: OAuthTokens, accountID: String, registry: AccountRegistry) async throws -> OAuthTokens {
        guard registry.canRefresh(accountID) else { throw ProviderError.refreshNotAllowed }
        return try await exchangeRefreshToken(tokens)
    }
}

extension String {
    /// `~` expanded.
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
