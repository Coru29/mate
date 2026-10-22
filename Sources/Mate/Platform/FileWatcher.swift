import Foundation
import CoreServices

/// One FSEvents stream over every watched path (directories are watched recursively, a file path is watched on its
/// own). Events are coalesced by `latency` and delivered on a utility queue as the list of changed paths.
final class FileWatcher {
    private let latency: TimeInterval
    private let onChange: ([String]) -> Void
    private let queue = DispatchQueue(label: "io.github.coru29.Mate.fsevents", qos: .utility)
    private var paths: [String]
    private var stream: FSEventStreamRef?

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
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let all = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let changed = Array(all.prefix(count))
            if !changed.isEmpty { watcher.onChange(changed) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            Log.error("FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
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
}
