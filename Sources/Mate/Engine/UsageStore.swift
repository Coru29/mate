import Foundation
import MateCore

/// Owns all app state: accounts (single-owner token rules from `AccountRegistry`), snapshots, samples, alerts,
/// aggregates. Fetches with one-shot timers per `FetchSchedule`; reconciles on changes of the agents' session files.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var snapshots: [String: UsageSnapshot] = [:]
    @Published private(set) var activeProvider: ProviderID?
    @Published var selectedAccountID: String?
    @Published private(set) var aggregates = UsageAggregates()
    /// While paused nothing is fetched on a schedule and the agents' files are not watched.
    @Published private(set) var isPaused = false
    var onAlert: (AlertEvent) -> Void = { _ in }

    static let sampleRetention: TimeInterval = 8 * 86_400

    private struct FetchState {
        /// Last completed attempt that was not a failure (success, or skipped because the agent's token expired).
        var lastAttempt: Date?
        var failures = 0
        var lastFailure: Date?
        var inFlight = false
    }

    private let providers: [any Provider]
    private let vault: TokenVault
    private let persistence: Persistence
    private let indexer: LogIndexer
    private let schedule = FetchSchedule()
    private var registry: AccountRegistry
    private var samplesByKey: [String: [Sample]]
    private var alertEngine: AlertEngine
    private var fetchState: [String: FetchState] = [:]
    private var activity = ActivityTracker()
    private var panelOpen = false
    private var fetchTimer: Timer?
    private var activityTimer: Timer?
    private var watcher: FileWatcher?
    private var reconciling: Set<ProviderID> = []
    private var reconcileAgain: Set<ProviderID> = []
    /// "provider|configDir" whose keychain prompt the user denied: no automatic credential read until `refreshNow()`.
    private var deniedDirs: Set<String> = []
    /// In-flight agent-credential reads per "provider|configDir", shared so at most one keychain prompt is pending.
    private var credentialReads: [String: Task<Data?, Error>] = [:]

    init(providers: [any Provider], vault: TokenVault, persistence: Persistence) {
        self.providers = providers
        self.vault = vault
        self.persistence = persistence
        registry = persistence.load(AccountRegistry.self, "registry") ?? AccountRegistry()
        snapshots = persistence.load([String: UsageSnapshot].self, "snapshots") ?? [:]
        samplesByKey = persistence.load([String: [Sample]].self, "samples") ?? [:]
        alertEngine = persistence.load(AlertEngine.self, "alerts") ?? AlertEngine()
        aggregates = persistence.load(UsageAggregates.self, "aggregates") ?? UsageAggregates()
        indexer = LogIndexer(cursors: persistence.load([String: FileCursor].self, "cursors") ?? [:])
        accounts = registry.accounts
        for (id, s) in snapshots { fetchState[id] = FetchState(lastAttempt: s.fetchedAt) }
        for p in providers {
            p.extraConfigDirs = registry.accounts.compactMap {
                guard $0.provider == p.id, case .configDir(let dir) = $0.source else { return nil }
                return dir
            }
        }
        pruneSamples(now: Date())
    }

    // MARK: Public API

    func start() {
        let paths = providers.flatMap { $0.watchedPaths + $0.sessionFiles }
        let w = FileWatcher(paths: paths) { [weak self] changed in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.filesChanged(changed) } }
        }
        w.start()
        watcher = w
        updateActivity()
        let firstRun = indexer.isFirstRun
        for p in providers {
            indexer.index(p, paths: p.watchedPaths, fullScan: true,
                          qos: firstRun ? .background : .utility) { [weak self] events, cursors in
                self?.ingest(events, cursors: cursors)
            }
        }
        Task {
            for p in providers { await reconcile(p) }
            scheduleFetches()
        }
    }

    /// `--dump`: reconcile and fetch every account once, then write everything to disk.
    func runOnce() async {
        for p in providers { await reconcile(p) }
        for a in registry.accounts where !a.hidden { await fetch(a.id) }
        persistence.flush()
    }

    func panelDidOpen() {
        panelOpen = true
        guard !isPaused else { return }
        let now = Date()
        for a in registry.accounts where !a.hidden
            && schedule.shouldFetchOnPanelOpen(lastSuccess: snapshots[a.id]?.fetchedAt, now: now) {
            Task { await fetch(a.id) }
        }
        scheduleFetches()
    }

    func panelDidClose() {
        panelOpen = false
        scheduleFetches()
    }

    /// Pausing stops every scheduled fetch and the FSEvents stream; resuming catches up on the logs and fetches.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            fetchTimer?.invalidate()
            fetchTimer = nil
            watcher?.stop()
            Log.info("paused")
            return
        }
        watcher?.start()
        for p in providers {
            indexer.index(p, paths: p.watchedPaths, fullScan: true, qos: .utility) { [weak self] events, cursors in
                self?.ingest(events, cursors: cursors)
            }
        }
        Task {
            for p in providers { await reconcile(p) }
            scheduleFetches()
        }
        Log.info("resumed")
    }

    /// Explicit user action (also while paused): also retries config dirs whose keychain prompt was denied.
    func refreshNow() {
        deniedDirs.removeAll()
        Task {
            for p in providers { await reconcile(p) }
            for a in registry.accounts where !a.hidden { fetchState[a.id]?.failures = 0; await fetch(a.id) }
        }
    }

    func samples(for accountID: String, window: WindowKind) -> [Sample] {
        samplesByKey[Self.sampleKey(accountID, window)] ?? []
    }

    /// Writes pending state now (app termination).
    func flush() { persistence.flush() }

    // MARK: Reconcile

    private func provider(_ id: ProviderID) -> (any Provider)? { providers.first { $0.id == id } }

    /// Re-reads the provider's sessions and applies the single-owner rules. Coalesces overlapping calls.
    private func reconcile(_ p: any Provider) async {
        guard reconciling.insert(p.id).inserted else { reconcileAgain.insert(p.id); return }
        defer { reconciling.remove(p.id) }
        repeat {
            reconcileAgain.remove(p.id)
            let scan = await p.observeSessions()
            let before = Dictionary(uniqueKeysWithValues: registry.accounts.map { ($0.id, ($0.owner, $0.agentConfigDir)) })
            let actions = registry.reconcile(provider: p.id, observed: scan.sessions, scannedDirs: scan.scannedDirs)
            commitRegistry()
            for action in actions {
                switch action {
                case .storeShadow(let id, let dir):
                    // Fetches keep the shadow current; here only new or changed ownership needs a copy right away.
                    let unchanged = before[id].map { $0.0 == .agent && $0.1 == dir } ?? false
                    if unchanged, (try? vault.read(p.id, accountID: id)) != nil { continue }
                    do {
                        if let data = try await agentCredentials(p, configDir: dir) { storeShadow(id, data: data, configDir: dir) }
                    } catch {
                        Log.error("\(p.id.rawValue): could not read the agent's credentials for \(id): \(error)")
                    }
                case .dropMateCopy(let id):
                    do { try vault.delete(p.id, accountID: id) } catch { Log.error("vault delete \(id): \(error)") }
                }
            }
            if selectedAccountID == nil || !registry.accounts.contains(where: { $0.id == selectedAccountID }) {
                selectedAccountID = registry.accounts.first { !$0.hidden }?.id
            }
        } while reconcileAgain.contains(p.id)
        scheduleFetches()
    }

    /// The agent's credentials for `configDir`. Reads are shared per dir (one keychain prompt at a time); a denied
    /// prompt marks the dir and its accounts `.error("keychainDenied")` and blocks automatic reads until `refreshNow()`.
    private func agentCredentials(_ p: any Provider, configDir dir: String) async throws -> Data? {
        let key = "\(p.id.rawValue)|\(dir)"
        if deniedDirs.contains(key) { throw ProviderError.credentialsDenied }
        if let running = credentialReads[key] { return try await running.value }
        let task = Task { try await p.agentCredentials(configDir: dir) }
        credentialReads[key] = task
        defer { credentialReads[key] = nil }
        do {
            return try await task.value
        } catch ProviderError.credentialsDenied {
            deniedDirs.insert(key)
            Log.error("\(p.id.rawValue): keychain access denied for \(dir); waiting for an explicit refresh")
            for a in registry.accounts where a.provider == p.id && a.owner == .agent && a.agentConfigDir == dir {
                setStatus(a.id, .error("keychainDenied"))
            }
            throw ProviderError.credentialsDenied
        }
    }

    /// Keeps Mate's copy of an agent-owned account's credentials current, so it can take over refreshing them
    /// when the agent logs in to another account. Never writes the agent's own store.
    private func storeShadow(_ id: String, data: Data, configDir: String) {
        guard let a = registry.accounts.first(where: { $0.id == id }), a.owner == .agent,
              a.agentConfigDir == configDir else { return }
        if isOtherAccountsCopy(data, of: a) {
            Log.info("\(id): agent credentials still belong to another account; not copied")
            return
        }
        if (try? vault.read(a.provider, accountID: id)) == data { return }
        do { try vault.write(a.provider, accountID: id, data: data) } catch { Log.error("vault write \(id): \(error)") }
    }

    /// During a `/login` the identity file can change before the keychain item: the agent's store then still holds
    /// the previous account's credentials, which Mate already has as that account's copy.
    private func isOtherAccountsCopy(_ data: Data, of account: Account) -> Bool {
        registry.accounts.contains {
            $0.provider == account.provider && $0.id != account.id && (try? vault.read($0.provider, accountID: $0.id)) == data
        }
    }

    private func commitRegistry() {
        if accounts != registry.accounts { accounts = registry.accounts }
        persistence.save("registry") { [unowned self] in registry }
    }

    private func setStatus(_ id: String, _ status: AccountStatus) {
        guard let i = registry.accounts.firstIndex(where: { $0.id == id }), registry.accounts[i].status != status else { return }
        registry.accounts[i].status = status
        commitRegistry()
    }

    // MARK: Fetch

    private enum Outcome { case success([LimitWindow]), skipped(AccountStatus), failed(AccountStatus) }

    private func fetch(_ id: String) async {
        guard let account = registry.accounts.first(where: { $0.id == id }), let p = provider(account.provider),
              fetchState[id]?.inFlight != true else { return }
        fetchState[id, default: FetchState()].inFlight = true
        let outcome = await (account.owner == .agent ? fetchAgentOwned(account, p) : fetchMateOwned(account, p))
        let now = Date()
        var state = fetchState[id] ?? FetchState()
        state.inFlight = false
        switch outcome {
        case .success(let windows):
            state.lastAttempt = now
            state.failures = 0
            record(UsageSnapshot(accountID: id, windows: windows, fetchedAt: now))
            setStatus(id, .ok)
        case .skipped(let status):
            state.lastAttempt = now
            state.failures = 0
            setStatus(id, status)
        case .failed(let status):
            state.failures += 1
            state.lastFailure = now
            setStatus(id, status)
        }
        fetchState[id] = state
        scheduleFetches()
    }

    /// Credentials read fresh from the agent; never refreshed. Expired → `.stale` until the agent refreshes them.
    private func fetchAgentOwned(_ account: Account, _ p: any Provider) async -> Outcome {
        guard let dir = account.agentConfigDir else { return .skipped(.stale) }
        let data: Data
        do {
            guard let d = try await agentCredentials(p, configDir: dir) else { return .skipped(.stale) }
            data = d
        } catch ProviderError.credentialsDenied {
            return .skipped(.error("keychainDenied"))
        } catch {
            Log.error("\(account.id): agent credentials unreadable: \(error)")
            return .failed(.error("keychain"))
        }
        guard let tokens = try? p.decodeCredentials(data) else { return .failed(.error("credentials")) }
        if isOtherAccountsCopy(data, of: account) { return .skipped(.stale) }
        storeShadow(account.id, data: data, configDir: dir)
        switch registry.refreshDecision(for: account.id, expiresAt: tokens.expiresAt, now: Date()) {
        case .stale: return .skipped(.stale)
        case .useAsIs, .refresh: break // `.refresh` never happens for an agent-owned account.
        }
        do {
            return .success(try await p.fetchUsage(account: account, tokens: tokens))
        } catch ProviderError.unauthorized {
            return .skipped(.stale) // FetchPolicy: always .markStale for agent-owned; the agent will refresh it

        } catch {
            return .failed(Self.status(error))
        }
    }

    /// Mate's own copy; refreshed when it expires within 5 min, the rotated tokens saved before they are used.
    private func fetchMateOwned(_ account: Account, _ p: any Provider) async -> Outcome {
        let original: Data
        var tokens: OAuthTokens
        do {
            guard let d = try vault.read(account.provider, accountID: account.id) else { return .skipped(.expired) }
            original = d
            tokens = try p.decodeCredentials(d)
        } catch {
            Log.error("\(account.id): Mate's copy unreadable: \(error)")
            return .failed(.error("keychain"))
        }
        var refreshed = false
        do {
            if registry.refreshDecision(for: account.id, expiresAt: tokens.expiresAt, now: Date()) == .refresh {
                tokens = try await refreshAndSave(account, p, tokens, original: original)
                refreshed = true
            }
            do {
                return .success(try await p.fetchUsage(account: account, tokens: tokens))
            } catch ProviderError.unauthorized
                where FetchPolicy.onUnauthorized(owner: .mate, alreadyRefreshed: refreshed) == .refreshAndRetry {
                tokens = try await refreshAndSave(account, p, tokens, original: original)
                return .success(try await p.fetchUsage(account: account, tokens: tokens))
            }
        } catch ProviderError.unauthorized {
            return .skipped(.expired)
        } catch ProviderError.refreshNotAllowed {
            return .skipped(.stale) // ownership moved to the agent meanwhile
        } catch {
            return .failed(Self.status(error))
        }
    }

    private func refreshAndSave(_ account: Account, _ p: any Provider, _ tokens: OAuthTokens,
                                original: Data) async throws -> OAuthTokens {
        let new = try await p.refresh(tokens, accountID: account.id, registry: registry)
        // Rotated refresh tokens invalidate the old ones: persist before anything else uses them.
        guard registry.canRefresh(account.id) else { throw ProviderError.refreshNotAllowed }
        let data = try p.encodeCredentials(new, preserving: original)
        do {
            try vault.write(account.provider, accountID: account.id, data: data)
        } catch {
            do {
                try vault.write(account.provider, accountID: account.id, data: data)
            } catch {
                // The old refresh token is already rotated away: without the new one saved the session is gone.
                Log.error("\(account.id): could not save refreshed tokens (\(error)); the account needs a new login")
                throw ProviderError.unauthorized
            }
        }
        return new
    }

    private static func status(_ error: Error) -> AccountStatus {
        switch error {
        case ProviderError.rateLimited: .error("rateLimited")
        case ProviderError.unavailable(let why): .error(why)
        case is ParseError: .error("response")
        default: .error((error as NSError).localizedDescription)
        }
    }

    private func record(_ snapshot: UsageSnapshot) {
        snapshots[snapshot.accountID] = snapshot
        for w in snapshot.windows {
            samplesByKey[Self.sampleKey(snapshot.accountID, w.kind), default: []]
                .append(Sample(at: snapshot.fetchedAt, percent: w.usedPercent))
        }
        pruneSamples(now: snapshot.fetchedAt)
        let thresholds = UserDefaults.mate.array(forKey: PrefKey.alertThresholds.rawValue) as? [Int]
            ?? Preferences.defaults[PrefKey.alertThresholds.rawValue] as? [Int] ?? []
        for event in alertEngine.evaluate(snapshot, thresholds: thresholds) { onAlert(event) }
        persistence.save("snapshots") { [unowned self] in snapshots }
        persistence.save("samples") { [unowned self] in samplesByKey }
        persistence.save("alerts") { [unowned self] in alertEngine }
    }

    private static func sampleKey(_ id: String, _ kind: WindowKind) -> String { "\(id)|\(kind.key)" }

    private func pruneSamples(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.sampleRetention)
        for key in samplesByKey.keys {
            samplesByKey[key]?.removeAll { $0.at < cutoff }
            if samplesByKey[key]?.isEmpty == true { samplesByKey[key] = nil }
        }
    }

    // MARK: Scheduling (one-shot timers only)

    private func isActive(_ p: ProviderID, now: Date) -> Bool {
        provider(p)?.alwaysActive == true || activity.activeProviders(now: now).contains(p)
    }

    /// Next fetch of an account: its `FetchSchedule` date, or 5 s after the earliest window reset if sooner.
    private func due(_ a: Account, now: Date) -> Date {
        let s = fetchState[a.id] ?? FetchState()
        // Never fetched: now (`FetchSchedule` counts a nil last success from `now`).
        if s.lastAttempt == nil && s.failures == 0 { return now }
        var next = schedule.nextFetch(lastSuccess: s.lastAttempt, failures: s.failures,
                                      active: isActive(a.provider, now: now), panelOpen: panelOpen, now: now,
                                      lastFailure: s.lastFailure)
        if s.failures == 0, let reset = snapshots[a.id]?.windows.compactMap(\.resetsAt).filter({ $0 > now.addingTimeInterval(-5) }).min() {
            next = min(next, max(reset.addingTimeInterval(5), now))
        }
        return next
    }

    /// Hidden accounts and expired Mate copies (they need a new login) are not fetched on a schedule.
    private func isSchedulable(_ a: Account) -> Bool {
        !a.hidden && !(a.owner == .mate && a.status == .expired) && fetchState[a.id]?.inFlight != true
    }

    private func scheduleFetches() {
        fetchTimer?.invalidate()
        fetchTimer = nil
        guard !isPaused else { return }
        let now = Date()
        let candidates = registry.accounts.filter(isSchedulable)
        guard let next = candidates.map({ due($0, now: now) }).min() else { return }
        let interval = max(next.timeIntervalSince(now), 0)
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetchDue() }
        }
        t.tolerance = max(interval * 0.1, 1)
        RunLoop.main.add(t, forMode: .common)
        fetchTimer = t
    }

    private func fetchDue() {
        fetchTimer = nil
        let now = Date()
        let dueNow = registry.accounts.filter { isSchedulable($0) && due($0, now: now) <= now.addingTimeInterval(1) }
        if dueNow.isEmpty { scheduleFetches(); return }
        for a in dueNow { Task { await fetch(a.id) } }
    }

    // MARK: Files and activity

    private func filesChanged(_ paths: [String]) {
        guard !isPaused else { return }
        let now = Date()
        for p in providers {
            let sessionFiles = Set(p.sessionFiles.flatMap { [$0, URL(fileURLWithPath: $0).resolvingSymlinksInPath().path] })
            if paths.contains(where: sessionFiles.contains) { Task { await reconcile(p) } }
            let logs = p.logFiles(in: paths)
            guard !logs.isEmpty else { continue }
            let wasActive = isActive(p.id, now: now)
            activity.noteWrite(p.id, at: now)
            indexer.index(p, paths: logs, fullScan: false, qos: .utility) { [weak self] events, cursors in
                self?.ingest(events, cursors: cursors)
            }
            if !wasActive { scheduleFetches() }
        }
        updateActivity()
    }

    private func updateActivity() {
        let now = Date()
        let active = activity.activeProviders(now: now).first ?? providers.first { $0.alwaysActive }?.id
        if activeProvider != active { activeProvider = active }
        activityTimer?.invalidate()
        activityTimer = nil
        guard let expiry = activity.nextExpiry(now: now) else { return }
        let interval = max(expiry.timeIntervalSince(now), 0)
        let t = Timer(fire: expiry.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateActivity()
                self?.scheduleFetches()
            }
        }
        t.tolerance = max(interval * 0.1, 1)
        RunLoop.main.add(t, forMode: .common)
        activityTimer = t
    }

    private func ingest(_ events: [TokenEvent], cursors: [String: FileCursor]) {
        if !events.isEmpty {
            var agg = aggregates
            for e in events { agg.add(e) }
            aggregates = agg
            persistence.save("aggregates") { [unowned self] in aggregates }
        }
        persistence.save("cursors") { cursors }
    }
}
