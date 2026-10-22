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

    /// One rename per old account whose new identity is among `newIdentities`, when the old id exists and the new
    /// one does not. The first identity seen takes an old account over; a second user of it starts fresh.
    public static func renames(newIdentities: [String], existingIDs: Set<String>) -> [Rename] {
        var out: [Rename] = []
        var taken = Set<String>()
        for identity in newIdentities {
            guard let legacy = CodexIdentity.legacyIdentity(of: identity) else { continue }
            let from = AccountRegistry.accountID(provider: .codex, identity: legacy)
            let to = AccountRegistry.accountID(provider: .codex, identity: identity)
            guard existingIDs.contains(from), !existingIDs.contains(to), taken.insert(from).inserted else { continue }
            out.append(Rename(from: from, to: to, identity: identity))
        }
        return out
    }
}
