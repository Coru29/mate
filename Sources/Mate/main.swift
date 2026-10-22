import AppKit

MainActor.assumeIsolated {
    if DebugCLI.isIndex { DebugCLI.index() }
    if let day = DebugCLI.dumpDay { DebugCLI.dumpDay(day) }
    if DebugCLI.isDump {
        Task { await DebugCLI.dump() }
        dispatchMain()
    }
    if let (provider, path) = DebugCLI.addConfigDir {
        Task { await DebugCLI.addConfigDir(provider, path: path) }
        dispatchMain()
    }
    if let provider = DebugCLI.addAccountProvider {
        // The sign-in window needs a running app, but not the notch.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { await DebugCLI.addAccount(provider) }
        app.run()
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
