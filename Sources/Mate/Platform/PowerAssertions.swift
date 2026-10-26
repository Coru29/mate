import AppKit
import Darwin
import Foundation
import IOKit.pwr_mgt
import MateCore
import notify

/// IOKit power assertions: Mate's own "prevent idle system sleep" (the display may still sleep), and who else holds
/// keep-awake assertions. Never spawns `caffeinate`.
enum PowerAssertions {
    /// Creates Mate's assertion; nil if IOKit refused.
    static func preventIdleSleep() -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 KeepAwakePolicy.assertionName as CFString, &id)
        guard result == kIOReturnSuccess else {
            Log.error("keep awake: IOPMAssertionCreateWithName failed (\(result))")
            return nil
        }
        return id
    }

    static func release(_ id: IOPMAssertionID) {
        let result = IOPMAssertionRelease(id)
        if result != kIOReturnSuccess { Log.error("keep awake: IOPMAssertionRelease failed (\(result))") }
    }

    /// Every process holding assertions, with its executable path and its parent's name.
    static func processes() -> [AssertingProcess] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byPID = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return byPID.keys.sorted { $0.int32Value < $1.int32Value }.map { key in
            let pid = key.int32Value
            let list = byPID[key] ?? []
            let assertions = list.map { a in
                AssertingProcess.Assertion(type: a[kIOPMAssertionTypeKey] as? String ?? "",
                                           name: a[kIOPMAssertionNameKey] as? String ?? "",
                                           level: (a[kIOPMAssertionLevelKey] as? NSNumber)?.intValue ?? 255)
            }
            let reported = list.first?["Process Name"] as? String
            return AssertingProcess(pid: pid, name: displayName(pid) ?? reported ?? "pid \(pid)", path: path(pid),
                                    parentName: parent(pid).flatMap(name), assertions: assertions)
        }
    }

    /// Whether some process holds Mate's own assertion (for `--dump`, which runs as a second process).
    static func mateHolds(in processes: [AssertingProcess]) -> Bool {
        processes.contains { p in p.assertions.contains { $0.name == KeepAwakePolicy.assertionName && $0.level != 0 } }
    }

    /// powerd posts these through notifyd: any assertion created, changed or released, and a change of the
    /// system-wide level of an assertion type. On macOS 26 powerd posts the first only to processes that asked for
    /// it with `IOPMAssertionNotify` (private but exported; looked up at run time, so a missing symbol only leaves the
    /// second); without that call neither name fired on this Mac (checked with a `caffeinate -i` child).
    static let anyChangeNotification = "com.apple.system.powermanagement.assertions.anychange"
    static let levelChangeNotification = "com.apple.system.powermanagement.assertions"

    private typealias AssertionNotify = @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
    private static let assertionNotify: AssertionNotify? = {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let sym = dlsym(iokit, "IOPMAssertionNotify") else { return nil }
        return unsafeBitCast(sym, to: AssertionNotify.self)
    }()
    /// kIOPMNotifyRegister / kIOPMNotifyDeRegister.
    private static let notifyRegister: Int32 = 1, notifyDeregister: Int32 = 2

    /// Calls `handler` on the main queue whenever some process's assertions change (bursts included: coalesce).
    /// Returns the notify tokens for `stopObserving`.
    static func observeChanges(_ handler: @escaping () -> Void) -> [Int32] {
        var tokens: [Int32] = []
        for name in [anyChangeNotification, levelChangeNotification] {
            if let register = assertionNotify {
                let result = register(name, notifyRegister)
                if result != 0 { Log.error("keep awake: IOPMAssertionNotify(\(name)) failed (\(result))") }
            }
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, .main) { _ in handler() }
            if status == NOTIFY_STATUS_OK { tokens.append(token) } else { Log.error("keep awake: notify \(name) failed (\(status))") }
        }
        return tokens
    }

    static func stopObserving(_ tokens: [Int32]) {
        for t in tokens { notify_cancel(t) }
        guard let register = assertionNotify, !tokens.isEmpty else { return }
        for name in [anyChangeNotification, levelChangeNotification] { _ = register(name, notifyDeregister) }
    }

    /// An app's name, else the executable's.
    private static func displayName(_ pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? name(pid)
    }

    private static func name(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    private static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    private static func parent(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
