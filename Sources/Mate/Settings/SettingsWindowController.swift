import AppKit
import SwiftUI

/// Owns the settings window. Created on open and released on close, so a closed window costs no memory.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// Set once at launch.
    var backend: SettingsBackend?
    private var window: NSWindow?
    private var navigation: SettingsNavigation?

    /// The window number while open (for `--snapshot-settings`).
    var debugWindowNumber: Int? { window?.windowNumber }

    /// Opens the window (or brings the open one forward), optionally at `section`.
    func show(section: SettingsSection? = nil) {
        guard let backend else { return }
        if let window {
            if let section { navigation?.selection = section }
            AppWindows.present(window)
            return
        }
        let nav = SettingsNavigation(selection: section ?? .general)
        let size = SettingsRoot.minimumSize
        let hosting = NSHostingView(rootView: SettingsRoot(backend: backend, store: backend.store, navigation: nav))
        // A plain title bar: bridged, the split view adds a sidebar toggle the window has no use for.
        hosting.sceneBridgingOptions = []
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = String(localized: "Configuración de Mate")
        w.contentView = hosting
        w.contentMinSize = size
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.collectionBehavior = [.moveToActiveSpace]
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("MateSettings")
        window = w
        navigation = nav
        AppWindows.present(w)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        closing.delegate = nil
        window = nil
        navigation = nil
        // The window is still on its way out of this call: release its content on the next turn.
        DispatchQueue.main.async { closing.contentView = nil }
    }
}

/// The selected page, settable from outside (`show(section:)`).
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsSection?

    init(selection: SettingsSection) { self.selection = selection }
}
