import AppKit
import MateCore

/// Command-line switches: `--fake` (scripted `FakeProvider`, in-memory vault, temp data dir unless `MATE_DATA_DIR`)
/// and `--dump` (fetch once, print non-secret fields, exit). UI checks: `--open-panel` opens the panel after launch
/// (and closes it 10 s later unless the mouse is over it),
/// `--demo-alert` drops a sample alert.
@MainActor
enum DebugCLI {
    static var isFake: Bool { CommandLine.arguments.contains("--fake") }
    static var isDump: Bool { CommandLine.arguments.contains("--dump") }
    static var isIndex: Bool { CommandLine.arguments.contains("--index") }

    /// One-shot UI checks for screenshots, a moment after launch (once the fake accounts have data).
    static func scheduleUIChecks(notch: NotchController, store: UsageStore) {
        let args = CommandLine.arguments
        if args.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { notch.openPanel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { notch.closePanelUnlessHovered() }
        }
        if args.contains("--demo-alert") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let id = store.accounts.first?.id else { return }
                notch.presentAlert(AlertEvent(kind: .threshold(90), accountID: id, window: .session, percent: 90,
                                              resetsAt: Date().addingTimeInterval(4800)))
            }
        }
        // `--snapshot <dir>`: PNGs of the notch window at 1, 3, 11 and 16 s, rendered in-process (no screen recording).
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = args[i + 1]
            for t in [1.0, 3.0, 11.0, 16.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    snapshot(notch.debugView, to: "\(dir)/notch-\(Int(t))s.png")
                }
            }
        }
    }

    /// Renders the view's layer tree over a mid-gray backdrop, so the black shape is visible.
    private static func snapshot(_ view: NSView, to path: String) {
        guard let layer = view.layer else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        guard size.width > 0, size.height > 0,
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let image = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            Log.info("snapshot \(path) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
        } catch {
            Log.error("snapshot \(path): \(error)")
        }
    }

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

    /// `--index`: indexes the Claude logs only (no keychain, no network) into the data dir, prints totals and peak
    /// memory, and exits. For measuring the first-launch scan.
    static func index() -> Never {
        let persistence = Persistence(dir: Persistence.defaultDir(fake: false))
        let provider = ClaudeProvider()
        let indexer = LogIndexer(cursors: persistence.load([String: FileCursor].self, "cursors") ?? [:])
        var aggregates = persistence.load(UsageAggregates.self, "aggregates") ?? UsageAggregates()
        var count = 0
        let started = Date()
        indexer.index(provider, paths: provider.watchedPaths, fullScan: true, qos: .utility, deliver: { events, cursors in
            for e in events where aggregates.add(e) { count += 1 }
            persistence.save("aggregates") { aggregates }
            persistence.save("cursors") { cursors }
        }, done: {
            persistence.flush()
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let today = aggregates.today(now: Date()).values.reduce(0, +)
            print("indexed \(count) events in \(String(format: "%.1f", Date().timeIntervalSince(started))) s; "
                  + "tokens today \(today); peak RSS \(usage.ru_maxrss / 1_048_576) MB")
            exit(0)
        })
        dispatchMain()
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
