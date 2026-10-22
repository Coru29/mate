import Foundation
import MateCore

/// Parses agent logs off the main thread. Owns the file cursors (confined to its serial queue) and hands each
/// batch of new events, with a copy of the cursors, back to the main actor.
final class LogIndexer: @unchecked Sendable {
    private static let batchSize = 25
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
               deliver: @escaping @MainActor ([TokenEvent], [String: FileCursor]) -> Void) {
        queue.async(qos: DispatchQoS(qosClass: qos, relativePriority: 0), flags: .enforceQoS) { [self] in
            let files = provider.logFiles(in: paths)
            if fullScan {
                let roots = provider.watchedPaths
                let present = Set(files)
                for key in cursors.keys where !present.contains(key) && roots.contains(where: { key.hasPrefix($0 + "/") }) {
                    cursors[key] = nil
                }
            }
            var start = 0
            repeat {
                let batch = Array(files[start..<min(start + Self.batchSize, files.count)])
                let events = provider.logEvents(changedPaths: batch, cursors: &cursors)
                let snapshot = cursors
                DispatchQueue.main.async { MainActor.assumeIsolated { deliver(events, snapshot) } }
                start += Self.batchSize
            } while start < files.count
        }
    }
}
