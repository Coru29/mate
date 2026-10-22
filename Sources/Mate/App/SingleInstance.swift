import AppKit

/// Only one Mate runs per data folder: a second copy (the login item plus a manual open, or two builds) would draw a
/// second notch on top of the first and share its files and keychain items. The first instance holds an exclusive
/// `flock` on `.lock` in the data folder for its whole life (the system drops it if the process dies); a later one
/// asks it, through a distributed notification, to open Configuración, and exits. Debug runs (`--fake`, the
/// one-shot command-line modes, snapshots) never take part.
@MainActor
enum SingleInstance {
    static let openSettings = Notification.Name("io.github.coru29.Mate.openSettings")
    private static var lockFD: Int32 = -1
    /// The notification's object: only the instance on the same data folder answers (a test copy on a scratch
    /// folder never pops the real Mate's settings).
    private static var channel: String { Persistence.defaultDir(fake: false).standardizedFileURL.path }

    /// True when this process now holds the lock (or the lock file can't be opened at all, which must not stop Mate).
    static func acquire(dataDir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        // O_CLOEXEC: the updater's relaunch helper must not inherit the lock, or the new copy would hand off to it.
        let fd = open(dataDir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }

    /// Asks the running instance to show Configuración and exits.
    static func handOffAndExit() -> Never {
        DistributedNotificationCenter.default().postNotificationName(openSettings, object: channel, userInfo: nil,
                                                                     deliverImmediately: true)
        Log.info("another Mate is running; asked it to open Configuración")
        exit(0)
    }

    /// Runs `handler` on the main queue whenever a second copy on the same data folder hands off.
    static func observe(_ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: openSettings, object: channel, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
