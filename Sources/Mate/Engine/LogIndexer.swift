import Foundation
import MateCore

/// Parses agent logs off the main thread. Owns the file cursors (confined to its serial queue) and hands new
/// events, with a copy of the cursors, back to the main actor about every 8 MB of log read (and at the end), so
/// memory stays bounded while the first launch indexes the whole history.
final class LogIndexer: @unchecked Sendable {
    private static let deliverEvery = UInt64(IncrementalReader.defaultChunk)
    private let queue = DispatchQueue(label: "io.github.coru29.Mate.logs")
    private var cursors: [String: FileCursor]

    init(cursors: [String: FileCursor]) {
        self.cursors = cursors
    }

    /// True when no log was ever indexed (first launch): the full scan then runs at background QoS.
    var isFirstRun: Bool { queue.sync { cursors.isEmpty } }

    /// Reads what is new in `paths` (files or directories). `fullScan` also forgets cursors of files under the
    /// provider's log directories that no longer exist.
    func index(_ provider: any Provider, paths: [String], fullScan: Bool, qos: DispatchQoS.QoSClass,
               deliver: @escaping @MainActor ([TokenEvent], [String: FileCursor]) -> Void,
               done: (@MainActor () -> Void)? = nil) {
        queue.async(qos: DispatchQoS(qosClass: qos, relativePriority: 0), flags: .enforceQoS) { [self] in
            let files = provider.logFiles(in: paths)
            if fullScan {
                let roots = provider.watchedPaths
                let present = Set(files)
                for key in cursors.keys where !present.contains(key) && roots.contains(where: { key.hasPrefix($0 + "/") }) {
                    cursors[key] = nil
                }
            }
            var events: [TokenEvent] = []
            var bytes: UInt64 = 0
            func flush() {
                let batch = events, snapshot = cursors
                events = []
                bytes = 0
                DispatchQueue.main.async { MainActor.assumeIsolated { deliver(batch, snapshot) } }
            }
            for file in files {
                var more = true
                while more {
                    autoreleasepool {
                        let before = cursors[file]?.offset ?? 0
                        let r = provider.logEvents(changedPaths: [file], cursors: &cursors)
                        events += r.events
                        more = r.more
                        let after = cursors[file]?.offset ?? before
                        bytes += after > before ? after - before : after
                    }
                    if bytes >= Self.deliverEvery { flush() }
                }
            }
            flush()
            if let done { DispatchQueue.main.async { MainActor.assumeIsolated { done() } } }
        }
    }
}
