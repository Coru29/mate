import Foundation
import MateCore

/// Grok (xAI API). No local session: the user gives Mate a management key and team id (Settings; until then
/// `Mate --set-grok <teamId>`), stored as Mate's own keychain item (service `io.github.coru29.Mate.grok`, account
/// `grok:<teamId>`, data = the key), plus a monthly budget in USD (`grokMonthlyBudget`). Shown only when both are
/// set. Spend from `GET management-api.x.ai/v1/billing/teams/{team}/postpaid/invoice/preview` (xAI docs). Agent-owned
/// in the registry's sense: nothing to refresh, and Mate never rewrites the key on its own.
final class GrokProvider: Provider, @unchecked Sendable {
    static let baseURL = "https://management-api.x.ai/v1/billing/teams/"
    static let service = KeychainVault.service(.grok)
    /// The accounts' `agentConfigDir`.
    static let sessionDir = "mate-keychain"

    let id = ProviderID.grok
    var extraConfigDirs: [String] { get { [] } set {} }
    var agentOnly: Bool { true }
    var watchedPaths: [String] { [] }
    var sessionFiles: [String] { [] }

    static var budget: Double {
        let v = UserDefaults.mate.object(forKey: PrefKey.grokMonthlyBudget.rawValue) as? NSNumber
        return v?.doubleValue ?? (Preferences.defaults[PrefKey.grokMonthlyBudget.rawValue] as? Double ?? 0)
    }

    static func accountID(teamID: String) -> String { AccountRegistry.accountID(provider: .grok, identity: teamID) }

    /// The stored keys' account names (attributes only), without the chunk items of a long value.
    private static var keyNames: [String] { Keychain.accountNames(service: service).filter { !$0.contains("#") } }

    /// Mate's own items, through the shared cached vault.
    private static var vault: KeychainVault { .shared }

    /// Stores the key for `teamID`, replacing any other team's (one Grok team at a time).
    static func setKey(_ key: String, teamID: String) throws {
        let account = accountID(teamID: teamID)
        for other in keyNames where other != account { try vault.delete(.grok, accountID: other) }
        try vault.write(.grok, accountID: account, data: Data(key.utf8))
    }

    /// The team whose key is stored, from the item's attributes (the key itself is not read).
    static var storedTeamID: String? {
        let prefix = ProviderID.grok.rawValue + ":"
        return keyNames.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// Deletes every stored Grok key (Mate's own items).
    static func deleteKeys() throws {
        for name in keyNames { try vault.delete(.grok, accountID: name) }
    }

    func accountRemoved(_ account: Account) throws {
        try Self.vault.delete(.grok, accountID: account.id)
    }

    func observeSessions() async -> SessionScan {
        let dir = Self.sessionDir
        guard Self.budget > 0 else { return SessionScan(sessions: [], scannedDirs: [dir]) }
        let prefix = ProviderID.grok.rawValue + ":"
        let sessions = Self.keyNames.compactMap { name -> ObservedSession? in
            guard name.hasPrefix(prefix), name.count > prefix.count else { return nil }
            return ObservedSession(provider: .grok, configDir: dir, identity: String(name.dropFirst(prefix.count)), email: nil)
        }
        return SessionScan(sessions: Array(sessions.prefix(1)), scannedDirs: [dir])
    }

    /// The key of the configured team (Mate's own item: no access prompt).
    func agentCredentials(configDir: String) async throws -> Data? {
        guard configDir == Self.sessionDir else { return nil }
        let prefix = ProviderID.grok.rawValue + ":"
        guard let name = Self.keyNames.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        guard let key = try Self.vault.read(.grok, accountID: name) else { return nil }
        // Carry the team id with the key so a fetch never pairs one team's key with another team's id.
        return try JSONSerialization.data(withJSONObject: ["key": String(decoding: key, as: UTF8.self),
                                                           "team": String(name.dropFirst(prefix.count))])
    }

    func decodeCredentials(_ data: Data) throws -> OAuthTokens {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let key = o["key"], !key.isEmpty, let team = o["team"], !team.isEmpty else {
            throw ParseError.malformed("Grok key missing")
        }
        return OAuthTokens(accessToken: key, extra: ["team": team])
    }

    func encodeCredentials(_ tokens: OAuthTokens, preserving original: Data?) throws -> Data {
        throw ProviderError.refreshNotAllowed
    }

    // MARK: Network (management-api.x.ai only)

    func fetchUsage(account: Account, tokens: OAuthTokens) async throws -> [LimitWindow] {
        guard let team = tokens.extra["team"], team == account.identity,
              let encoded = team.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])),
              let url = URL(string: Self.baseURL + encoded + "/postpaid/invoice/preview") else {
            throw ProviderError.unauthorized
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await HTTP.json(req)
        try ProviderError.check(status: status)
        let budget = Self.budget
        guard budget > 0 else { throw ProviderError.unavailable(String(localized: "sin presupuesto")) }
        return try GrokSpend.windows(from: data, budget: budget, now: Date())
    }

    func exchangeRefreshToken(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        throw ProviderError.refreshNotAllowed
    }

    func logFiles(in paths: [String]) -> [String] { [] }

    func logEvents(changedPaths: [String], cursors: inout [String: FileCursor]) -> (events: [TokenEvent], more: Bool) {
        ([], false)
    }
}
