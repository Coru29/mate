import AppKit

MainActor.assumeIsolated {
    if DebugCLI.isDump {
        Task { await DebugCLI.dump() }
        dispatchMain()
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
