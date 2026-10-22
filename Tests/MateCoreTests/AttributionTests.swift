import Testing
import Foundation
@testable import MateCore

@Test func accountIDMatchesWhatTheRegistryBuilds() {
    var registry = AccountRegistry()
    _ = registry.reconcile(provider: .claude,
                           observed: [ObservedSession(provider: .claude, configDir: "~/.claude", identity: "uuid-1", email: "a@b.c")],
                           scannedDirs: ["~/.claude"])
    #expect(registry.accounts.map(\.id) == [AccountRegistry.accountID(provider: .claude, identity: "uuid-1")])
    #expect(AccountRegistry.accountID(provider: .claude, identity: "uuid-1") == "claude:uuid-1")
}

@Test func schemaMismatchForcesRebuild() {
    #expect(UsageAggregates.needsRebuild(storedVersion: nil))
    #expect(UsageAggregates.needsRebuild(storedVersion: UsageAggregates.schemaVersion - 1))
    #expect(!UsageAggregates.needsRebuild(storedVersion: UsageAggregates.schemaVersion))
    #expect(UsageAggregates().storedSchema == UsageAggregates.schemaVersion)
}

@Test func storedSchemaSurvivesJSON() throws {
    let back = try JSONDecoder().decode(UsageAggregates.self, from: JSONEncoder().encode(UsageAggregates()))
    #expect(!UsageAggregates.needsRebuild(storedVersion: back.storedSchema))
}

@Test func logDirResolvesPlainAndSymlinkedDirs() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("mate-logdir-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: base) }
    let real = base.appendingPathComponent("real/projects/p")
    try fm.createDirectory(at: real, withIntermediateDirectories: true)
    let other = base.appendingPathComponent("other/projects")
    try fm.createDirectory(at: other, withIntermediateDirectories: true)
    let link = base.appendingPathComponent("link")
    try fm.createSymbolicLink(at: link, withDestinationURL: base.appendingPathComponent("real"))
    let roots = [(dir: "~/.claude", root: other.path), (dir: "/custom", root: link.appendingPathComponent("projects").path)]
    // Through the symlink and through the real path.
    #expect(LogDirs.configDir(forLogFile: link.path + "/projects/p/s.jsonl", roots: roots) == "/custom")
    #expect(LogDirs.configDir(forLogFile: real.path + "/s.jsonl", roots: roots) == "/custom")
    #expect(LogDirs.configDir(forLogFile: other.path + "/x/s.jsonl", roots: roots) == "~/.claude")
    #expect(LogDirs.configDir(forLogFile: base.path + "/elsewhere/s.jsonl", roots: roots) == nil)
}
