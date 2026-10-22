import Testing
import Foundation
@testable import MateCore

@Test func securityQuotingRefusesWhatItCannotPassVerbatim() {
    #expect(SecurityCommand.quoted("io.github.coru29.Mate.claude") == "\"io.github.coru29.Mate.claude\"")
    #expect(SecurityCommand.quoted("claude:a b") == "\"claude:a b\"")
    // Escapes inside `security -i` words are not relied on; a line break would end the command early.
    for bad in ["a\"b", "a\\b", "a\nb", "a\rb", "a\u{0}b"] { #expect(SecurityCommand.quoted(bad) == nil) }
}

@Test func securityAddLineCarriesTheSecretOnlyAsBase64InTheStdinLine() throws {
    let data = Data("{\"k\":\"secret\"}".utf8)
    let line = try #require(SecurityCommand.addLine(service: "io.github.coru29.Mate.claude", account: "claude:abc",
                                                    comment: SecurityCommand.marker, data: data))
    #expect(line == "add-generic-password -U -s \"io.github.coru29.Mate.claude\" -a \"claude:abc\" -j \"\(SecurityCommand.marker)\" -w \"\(data.base64EncodedString())\"\n")
    #expect(!line.contains("secret"))
}

@Test func securityAddLineRefusesWhatSecurityWouldSplit() {
    // `security -i` splits lines over 4096 bytes (measured): a split would store a truncated secret.
    #expect(SecurityCommand.addLine(service: "s", account: "a", comment: "c", data: Data(repeating: 0x41, count: 3_000)) == nil)
    let line = SecurityCommand.addLine(service: "s", account: "a", comment: "c", data: Data(repeating: 0x41, count: 2_800))
    #expect((line?.utf8.count ?? .max) <= SecurityCommand.maxLineLength + 1)
    // Measured in bytes, not characters.
    let wide = String(repeating: "é", count: 1_000)
    #expect(SecurityCommand.addLine(service: wide, account: wide, comment: "c", data: Data(repeating: 0x41, count: 1_400)) == nil)
    #expect(SecurityCommand.addLine(service: "s", account: "a\nb", comment: "c", data: Data("x".utf8)) == nil)
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

@Test func ownItemSmallValueIsOneItem() throws {
    let data = Data("{\"a\":1}".utf8)
    let parts = try #require(OwnItemLayout.parts(service: "io.github.coru29.Mate.claude", account: "claude:x", data: data, generation: "g1"))
    #expect(parts == [OwnItemPart(account: "claude:x", comment: SecurityCommand.marker, data: data)])
    #expect(OwnItemLayout.head(comment: SecurityCommand.marker) == .single)
}

@Test func ownItemLargeValueIsChunkedWithTheHeadLast() throws {
    let data = Data((0..<10_000).map { UInt8($0 % 251) })
    let svc = "io.github.coru29.Mate.codex"
    let parts = try #require(OwnItemLayout.parts(service: svc, account: "codex:x", data: data, generation: "g1"))
    #expect(parts.count > 3)
    let head = try #require(parts.last)
    #expect(head.account == "codex:x")
    let layout = try #require(OwnItemLayout.head(comment: head.comment))
    #expect(layout == .chunked(count: parts.count, generation: "g1"))
    // Chunks are written before the head, so until the head changes the old value stays whole.
    #expect(Array(parts.dropLast().map(\.account)) == OwnItemLayout.chunkAccounts(layout, of: "codex:x"))
    for p in parts { #expect(SecurityCommand.addLine(service: svc, account: p.account, comment: p.comment, data: p.data) != nil) }
    // The reader joins the head's part, then the chunks in order.
    #expect(OwnItemLayout.join(head: head.data, chunks: parts.dropLast().map(\.data)) == data)
}

@Test func ownItemChunkNames() {
    #expect(OwnItemLayout.chunkAccounts(.single, of: "a") == [])
    #expect(OwnItemLayout.chunkAccounts(.chunked(count: 3, generation: "g"), of: "a") == ["a#g.1", "a#g.2"])
    #expect(OwnItemLayout.isChunk("a#g.1", of: "a"))
    #expect(!OwnItemLayout.isChunk("a", of: "a"))
    #expect(!OwnItemLayout.isChunk("ab#g.1", of: "a"))
    #expect(OwnItemLayout.head(comment: nil) == nil)
    #expect(OwnItemLayout.head(comment: "\(SecurityCommand.marker) chunks=0 gen=g") == nil)
    #expect(OwnItemLayout.head(comment: "other") == nil)
    #expect(OwnItemLayout.parts(service: "s", account: "a\"b", data: Data("x".utf8), generation: "g") == nil)
}

@Test func ownItemPlan() {
    #expect(OwnKeychainItem.plan(comment: nil, exists: false) == .missing)
    #expect(OwnKeychainItem.plan(comment: SecurityCommand.marker, exists: true) == .tool)
    // Written by an earlier Mate through the Security framework: readable only in process, then migrated.
    #expect(OwnKeychainItem.plan(comment: nil, exists: true) == .legacy)
    #expect(OwnKeychainItem.plan(comment: "something else", exists: true) == .legacy)
    #expect(OwnKeychainItem.plan(comment: "\(SecurityCommand.marker) chunks=2 gen=g", exists: true) == .tool)
}
