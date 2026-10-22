import AppKit
import MateCore

/// Command-line switches: `--fake` (scripted `FakeProvider`, in-memory vault, temp data dir unless `MATE_DATA_DIR`)
/// and `--dump` (fetch once, print non-secret fields, exit). `--debug-update` installs from a local test feed. UI checks: `--open-panel` opens the panel after launch
/// (and closes it 10 s later unless the mouse is over it),
/// `--demo-alert` drops a sample alert, `--snapshot-settings <dir>` / `--snapshot-welcome <dir>` write a PNG of every
/// settings page / welcome step (see `DebugCLI+Windows.swift`). `MATE_DEFAULTS_SUITE` keeps a test run's preferences
/// apart from the real ones.
/// Accounts (until Settings exists): `--add-account claude|codex` runs that provider's sign-in, stores the account,
/// fetches it once, prints it and exits; `--add-config-dir claude|codex <path>` adds a config-dir source, prints the
/// provider's accounts and exits; `--set-grok <teamId> [<budget>]` stores a Grok management key read from stdin.
@MainActor
enum DebugCLI {
    static var isFake: Bool { CommandLine.arguments.contains("--fake") }
    static var isDump: Bool { CommandLine.arguments.contains("--dump") }
    static var isIndex: Bool { CommandLine.arguments.contains("--index") }
    /// `MATE_HEADLESS=1`: a test run that shows nothing on the user's screen (no notch, no welcome guide, no window;
    /// reopening is only logged). With `--fake` the store runs as usual (`scripts/measure-idle.sh`); without it the
    /// store never starts, so the agents' sessions and the keychain are not touched (single-instance checks).
    static var isHeadless: Bool { ProcessInfo.processInfo.environment["MATE_HEADLESS"] == "1" }
    /// `--debug-update`: installs the newest release of the `updateFeedURL` test feed (see `Updater`).
    static var isDebugUpdate: Bool { CommandLine.arguments.contains("--debug-update") }

    /// The value after `flag`, if any.
    private static func value(after flag: String, offset: Int = 1) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + offset < args.count else { return nil }
        return args[i + offset]
    }

    /// `--add-account <provider>`.
    static var addAccountProvider: ProviderID? {
        guard CommandLine.arguments.contains("--add-account") else { return nil }
        return parseProvider(value(after: "--add-account"))
    }

    /// `--add-config-dir <provider> <path>`.
    static var addConfigDir: (ProviderID, String)? {
        guard CommandLine.arguments.contains("--add-config-dir") else { return nil }
        guard let p = parseProvider(value(after: "--add-config-dir")), let path = value(after: "--add-config-dir", offset: 2) else {
            print("usage: Mate --add-config-dir claude|codex <path>")
            exit(2)
        }
        return (p, path)
    }

    private static func parseProvider(_ s: String?) -> ProviderID? {
        guard let s, let p = ProviderID(rawValue: s), p == .claude || p == .codex else {
            print("expected claude or codex")
            exit(2)
        }
        return p
    }

    /// Runs `--add-account` (the app must be running: the sign-in shows a window) and exits.
    static func addAccount(_ provider: ProviderID) async -> Never {
        let store = makeStore()
        do {
            let a = try await store.addLogin(provider: provider)
            store.flush()
            print(render(accounts: [a], snapshots: store.snapshots))
            exit(0)
        } catch {
            store.flush()
            print("sign-in failed: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
            exit(1)
        }
    }

    /// Runs `--add-config-dir` and exits.
    static func addConfigDir(_ provider: ProviderID, path: String) async -> Never {
        let store = makeStore()
        do {
            let result = try await store.addConfigDir(provider: provider, path: path)
            store.flush()
            let accounts = store.accounts.filter { $0.provider == provider }
            let dir = UsageStore.canonicalDir(path)
            switch result {
            case .added: print("watching \(dir) for \(provider.rawValue)")
            case .alreadyWatched: print("\(dir) was already watched for \(provider.rawValue); nothing changed")
            case .isDefaultDir: print("\(dir) is \(provider.rawValue)'s default folder, always watched; nothing changed")
            }
            print(render(accounts: accounts, snapshots: store.snapshots))
            exit(0)
        } catch {
            print("could not add the folder: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
            exit(1)
        }
    }

    /// `--set-grok <teamId> [<budget USD>]`: the team id (and optionally the monthly budget).
    static var setGrok: (team: String, budget: Double?)? {
        guard CommandLine.arguments.contains("--set-grok") else { return nil }
        guard let team = value(after: "--set-grok"), !team.hasPrefix("--"), !team.isEmpty else {
            print("usage: echo -n <management key> | Mate --set-grok <teamId> [<monthly budget USD>]")
            exit(2)
        }
        let budget = value(after: "--set-grok", offset: 2).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        return (team, budget)
    }

    /// Runs `--set-grok`: reads the management key from stdin (never echoed or logged), stores it in Mate's keychain
    /// for the team, sets the budget when given, and exits.
    static func setGrok(team: String, budget: Double?) -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let key = String(decoding: input, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { print("no key on stdin"); exit(2) }
        do {
            try GrokProvider.setKey(key, teamID: team)
        } catch {
            print("could not store the key: \(error)")
            exit(1)
        }
        if let budget {
            guard budget >= 0, budget.isFinite else { print("bad budget"); exit(2) }
            UserDefaults.mate.set(budget, forKey: PrefKey.grokMonthlyBudget.rawValue)
        }
        let b = GrokProvider.budget
        print("grok key stored for team \(team); monthly budget \(b > 0 ? "USD \(b)" : "not set (Grok stays hidden until it is)")")
        exit(0)
    }

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
                    captureWindow(UsageWindowController.shared.debugWindowNumber, to: "\(dir)/usage.png")
                }
            }
        }
        scheduleWindowSnapshots(notch: notch)
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
    static func snapshot(_ view: NSView, to path: String) {
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
        let providers: [any Provider] = fake ? [FakeProvider()]
            : [ClaudeProvider(), CodexProvider(), CursorProvider(), GeminiProvider(), CopilotProvider(), GrokProvider()]
        let vault: TokenVault = fake ? MemoryVault() : KeychainVault.shared
        return UsageStore(providers: providers, vault: vault, persistence: Persistence(dir: Persistence.defaultDir(fake: fake)))
    }

    /// Runs the dump and exits the process.
    static func dump() async -> Never {
        let store = makeStore()
        await store.runOnce()
        print(render(accounts: store.accounts, snapshots: store.snapshots))
        exit(0)
    }

    /// The provider whose logs `--index` and `--dump --day` read: `--index codex` / `--logs codex`, Claude otherwise.
    private static func logProvider() -> any Provider {
        let name = value(after: isIndex ? "--index" : "--logs")
        return name == "codex" ? CodexProvider() : ClaudeProvider()
    }

    /// `--index [codex]`: indexes one provider's logs (no keychain, no network) into the data dir, prints totals,
    /// the events per config dir (account attribution) and peak memory, and exits. For measuring the first-launch scan.
    static func index() -> Never {
        requireDataDir()
        let persistence = Persistence(dir: Persistence.defaultDir(fake: false))
        let provider = logProvider()
        let state = persistence.loadIndexState()
        let indexer = LogIndexer(cursors: state.cursors)
        var aggregates = state.aggregates
        var count = 0
        var perDir: [String: Int] = [:]
        var perModel: [String: Int] = [:]
        let started = Date()
        indexer.index(provider, paths: provider.watchedPaths, fullScan: true, qos: .utility, deliver: { events, cursors in
            for e in events where aggregates.add(e) {
                count += 1
                perDir[e.logDir ?? "(none)", default: 0] += 1
                perModel[e.model, default: 0] += 1
            }
            persistence.save("aggregates") { aggregates }
            persistence.save("cursors") { cursors }
        }, done: {
            persistence.flush()
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let today = aggregates.today(now: Date()).values.reduce(0, +)
            print("indexed \(count) events in \(String(format: "%.1f", Date().timeIntervalSince(started))) s; "
                  + "tokens today \(today); peak RSS \(usage.ru_maxrss / 1_048_576) MB")
            for (dir, n) in perDir.sorted(by: { $0.key < $1.key }) { print("  dir \(dir): \(n) events") }
            for (model, n) in perModel.sorted(by: { $0.key < $1.key }) { print("  model \(model): \(n) events") }
            exit(0)
        })
        dispatchMain()
    }

    /// `--dump --day YYYY-MM-DD`: indexes the Claude logs (Codex with `--logs codex`) into the data dir (no keychain,
    /// no network; use `MATE_DATA_DIR`), prints that local day's tokens per provider and per model, and exits.
    static func dumpDay(_ day: String) -> Never {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: day) else { print("bad day '\(day)', expected YYYY-MM-DD"); exit(2) }
        requireDataDir()
        let persistence = Persistence(dir: Persistence.defaultDir(fake: false))
        let provider = logProvider()
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
