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

    public init(accounts: [Account] = []) { self.accounts = accounts }

    /// `observed` holds ALL sessions currently seen for `provider` across every
    /// watched config dir. Only that provider's accounts are touched.
    public mutating func reconcile(provider: ProviderID, observed: [ObservedSession]) -> [OwnershipAction] {
        var actions: [OwnershipAction] = []
        let sessions = observed.filter { $0.provider == provider }
        var seen = Set<String>()

        for s in sessions {
            let id = "\(provider.rawValue):\(s.identity)"
            seen.insert(id)
            let dirs = sessions.filter { $0.identity == s.identity }.map(\.configDir)
            if let i = accounts.firstIndex(where: { $0.id == id }) {
                if let e = s.email { accounts[i].email = e; accounts[i].name = e }
                accounts[i].owner = .agent
                if accounts[i].agentConfigDir.map({ dirs.contains($0) }) != true {
                    accounts[i].agentConfigDir = dirs[0]
                }
            } else {
                let color = accounts.filter { $0.provider == provider }.count
                accounts.append(Account(id: id, provider: provider, identity: s.identity, email: s.email,
                                        name: s.email ?? s.identity, colorIndex: color,
                                        source: .detected, owner: .agent, agentConfigDir: dirs[0]))
            }
            actions.append(.storeShadow(accountID: id, configDir: s.configDir))
        }

        for i in accounts.indices where accounts[i].provider == provider
            && accounts[i].owner == .agent && !seen.contains(accounts[i].id) {
            accounts[i].owner = .mate
            accounts[i].agentConfigDir = nil
        }
        return actions
    }

    /// An account added through Mate's own login: Mate owns its tokens.
    @discardableResult
    public mutating func addLogin(provider: ProviderID, identity: String, email: String?) -> Account {
        let id = "\(provider.rawValue):\(identity)"
        if let i = accounts.firstIndex(where: { $0.id == id }) {
            if let e = email { accounts[i].email = e; accounts[i].name = e }
            return accounts[i]
        }
        let color = accounts.filter { $0.provider == provider }.count
        let a = Account(id: id, provider: provider, identity: identity, email: email,
                        name: email ?? identity, colorIndex: color, source: .login,
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

    public mutating func apply(_ plan: SwitchPlan) {
        if let o = plan.outgoing, let i = accounts.firstIndex(where: { $0.id == o }) {
            accounts[i].owner = .mate
            accounts[i].agentConfigDir = nil
        }
        if let i = accounts.firstIndex(where: { $0.id == plan.incoming }) {
            accounts[i].owner = .agent
            accounts[i].agentConfigDir = plan.configDir
        }
    }
}
