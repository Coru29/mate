import Foundation
import MateCore

/// Command-line switches: `--fake` (scripted `FakeProvider`, in-memory vault, temp data dir unless `MATE_DATA_DIR`)
/// and `--dump` (fetch once, print non-secret fields, exit).
@MainActor
enum DebugCLI {
    static var isFake: Bool { CommandLine.arguments.contains("--fake") }
    static var isDump: Bool { CommandLine.arguments.contains("--dump") }

    static func makeStore() -> UsageStore {
        let fake = isFake
        let providers: [any Provider] = fake ? [FakeProvider()] : [ClaudeProvider()]
        let vault: TokenVault = fake ? MemoryVault() : KeychainVault()
        return UsageStore(providers: providers, vault: vault, persistence: Persistence(dir: Persistence.defaultDir(fake: fake)))
    }

    /// Runs the dump and exits the process.
    static func dump() async -> Never {
        let store = makeStore()
        await store.runOnce()
        print(render(accounts: store.accounts, snapshots: store.snapshots))
        exit(0)
    }

    static func render(accounts: [Account], snapshots: [String: UsageSnapshot]) -> String {
        guard !accounts.isEmpty else { return "no accounts" }
        let time = DateFormatter()
        time.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = []
        for a in accounts {
            let owner = a.owner == .agent ? "agent(\(a.agentConfigDir ?? "?"))" : "mate"
            lines.append("\(a.id)  email=\(a.email ?? "-")  owner=\(owner)  status=\(status(a.status))\(a.hidden ? "  hidden" : "")")
            guard let s = snapshots[a.id] else { lines.append("  (no data)"); continue }
            lines.append("  fetched \(time.string(from: s.fetchedAt))")
            for w in s.windows {
                let reset = w.resetsAt.map { "resets \(time.string(from: $0))" } ?? "no reset"
                let detail = w.detail.map { "  \($0)" } ?? ""
                lines.append("  \(w.kind.key): \(String(format: "%.1f", w.usedPercent)) %  \(reset)\(detail)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func status(_ s: AccountStatus) -> String {
        switch s {
        case .ok: "ok"
        case .stale: "stale"
        case .expired: "expired"
        case .error(let why): "error(\(why))"
        }
    }
}
