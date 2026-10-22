import AppKit
import SwiftUI

/// The usage window. Created on open and released on close: nothing is retained while it is closed.
@MainActor
final class UsageWindowController: NSObject, NSWindowDelegate {
    static let shared = UsageWindowController()
    static let size = NSSize(width: 720, height: 520)

    /// Set once at launch.
    var store: UsageStore?
    private var window: NSWindow?

    /// The window number while open (for `--snapshot`).
    var debugWindowNumber: Int? { window?.windowNumber }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let store else { return }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = String(localized: "Uso")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: UsageView(store: store))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window?.delegate = nil
        window = nil
    }
}
