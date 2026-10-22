import Testing
import Foundation
@testable import MateCore

private func account(_ identity: String, owner: TokenOwner = .agent) -> Account {
    Account(id: "claude:\(identity)", provider: .claude, identity: identity, email: nil, name: identity,
            colorIndex: 0, source: .detected, owner: owner, agentConfigDir: owner == .agent ? "~/.claude" : nil)
}

@Test func blobOfTheObservedAccountIsStored() {
    let d = ShadowAttribution.decide(blobIdentity: "a", observedIdentity: "a", knownAccounts: [account("a"), account("b")])
    #expect(d == .store)
}

@Test func blobOfAnotherKnownAccountGoesToThatAccount() {
    let d = ShadowAttribution.decide(blobIdentity: "b", observedIdentity: "a",
                                     knownAccounts: [account("a"), account("b", owner: .mate)])
    #expect(d == .redirect(accountID: "claude:b"))
}

@Test func blobOfAnUnknownAccountIsSkipped() {
    let d = ShadowAttribution.decide(blobIdentity: "z", observedIdentity: "a", knownAccounts: [account("a")])
    #expect(d == .skip)
}

/// A failed profile lookup never guesses: nothing is stored this round.
@Test func unknownBlobIdentityIsSkipped() {
    let d = ShadowAttribution.decide(blobIdentity: nil, observedIdentity: "a", knownAccounts: [account("a")])
    #expect(d == .skip)
}

/// A redirected blob replaces another account's copy only when it is newer: Mate may have refreshed that copy.
@Test func redirectedBlobReplacesOnlyAnOlderCopy() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 2_000)
    #expect(ShadowAttribution.replacesCopy(copyExpiresAt: t0, blobExpiresAt: t1))
    #expect(!ShadowAttribution.replacesCopy(copyExpiresAt: t1, blobExpiresAt: t0))
    #expect(!ShadowAttribution.replacesCopy(copyExpiresAt: t1, blobExpiresAt: t1))
    #expect(ShadowAttribution.replacesCopy(copyExpiresAt: nil, blobExpiresAt: t0))
    #expect(!ShadowAttribution.replacesCopy(copyExpiresAt: t0, blobExpiresAt: nil))
}

@Test func blobKeyIsStableAndDoesNotContainTheBlob() {
    let blob = Data("secret-token".utf8)
    #expect(ShadowAttribution.blobKey(blob) == ShadowAttribution.blobKey(Data("secret-token".utf8)))
    #expect(ShadowAttribution.blobKey(blob) != ShadowAttribution.blobKey(Data("other".utf8)))
    #expect(!ShadowAttribution.blobKey(blob).contains("secret"))
}
