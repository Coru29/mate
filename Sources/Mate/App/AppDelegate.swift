import AppKit
import MateCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: UsageStore?
    private var notch: NotchController?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = DebugCLI.makeStore()
        let notch = NotchController(store: store)
        UsageWindowController.shared.store = store
        notch.onOpenUsage = { UsageWindowController.shared.show() }
        // Settings arrives in a later task.
        notch.onOpenSettings = { Log.info("open settings") }
        store.onAlert = { [weak notch] event in
            Log.info("alert \(event.kind) \(event.accountID) \(event.window.key) \(Int(event.percent)) %")
            notch?.presentAlert(event)
        }
        store.start()
        notch.show()
        self.store = store
        self.notch = notch
        DebugCLI.scheduleUIChecks(notch: notch, store: store)
        Log.info("Mate started\(DebugCLI.isFake ? " (fake)" : "")")
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { store?.flush() }
    }
}
