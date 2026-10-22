import Testing
import Foundation
@testable import MateCore

private func tempFile(_ content: String = "") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mate-logs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("log.jsonl")
    try Data(content.utf8).write(to: url)
    return url
}

private func append(_ s: String, to url: URL) throws {
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    try h.seekToEnd()
    try h.write(contentsOf: Data(s.utf8))
}

private func strings(_ lines: [Data]) -> [String] { lines.map { String(decoding: $0, as: UTF8.self) } }

@Test func partialLastLineIsKeptForNextRead() throws {
    let url = try tempFile("one\ntwo\nthr")
    let first = try IncrementalReader.read(url: url, cursor: nil)
    #expect(strings(first.lines) == ["one", "two"])
    #expect(first.cursor.pending == Data("thr".utf8))
    try append("ee\nfour\n", to: url)
    let second = try IncrementalReader.read(url: url, cursor: first.cursor)
    #expect(strings(second.lines) == ["three", "four"])
    #expect(second.cursor.pending.isEmpty)
    let third = try IncrementalReader.read(url: url, cursor: second.cursor)
    #expect(third.lines.isEmpty)
}

@Test func truncatedFileRestartsFromZero() throws {
    let url = try tempFile("aaaa\nbbbb\n")
    let first = try IncrementalReader.read(url: url, cursor: nil)
    try Data("c\n".utf8).write(to: url)
    let second = try IncrementalReader.read(url: url, cursor: first.cursor)
    #expect(strings(second.lines) == ["c"])
}

@Test func replacedFileRestartsFromZero() throws {
    let url = try tempFile("aaaa\n")
    let first = try IncrementalReader.read(url: url, cursor: nil)
    try FileManager.default.removeItem(at: url)
    try Data("bbbbbbbb\ncc\n".utf8).write(to: url)
    var cursor = first.cursor
    cursor.inode = first.cursor.inode &+ 1   // a rewritten file may reuse the inode; force the change
    let second = try IncrementalReader.read(url: url, cursor: cursor)
    #expect(strings(second.lines) == ["bbbbbbbb", "cc"])
}

@Test func oversizedPendingIsDropped() throws {
    let url = try tempFile(String(repeating: "x", count: 1_100_000))
    let first = try IncrementalReader.read(url: url, cursor: nil)
    #expect(first.lines.isEmpty)
    #expect(first.cursor.pending.isEmpty)
}

private let claudeAssistant = """
{"type":"assistant","timestamp":"2026-10-21T14:03:11.123Z","sessionId":"s1","cwd":"/Users/x/proj","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-4-5-20251101","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}}}
"""

@Test func claudeAssistantLineParsed() throws {
    let e = try #require(ClaudeLog.events(from: Data(claudeAssistant.utf8), sessionID: "fallback"))
    #expect(e.provider == .claude)
    #expect(e.model == "claude-opus-4-5-20251101")
    #expect(e.input == 10 && e.output == 20 && e.cacheWrite == 30 && e.cacheRead == 40)
    #expect(e.project == "proj")
    #expect(e.sessionID == "s1")
    #expect(e.dedupeKey == "msg_1:req_1")
    #expect(e.at == Date(timeIntervalSince1970: 1_792_591_391.123))
}

@Test func claudeNonAssistantLinesIgnored() {
    let user = #"{"type":"user","timestamp":"2026-10-21T14:03:11Z","message":{"role":"user","content":"hi"}}"#
    let noUsage = #"{"type":"assistant","timestamp":"2026-10-21T14:03:11Z","message":{"id":"m","model":"x"}}"#
    for l in [user, noUsage, "not json", ""] {
        #expect(ClaudeLog.events(from: Data(l.utf8), sessionID: "s") == nil)
    }
    let e = ClaudeLog.events(from: Data(claudeAssistant.replacingOccurrences(of: #""sessionId":"s1","#, with: "").utf8), sessionID: "fallback")
    #expect(e?.sessionID == "fallback")
}

@Test func duplicateClaudeMessageCountedOnce() throws {
    let e = try #require(ClaudeLog.events(from: Data(claudeAssistant.utf8), sessionID: "s"))
    var agg = UsageAggregates()
    let first = agg.add(e)
    let second = agg.add(e)
    #expect(first && !second)
    #expect(agg.today(now: e.at)[.claude] == 100)
}

private let codexLines = [
    #"{"timestamp":"2026-10-21T10:00:00.000Z","type":"turn_context","payload":{"cwd":"/Users/x/work/app","model":"gpt-5-codex"}}"#,
    #"{"timestamp":"2026-10-21T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":999,"output_tokens":999},"last_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":50,"reasoning_output_tokens":20}},"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_in_seconds":600},"secondary":{"used_percent":40,"window_minutes":10080,"resets_in_seconds":86400}}}}"#,
    #"{"timestamp":"2026-10-21T10:00:06.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":13,"window_minutes":300,"resets_in_seconds":590}}}}"#,
]

@Test func codexTokenCountUsesLastUsage() {
    var p = CodexLogParser()
    let none = p.parse(Data(codexLines[0].utf8), sessionID: "r1")
    #expect(none.0 == nil && none.rateLimits == nil)
    let r = p.parse(Data(codexLines[1].utf8), sessionID: "r1")
    let e = r.0
    #expect(e?.provider == .codex)
    #expect(e?.model == "gpt-5-codex")
    #expect(e?.project == "app")
    #expect(e?.input == 70)
    #expect(e?.cacheRead == 30)
    #expect(e?.output == 50)
    #expect(e?.cacheWrite == 0)
    #expect(e?.sessionID == "r1")
    #expect(e?.dedupeKey == nil)
}

@Test func codexRateLimitsExtracted() {
    var p = CodexLogParser()
    _ = p.parse(Data(codexLines[0].utf8), sessionID: "r1")
    let r = p.parse(Data(codexLines[1].utf8), sessionID: "r1")
    let now = Date(timeIntervalSince1970: 1_792_576_805)
    #expect(r.rateLimits?.map(\.kind) == [.session, .weekly])
    #expect(r.rateLimits?.first?.usedPercent == 12.5)
    #expect(r.rateLimits?.first?.resetsAt == now.addingTimeInterval(600))
    let nullInfo = p.parse(Data(codexLines[2].utf8), sessionID: "r1")
    #expect(nullInfo.0 == nil)
    #expect(nullInfo.rateLimits?.count == 1)
}

@Test func geminiStubReturnsNothing() {
    #expect(GeminiLog.events(from: Data("{}".utf8), sessionID: "s").isEmpty)
}
