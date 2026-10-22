import AppKit
import MateCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: UsageStore?
    private var notch: NotchController?
    private var backend: SettingsBackend?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = DebugCLI.makeStore()
        let notch = NotchController(store: store)
        let backend = SettingsBackend(store: store, fake: DebugCLI.isFake)
        UsageWindowController.shared.store = store
        SettingsWindowController.shared.backend = backend
        notch.onOpenUsage = { UsageWindowController.shared.show() }
        notch.onOpenSettings = { SettingsWindowController.shared.show() }
        store.onAlert = { [weak notch] event in
            Log.info("alert \(event.kind) \(event.accountID) \(event.window.key) \(Int(event.percent)) %")
            notch?.presentAlert(event)
        }
        self.store = store
        self.notch = notch
        self.backend = backend
        notch.show()
        if WelcomeWindowController.hasOnboarded && !DebugCLI.forceWelcome {
            store.start()
        } else {
            // The agents' sessions (and macOS's keychain prompt) wait until the guide has explained the prompt.
            WelcomeWindowController.shared.show(backend: backend, onStart: { store.start() }, onFinish: { [weak notch] in
                notch?.openPanel(hint: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { notch?.closePanelUnlessHovered() }
            })
        }
        DebugCLI.scheduleUIChecks(notch: notch, store: store)
        Log.info("Mate started\(DebugCLI.isFake ? " (fake)" : "")")
    }

    /// Opening Mate again (Finder, Spotlight, Aplicaciones) opens Configuración, or brings the welcome guide forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            Log.info("reopen")
            if WelcomeWindowController.shared.isOpen, let backend {
                WelcomeWindowController.shared.show(backend: backend, onStart: {}, onFinish: {})
            } else {
                SettingsWindowController.shared.show()
            }
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { store?.flush() }
    }
}
