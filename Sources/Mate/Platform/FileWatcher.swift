import Foundation
import CoreServices

/// One FSEvents stream over every watched path (directories are watched recursively, a file path is watched on its
/// own). Events are coalesced by `latency` and delivered on a utility queue as the list of changed paths.
final class FileWatcher {
    private var latency: TimeInterval
    private let onChange: ([String]) -> Void
    private let queue = DispatchQueue(label: "io.github.coru29.Mate.fsevents", qos: .utility)
    private var paths: [String]
    private var stream: FSEventStreamRef?
    /// Where a restarted stream resumes, so nothing written while it restarts is missed.
    private var resumeFrom = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

    init(paths: [String], latency: TimeInterval = 1, onChange: @escaping ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let all = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            // A resumed stream ends its replay with a "history done" marker, which is no change.
            let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
            let changed = all.prefix(count).enumerated().filter { rawFlags[$0.offset] & historyDone == 0 }.map(\.element)
            if !changed.isEmpty { watcher.onChange(changed) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                          resumeFrom, latency, flags) else {
            Log.error("FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        stop(resuming: false)
    }

    private func stop(resuming: Bool) {
        guard let s = stream else { return }
        let last = FSEventStreamGetLatestEventId(s)
        resumeFrom = resuming && last != 0 ? last : FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    /// Replaces the watched paths, restarting the stream only when they changed.
    func setPaths(_ newPaths: [String]) {
        guard newPaths != paths else { return }
        let running = stream != nil
        stop()
        paths = newPaths
        if running { start() }
    }

    /// Changes the coalescing latency, restarting the stream from its last event (no change is lost).
    func setLatency(_ newLatency: TimeInterval) {
        guard newLatency != latency else { return }
        latency = newLatency
        guard stream != nil else { return }
        stop(resuming: true)
        start()
    }
}
