import MateCore
import Foundation

/// JSON files under `~/Library/Application Support/Mate/` (or `$MATE_DATA_DIR`). Saves are debounced per
/// `SaveSchedule`: most files 2 s after their last change (at most 60 s after the first unsaved one); the index
/// state (`aggregates`, `cursors`) on its own, much slower schedule, always written together and cursors last.
/// Encoding and writing run off the main thread on a snapshot of the value, atomically. `flush()` writes everything
/// pending synchronously.
@MainActor
final class Persistence {
    static let indexFiles: Set<String> = ["aggregates", "cursors"]

    let dir: URL
    private let queue = DispatchQueue(label: "io.github.coru29.Mate.persistence", qos: .utility)

    /// Files saved on one schedule, written together by one one-shot timer.
    @MainActor private final class Lane {
        var schedule: SaveSchedule
        var pending: [String: @MainActor () -> @Sendable () throws -> Data] = [:]
        var timer: Timer?
        init(_ policy: SaveSchedule.Policy) { schedule = SaveSchedule(policy: policy) }
    }
    private let standard = Lane(.standard)
    private let index = Lane(.index)

    init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// `$MATE_DATA_DIR` when set; otherwise a temp dir in fake mode (fake runs never touch real data) or
    /// `~/Library/Application Support/Mate`.
    static func defaultDir(fake: Bool) -> URL {
        if let custom = ProcessInfo.processInfo.environment["MATE_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom.expandingTilde, isDirectory: true)
        }
        if fake { return FileManager.default.temporaryDirectory.appendingPathComponent("Mate-fake", isDirectory: true) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Mate", isDirectory: true)
    }

    /// Aggregates and log cursors, dropped together when the persisted aggregates predate the current schema
    /// (or are missing while cursors exist), so the logs are indexed again.
    func loadIndexState() -> (aggregates: UsageAggregates, cursors: [String: FileCursor]) {
        let stored = load(UsageAggregates.self, "aggregates")
        let cursors = load([String: FileCursor].self, "cursors") ?? [:]
        if let stored, !UsageAggregates.needsRebuild(storedVersion: stored.storedSchema) { return (stored, cursors) }
        if stored != nil || !cursors.isEmpty { Log.info("persistence: aggregates schema changed, re-indexing the logs") }
        return (UsageAggregates(), [:])
    }

    func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = dir.appendingPathComponent(name + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.error("persistence: \(name).json unreadable, starting empty: \(error)")
            return nil
        }
    }

    /// Schedules `value` (evaluated at write time) to be saved as `<name>.json`.
    func save<T: Encodable & Sendable>(_ name: String, _ value: @escaping @MainActor () -> T) {
        let lane = Self.indexFiles.contains(name) ? index : standard
        lane.pending[name] = {
            let snapshot = value()
            return { try JSONEncoder().encode(snapshot) }
        }
        let due = lane.schedule.noteChange(at: Date())
        lane.timer?.invalidate()
        let t = Timer(fire: due, interval: 0, repeats: false) { [weak self, unowned lane] _ in
            MainActor.assumeIsolated { self?.write(lane, sync: false) }
        }
        t.tolerance = max(lane.schedule.policy.debounce * 0.25, 0.5)
        RunLoop.main.add(t, forMode: .common)
        lane.timer = t
    }

    func flush() {
        write(standard, sync: true)
        write(index, sync: true)
    }

    private func write(_ lane: Lane, sync: Bool) {
        lane.timer?.invalidate()
        lane.timer = nil
        lane.schedule.reset()
        guard !lane.pending.isEmpty else { return }
        let files = SaveSchedule.writeOrder(Array(lane.pending.keys)).map {
            (dir.appendingPathComponent($0 + ".json"), lane.pending[$0]!())
        }
        lane.pending.removeAll()
        let work: @Sendable () -> Void = {
            for (url, encode) in files {
                do {
                    try encode().write(to: url, options: [.atomic])
                } catch {
                    Log.error("persistence: \(url.lastPathComponent): \(error)")
                }
            }
            // Encoding megabytes of JSON leaves freed pages behind; give them back instead of keeping them dirty.
            malloc_zone_pressure_relief(nil, 0)
        }
        if sync { queue.sync(execute: work) } else { queue.async(execute: work) }
    }
}

extension UserDefaults {
    /// The `io.github.coru29.Mate` suite. Inside the app bundle that is the app's own domain (`.standard`); a suite
    /// named after the running bundle id is refused by Foundation. `MATE_DEFAULTS_SUITE` points test runs at a
    /// scratch suite, so they never read or write the user's real preferences.
    static let mate: UserDefaults = {
        let name = ProcessInfo.processInfo.environment["MATE_DEFAULTS_SUITE"].flatMap { $0.isEmpty ? nil : $0 }
            ?? Preferences.suiteName
        return Bundle.main.bundleIdentifier == name ? .standard : UserDefaults(suiteName: name) ?? .standard
    }()
}
