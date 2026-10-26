import AppKit
import MateCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: UsageStore?
    private var notch: NotchController?
    private var backend: SettingsBackend?
    private var updatesObserver: NSObjectProtocol?
    private var handOffObserver: NSObjectProtocol?
    /// SIGTERM (`kill <pid>`, `scripts/install.sh`) quits like the menu does, so the store is saved.
    private var termSource: DispatchSourceSignal?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term
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
        KeepAwake.shared.start(store: store)
        // Real players only in a normal run; `--fake` gets the scripted one, and a headless run without it (the
        // single-instance checks) touches no player at all.
        if DebugCLI.isFake {
            NowPlayingCenter.shared.start(fake: FakePlayerBridge.fromArguments)
        } else if !DebugCLI.isHeadless {
            NowPlayingCenter.shared.start(fake: nil)
        }
        if DebugCLI.isHeadless {
            // Test runs: no notch, no guide, no window of any kind on the user's screen; only `--fake` fetches.
            store.onAlert = { event in Log.info("alert \(event.kind) \(event.accountID) (headless)") }
            if DebugCLI.isFake { store.start() }
            if DebugCLI.isDebugUpdate { configureUpdates() }
            if !DebugCLI.isFake { handOffObserver = SingleInstance.observe { Log.info("reopen (headless)") } }
            Log.info("Mate started headless\(DebugCLI.isFake ? " (fake)" : "")")
            return
        }
        notch.show()
        if (WelcomeWindowController.hasOnboarded || DebugCLI.isInvisible) && !DebugCLI.forceWelcome {
            store.start()
        } else {
            // The agents' sessions (and macOS's keychain prompt) wait until the guide has explained the prompt.
            WelcomeWindowController.shared.show(backend: backend, onStart: { store.start() }, onFinish: { [weak notch] in
                notch?.openPanel(hint: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { notch?.closePanelUnlessHovered() }
            })
        }
        DebugCLI.scheduleUIChecks(notch: notch, store: store)
        Updater.shared.onFound = { [weak notch] release in notch?.presentUpdate(release.version.description) }
        configureUpdates()
        if !DebugCLI.isFake {
            handOffObserver = SingleInstance.observe { [weak self] in self?.reopen() }
        }
        Log.info("Mate started\(DebugCLI.isFake ? " (fake)" : "")")
    }

    /// The daily update check follows Configuración → Actualizaciones. `--fake` runs never reach GitHub; with a
    /// test feed, `--debug-update` installs from it.
    @MainActor
    private func configureUpdates() {
        if DebugCLI.isDebugUpdate {
            Task { await Updater.shared.installForTesting() }
            return
        }
        guard !DebugCLI.isFake else { return }
        let apply = {
            let on = UserDefaults.mate.object(forKey: PrefKey.checkUpdates.rawValue) as? Bool ?? true
            Updater.shared.configure(automatic: on)
        }
        apply()
        updatesObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                 object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply() }
        }
    }

    /// Opening Mate again (Finder, Spotlight, Aplicaciones) opens Configuración, or brings the welcome guide forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { reopen() }
        return false
    }

    /// Opening Mate again, or a second copy that handed off (`SingleInstance`).
    @MainActor
    private func reopen() {
        Log.info("reopen")
        guard !DebugCLI.isHeadless else { return }
        if WelcomeWindowController.shared.isOpen, let backend {
            WelcomeWindowController.shared.show(backend: backend, onStart: {}, onFinish: {})
        } else {
            SettingsWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            KeepAwake.shared.stop()
            NowPlayingCenter.shared.stop()
            store?.flush()
        }
    }
}
