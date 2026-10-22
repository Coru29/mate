import Foundation

/// Codex accounts used to be keyed by the ChatGPT workspace id alone (`codex:<accountId>`), which merged two users
/// of one Team workspace. Now the identity also names the user (`codex:<accountId>:<userId>`); an old account is
/// renamed in place the first time its user's new identity is seen, so its name, color, copy and history stay.
public enum CodexAccountMigration {
    public struct Rename: Equatable, Sendable {
        public var from: String
        public var to: String
        /// The new identity (the part of `to` after "codex:").
        public var identity: String

        public init(from: String, to: String, identity: String) {
            self.from = from; self.to = to; self.identity = identity
        }
    }

    /// One rename per old account, when the old id exists and the new one does not. An old account with a copy of
    /// its own (`accountsWithCopy`, including copies that could not be read) follows only that copy's identity
    /// (`copyIdentities`, old id → identity); one without a copy is taken over by the first session identity of
    /// its workspace. A second user of it starts fresh.
    public static func renames(existingIDs: Set<String>, copyIdentities: [String: String] = [:],
                               accountsWithCopy: Set<String> = [], sessionIdentities: [String]) -> [Rename] {
        var out: [Rename] = []
        var taken = Set<String>()
        func consider(_ identity: String, from required: String?) {
            guard let legacy = CodexIdentity.legacyIdentity(of: identity) else { return }
            let from = AccountRegistry.accountID(provider: .codex, identity: legacy)
            let to = AccountRegistry.accountID(provider: .codex, identity: identity)
            guard required.map({ $0 == from }) ?? !accountsWithCopy.contains(from),
                  existingIDs.contains(from), !existingIDs.contains(to), !out.contains(where: { $0.to == to }),
                  taken.insert(from).inserted else { return }
            out.append(Rename(from: from, to: to, identity: identity))
        }
        for (id, identity) in copyIdentities.sorted(by: { $0.key < $1.key }) { consider(identity, from: id) }
        for identity in sessionIdentities { consider(identity, from: nil) }
        return out
    }
}
