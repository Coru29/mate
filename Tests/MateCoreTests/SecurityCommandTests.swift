import Testing
import Foundation
@testable import MateCore

@Test func securityQuotingEscapesQuotesAndBackslashes() {
    #expect(SecurityCommand.quoted("plain") == "\"plain\"")
    #expect(SecurityCommand.quoted("we ird\"acct\\x") == "\"we ird\\\"acct\\\\x\"")
    // A line break would end the `security -i` command early.
    #expect(SecurityCommand.quoted("a\nb") == nil)
    #expect(SecurityCommand.quoted("a\rb") == nil)
}

@Test func securityAddLineCarriesTheSecretOnlyAsBase64InTheStdinLine() throws {
    let data = Data("{\"k\":\"secret\"}".utf8)
    let line = try #require(SecurityCommand.addLine(service: "io.github.coru29.Mate.claude", account: "claude:abc", data: data))
    #expect(line == "add-generic-password -U -s \"io.github.coru29.Mate.claude\" -a \"claude:abc\" -j \"\(SecurityCommand.marker)\" -w \"\(data.base64EncodedString())\"\n")
    #expect(!line.contains("secret"))
}

@Test func securityAddLineRefusesWhatSecurityWouldTruncate() {
    // `security -i` splits lines over 4096 characters (measured): a split would store a truncated secret.
    let big = Data(repeating: 0x41, count: 3_000)
    #expect(SecurityCommand.addLine(service: "s", account: "a", data: big) == nil)
    let fits = Data(repeating: 0x41, count: 2_800)
    let line = SecurityCommand.addLine(service: "s", account: "a", data: fits)
    #expect(line != nil)
    #expect((line?.count ?? .max) <= SecurityCommand.maxLineLength + 1)
    #expect(SecurityCommand.addLine(service: "s", account: "a\nb", data: Data("x".utf8)) == nil)
}

@Test func securityArgumentsNeverCarryData() {
    #expect(SecurityCommand.findArguments(service: "Claude Code-credentials", account: nil)
        == ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    #expect(SecurityCommand.findArguments(service: "s", account: "a") == ["find-generic-password", "-s", "s", "-a", "a", "-w"])
    #expect(SecurityCommand.deleteArguments(service: "s", account: "a") == ["delete-generic-password", "-s", "s", "-a", "a"])
}

@Test func securityExitStatusMapping() {
    #expect(SecurityCommand.exit(0) == .ok)
    #expect(SecurityCommand.exit(44) == .notFound)      // errSecItemNotFound (-25300) & 0xff
    #expect(SecurityCommand.exit(128) == .denied)       // errSecUserCanceled (-128): "Denegar" (observed)
    #expect(SecurityCommand.exit(51) == .denied)        // errSecAuthFailed (-25293) & 0xff
    #expect(SecurityCommand.exit(36) == .denied)        // errSecInteractionNotAllowed (-25308) & 0xff
    #expect(SecurityCommand.exit(1) == .failed(1))
}

@Test func securityOwnOutputDecodesBase64() {
    let data = Data([0, 1, 2, 0xff])
    #expect(SecurityCommand.decodeOwn(Data((data.base64EncodedString() + "\n").utf8)) == data)
    #expect(SecurityCommand.decodeOwn(Data("not base64!\n".utf8)) == nil)
}

@Test func securityForeignOutputStripsTheNewlineAndUndoesHex() {
    #expect(SecurityCommand.decodeForeign(Data("{\"a\":1}\n".utf8)) == Data("{\"a\":1}".utf8))
    // `security -w` prints data it cannot show as text in hex.
    #expect(SecurityCommand.decodeForeign(Data("7b7d\n".utf8)) == Data("{}".utf8))
    #expect(SecurityCommand.decodeForeign(Data("abc\n".utf8)) == Data("abc".utf8))
}

@Test func ownItemPlan() {
    #expect(OwnKeychainItem.plan(comment: nil, exists: false) == .missing)
    #expect(OwnKeychainItem.plan(comment: SecurityCommand.marker, exists: true) == .tool)
    // Written by an earlier Mate through the Security framework: readable only in process, then migrated.
    #expect(OwnKeychainItem.plan(comment: nil, exists: true) == .legacy)
    #expect(OwnKeychainItem.plan(comment: "something else", exists: true) == .legacy)
}
