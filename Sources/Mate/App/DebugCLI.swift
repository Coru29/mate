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

    /// `--dump --day YYYY-MM-DD`: the day to print per-provider/per-model totals for (log reading only).
    static var dumpDay: String? {
        let args = CommandLine.arguments
        guard isDump, let i = args.firstIndex(of: "--day"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

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
        // `--open-usage`: opens the usage window after launch; with `--snapshot <dir>` also writes usage.png.
        if args.contains("--open-usage") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { UsageWindowController.shared.show() }
            if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
                let dir = args[i + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    // The window's own pixels (SwiftUI text does not survive `cacheDisplay`).
                    guard let number = UsageWindowController.shared.debugWindowNumber,
                          let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(number),
                                                              .boundsIgnoreFraming) else { return }
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(dir)/usage.png"))
                    Log.info("snapshot \(dir)/usage.png")
                }
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
        requireDataDir()
        let persistence = Persistence(dir: Persistence.defaultDir(fake: false))
        let provider = ClaudeProvider()
        let state = persistence.loadIndexState()
        let indexer = LogIndexer(cursors: state.cursors)
        var aggregates = state.aggregates
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

    /// `--dump --day YYYY-MM-DD`: indexes the Claude logs into the data dir (no keychain, no network; use
    /// `MATE_DATA_DIR`), prints that local day's tokens per provider and per model, and exits.
    static func dumpDay(_ day: String) -> Never {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: day) else { print("bad day '\(day)', expected YYYY-MM-DD"); exit(2) }
        requireDataDir()
        let persistence = Persistence(dir: Persistence.defaultDir(fake: false))
        let provider = ClaudeProvider()
        let state = persistence.loadIndexState()
        let indexer = LogIndexer(cursors: state.cursors)
        var aggregates = state.aggregates
        indexer.index(provider, paths: provider.watchedPaths, fullScan: true, qos: .userInitiated, deliver: { events, cursors in
            for e in events { aggregates.add(e) }
            persistence.save("aggregates") { aggregates }
            persistence.save("cursors") { cursors }
        }, done: {
            persistence.flush()
            let noon = date.addingTimeInterval(12 * 3600)
            let perProvider = aggregates.daily(last: 1, now: noon)[0].perProvider
            print("day \(day)")
            for (p, total) in perProvider.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                print("\(p.rawValue): \(total) tokens")
                for m in aggregates.byModel(last: 1, now: noon, provider: p) {
                    print("  \(m.model): \(m.tokens) tokens, est. \(NotchText.usd(m.cost))")
                }
            }
            if perProvider.isEmpty { print("no usage") }
            exit(0)
        })
        dispatchMain()
    }

    /// Debug runs that write indexes must never touch the real data dir.
    private static func requireDataDir() {
        guard ProcessInfo.processInfo.environment["MATE_DATA_DIR"]?.isEmpty ?? true else { return }
        print("refusing to run: set MATE_DATA_DIR to a scratch directory (debug runs never touch the real data dir)")
        exit(2)
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
