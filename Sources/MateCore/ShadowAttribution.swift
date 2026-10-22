import CryptoKit
import Foundation

/// Whose tokens an agent's credential blob holds, before Mate copies it as an account's shadow or fetches with it.
/// During a `/login` the identity file can change before the credential store, so the blob read for the observed
/// account may still be another account's.
public enum ShadowAttribution: Equatable, Sendable {
    /// The blob is the observed account's: copy it and fetch with it.
    case store
    /// The blob is another known account's: it may update that account's copy, never the observed one's.
    case redirect(accountID: String)
    /// Unknown owner, or the lookup failed: nothing is stored or fetched with it this round.
    case skip

    /// `blobIdentity` is the identity the provider reports for the blob's token (nil when the lookup failed);
    /// `knownAccounts` are the provider's accounts.
    public static func decide(blobIdentity: String?, observedIdentity: String, knownAccounts: [Account]) -> Self {
        guard let blobIdentity else { return .skip }
        if blobIdentity == observedIdentity { return .store }
        if let other = knownAccounts.first(where: { $0.identity == blobIdentity }) { return .redirect(accountID: other.id) }
        return .skip
    }

    /// Whether a redirected blob replaces the other account's copy: only a newer token does (Mate may have
    /// refreshed that copy after the agent let it go). `copyExpiresAt` nil means there is no usable copy.
    public static func replacesCopy(copyExpiresAt: Date?, blobExpiresAt: Date?) -> Bool {
        guard let copyExpiresAt else { return true }
        guard let blobExpiresAt else { return false }
        return blobExpiresAt > copyExpiresAt
    }

    /// Cache key of a blob's identity lookup (SHA-256 hex): one lookup per token change, no secret kept in memory.
    public static func blobKey(_ blob: Data) -> String {
        SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
    }
}
