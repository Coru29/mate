import Foundation
import MateCore

/// `--fake`: two scripted Claude-shaped accounts whose usage rises 1 %/min from launch. No network, no keychain,
/// no real files. Used for UI checks.
final class FakeProvider: Provider, @unchecked Sendable {
    private struct Script {
        var dir: String
        var identity: String
        var email: String
        /// Session percent at launch.
        var sessionStart: Double
        var weeklyStart: Double
        var opus: Bool
    }

    private static let scripts = [
        Script(dir: "fake:personal", identity: "fake-personal", email: "personal@example.com",
               sessionStart: 70, weeklyStart: 30, opus: false),
        Script(dir: "fake:work", identity: "fake-work", email: "work@example.com",
               sessionStart: 20, weeklyStart: 55, opus: true),
    ]

    let id = ProviderID.claude
    let launch = Date()
    var watchedPaths: [String] { [] }
    var sessionFiles: [String] { [] }
    var extraConfigDirs: [String] = []
    var alwaysActive: Bool { true }

    func observeSessions() async -> SessionScan {
        SessionScan(sessions: Self.scripts.map {
            ObservedSession(provider: .claude, configDir: $0.dir, identity: $0.identity, email: $0.email)
        }, scannedDirs: Set(Self.scripts.map(\.dir)))
    }

    func agentCredentials(configDir: String) async throws -> Data? {
        let t = OAuthTokens(accessToken: "fake-\(configDir)", refreshToken: "fake-refresh",
                            expiresAt: Date().addingTimeInterval(86_400))
        return try ClaudeCredentials.encode(t, preserving: nil)
    }

    func decodeCredentials(_ data: Data) throws -> OAuthTokens { try ClaudeCredentials.decode(data) }

    func encodeCredentials(_ tokens: OAuthTokens, preserving original: Data?) throws -> Data {
        try ClaudeCredentials.encode(tokens, preserving: original)
    }

    func fetchUsage(account: Account, tokens: OAuthTokens) async throws -> [LimitWindow] {
        guard let s = Self.scripts.first(where: { $0.identity == account.identity }) else {
            throw ProviderError.unauthorized
        }
        let now = Date()
        let minutes = now.timeIntervalSince(launch) / 60
        // The session window lasts 101 fake minutes, so it climbs 0 → 100 and then resets.
        let period = 101.0
        let position = (s.sessionStart + minutes).truncatingRemainder(dividingBy: period)
        var windows = [
            LimitWindow(kind: .session, usedPercent: position.rounded(.down),
                        resetsAt: now.addingTimeInterval((period - position) * 60), duration: period * 60),
            LimitWindow(kind: .weekly, usedPercent: min(100, (s.weeklyStart + minutes / 10).rounded(.down)),
                        resetsAt: launch.addingTimeInterval(3 * 86_400), duration: 604_800),
        ]
        if s.opus {
            windows.append(LimitWindow(kind: .weeklyModel("Opus"), usedPercent: min(100, (40 + minutes / 5).rounded(.down)),
                                       resetsAt: launch.addingTimeInterval(3 * 86_400), duration: 604_800))
        }
        return windows
    }

    func exchangeRefreshToken(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        var t = tokens
        t.expiresAt = Date().addingTimeInterval(86_400)
        return t
    }

    func logFiles(in paths: [String]) -> [String] { ["fake:log"] }

    /// A week of scripted history, once.
    func logEvents(changedPaths: [String], cursors: inout [String: FileCursor]) -> [TokenEvent] {
        guard changedPaths.contains("fake:log"), cursors["fake:log"] == nil else { return [] }
        cursors["fake:log"] = FileCursor(inode: 0, offset: 1, pending: Data())
        var events: [TokenEvent] = []
        let models = ["claude-opus-4-5", "claude-sonnet-4-5"]
        for day in 0..<7 {
            for i in 0..<(3 + day % 3) {
                let at = launch.addingTimeInterval(-Double(day) * 86_400 - Double(i) * 1800 - 60)
                events.append(TokenEvent(provider: .claude, at: at, model: models[i % 2], input: 1200 * (i + 1),
                                         output: 800 + 150 * day, cacheRead: 40_000, cacheWrite: 3000,
                                         project: "mate", sessionID: "fake-\(day)",
                                         dedupeKey: "fake-\(day)-\(i)"))
            }
        }
        return events
    }
}
