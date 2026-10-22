import Foundation

public enum AccountSource: Codable, Hashable, Sendable {
    case detected
    case login
    case configDir(String)
}

public enum TokenOwner: Codable, Hashable, Sendable { case agent, mate }

public enum AccountStatus: Codable, Equatable, Sendable {
    case ok, stale, expired
    case error(String)
}

public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var provider: ProviderID
    public var identity: String
    public var email: String?
    public var name: String
    public var colorIndex: Int
    public var source: AccountSource
    public var owner: TokenOwner
    /// Where the agent holds the credentials while `owner == .agent`.
    public var agentConfigDir: String?
    public var hidden: Bool
    public var status: AccountStatus

    public init(id: String, provider: ProviderID, identity: String, email: String?, name: String,
                colorIndex: Int, source: AccountSource, owner: TokenOwner,
                agentConfigDir: String?, hidden: Bool = false, status: AccountStatus = .ok) {
        self.id = id; self.provider = provider; self.identity = identity; self.email = email
        self.name = name; self.colorIndex = colorIndex; self.source = source; self.owner = owner
        self.agentConfigDir = agentConfigDir; self.hidden = hidden; self.status = status
    }
}

public struct ObservedSession: Equatable, Sendable {
    public var provider: ProviderID
    /// Canonical path, "~/.claude" for the default.
    public var configDir: String
    public var identity: String
    public var email: String?

    public init(provider: ProviderID, configDir: String, identity: String, email: String?) {
        self.provider = provider; self.configDir = configDir
        self.identity = identity; self.email = email
    }
}

public enum OwnershipAction: Equatable, Sendable {
    /// Copy the agent's current credentials into Mate's keychain.
    case storeShadow(accountID: String, configDir: String)
    case dropMateCopy(accountID: String)
}

public struct SwitchPlan: Equatable, Sendable {
    public var incoming: String
    public var outgoing: String?
    public var configDir: String

    public init(incoming: String, outgoing: String?, configDir: String) {
        self.incoming = incoming; self.outgoing = outgoing; self.configDir = configDir
    }
}

public enum RefreshDecision: Equatable, Sendable { case useAsIs, refresh, stale }

public enum UnauthorizedAction: Equatable, Sendable { case markStale, refreshAndRetry, markExpired }

public enum FetchPolicy {
    /// What a 401 from the usage endpoint means. Agent-owned tokens are never refreshed by Mate: the agent will
    /// refresh them, so the account is only stale. A Mate-owned account refreshes once; a 401 after that is a dead
    /// session.
    public static func onUnauthorized(owner: TokenOwner, alreadyRefreshed: Bool) -> UnauthorizedAction {
        switch owner {
        case .agent: .markStale
        case .mate: alreadyRefreshed ? .markExpired : .refreshAndRetry
        }
    }
}

/// Single-owner token rules. At any time exactly one party refreshes an account's
/// tokens: the agent (CLI) or Mate, never both, because refresh tokens rotate and
/// a second refresher would invalidate the first one's copy.
///
/// Mate keeps a shadow copy of the agent's credentials on every observation.
/// That shadow is what makes "the previous account keeps working" possible: Mate
/// always holds the agent's latest tokens, so when the agent stops using them
/// (the user logs in to another account) they are still current and Mate can
/// take over refreshing them.
public struct AccountRegistry: Codable, Equatable, Sendable {
    public var accounts: [Account]

    /// The id of the account of `identity` at `provider`; also the key of `SwitchHistory` and the aggregates' slices.
    /// Status of an agent-only account whose session ended (kept listed with its last data, never fetched).
    public static let noSession = "noSession"

    public static func accountID(provider: ProviderID, identity: String) -> String { "\(provider.rawValue):\(identity)" }

    public init(accounts: [Account] = []) { self.accounts = accounts }

    /// `observed` holds ALL sessions currently seen for `provider` across every
    /// watched config dir. `scannedDirs` holds the config dirs that were read
    /// successfully: callers pass only dirs whose read fully succeeded, because a
    /// failed read must not look like a logout. An agent-owned account is demoted
    /// to Mate only when its `agentConfigDir` is in `scannedDirs` and its identity
    /// was not observed there. Only that provider's accounts are touched.
    /// Emits one `storeShadow` per account, for the session in its `agentConfigDir`.
    /// `sourceDirs` are the config dirs the user added as sources: an account first observed in one of them gets
    /// `.configDir(dir)` as its source (`.detected` otherwise).
    /// `agentOnly` providers (Mate keeps no copy of their credentials) keep a demoted account listed with status
    /// `.error(noSession)`: nothing can fetch it until its identity is observed again, which revives it.
    public mutating func reconcile(provider: ProviderID, observed: [ObservedSession],
                                   scannedDirs: Set<String>, sourceDirs: Set<String> = [],
                                   agentOnly: Bool = false) -> [OwnershipAction] {
        var actions: [OwnershipAction] = []
        let sessions = observed.filter { $0.provider == provider }
        var done = Set<String>()

        for s in sessions {
            let id = Self.accountID(provider: provider, identity: s.identity)
            guard done.insert(id).inserted else { continue }
            let dirs = sessions.filter { $0.identity == s.identity }.map(\.configDir)
            let email = sessions.first { $0.identity == s.identity && $0.email != nil }?.email
            let i: Int
            if let found = accounts.firstIndex(where: { $0.id == id }) {
                i = found
                if let email { accounts[i].email = email }
                // A fresh agent login revives an account whose Mate copy had died.
                if accounts[i].owner == .mate && accounts[i].status == .expired { accounts[i].status = .ok }
                if accounts[i].status == .error(Self.noSession) { accounts[i].status = .ok }
                accounts[i].owner = .agent
                if accounts[i].agentConfigDir.map({ dirs.contains($0) }) != true {
                    accounts[i].agentConfigDir = dirs[0]
                }
            } else {
                accounts.append(Account(id: id, provider: provider, identity: s.identity, email: email,
                                        name: email ?? s.identity, colorIndex: nextColor(provider),
                                        source: sourceDirs.contains(dirs[0]) ? .configDir(dirs[0]) : .detected,
                                        owner: .agent, agentConfigDir: dirs[0]))
                i = accounts.count - 1
            }
            actions.append(.storeShadow(accountID: id, configDir: accounts[i].agentConfigDir ?? dirs[0]))
        }

        for i in accounts.indices where accounts[i].provider == provider
            && accounts[i].owner == .agent && !done.contains(accounts[i].id) {
            if let dir = accounts[i].agentConfigDir, scannedDirs.contains(dir) {
                accounts[i].owner = .mate
                accounts[i].agentConfigDir = nil
                if agentOnly { accounts[i].status = .error(Self.noSession) }
            }
        }
        return actions
    }

    private func nextColor(_ provider: ProviderID) -> Int {
        (accounts.filter { $0.provider == provider }.map(\.colorIndex).max() ?? -1) + 1
    }

    /// An account added through Mate's own login: Mate owns its tokens. A known identity is updated, not
    /// duplicated, and keeps its owner and source: when the agent owns it the caller discards the new tokens; when
    /// Mate owns it the caller replaces its copy, which revives an expired account.
    @discardableResult
    public mutating func addLogin(provider: ProviderID, identity: String, email: String?) -> Account {
        let id = Self.accountID(provider: provider, identity: identity)
        if let i = accounts.firstIndex(where: { $0.id == id }) {
            if let e = email { accounts[i].email = e }
            if accounts[i].owner == .mate { accounts[i].status = .ok }
            return accounts[i]
        }
        let a = Account(id: id, provider: provider, identity: identity, email: email,
                        name: email ?? identity, colorIndex: nextColor(provider), source: .login,
                        owner: .mate, agentConfigDir: nil)
        accounts.append(a)
        return a
    }

    /// Removes an account. Only a Mate-owned account has a Mate copy to drop.
    @discardableResult
    public mutating func remove(_ id: String) -> [OwnershipAction] {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return [] }
        let owner = accounts[i].owner
        accounts.remove(at: i)
        return owner == .mate ? [.dropMateCopy(accountID: id)] : []
    }

    public func canRefresh(_ id: String) -> Bool {
        accounts.first { $0.id == id }?.owner == .mate
    }

    public func refreshDecision(for id: String, expiresAt: Date?, now: Date) -> RefreshDecision {
        guard let account = accounts.first(where: { $0.id == id }), let expiresAt else { return .useAsIs }
        switch account.owner {
        case .agent: return expiresAt <= now ? .stale : .useAsIs
        case .mate: return expiresAt < now.addingTimeInterval(300) ? .refresh : .useAsIs
        }
    }

    /// Only a Mate-owned account can be handed to the agent. The outgoing account
    /// is the one of the same provider the agent currently holds in `configDir`.
    public func switchPlan(to id: String, configDir: String) -> SwitchPlan? {
        guard let incoming = accounts.first(where: { $0.id == id }), incoming.owner == .mate else { return nil }
        let outgoing = accounts.first {
            $0.provider == incoming.provider && $0.owner == .agent && $0.agentConfigDir == configDir
        }
        return SwitchPlan(incoming: id, outgoing: outgoing?.id, configDir: configDir)
    }

    /// Call only after the agent's credentials were written. Refuses (false, no
    /// change) if the plan is stale: incoming is no longer Mate-owned, or the
    /// agent-owned account in the dir is not the plan's outgoing one.
    @discardableResult
    public mutating func apply(_ plan: SwitchPlan) -> Bool {
        guard let n = accounts.firstIndex(where: { $0.id == plan.incoming }),
              accounts[n].owner == .mate else { return false }
        let current = accounts.firstIndex {
            $0.provider == accounts[n].provider && $0.owner == .agent && $0.agentConfigDir == plan.configDir
        }
        guard current.map({ accounts[$0].id }) == plan.outgoing else { return false }
        if let c = current {
            accounts[c].owner = .mate
            accounts[c].agentConfigDir = nil
        }
        accounts[n].owner = .agent
        accounts[n].agentConfigDir = plan.configDir
        return true
    }
}
