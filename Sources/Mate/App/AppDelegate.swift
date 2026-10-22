import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: UsageStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = DebugCLI.makeStore()
        store.onAlert = { event in
            Log.info("alert \(event.kind) \(event.accountID) \(event.window.key) \(Int(event.percent)) %")
        }
        store.start()
        self.store = store
        Log.info("Mate started\(DebugCLI.isFake ? " (fake)" : "")")
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.flush()
    }
}
