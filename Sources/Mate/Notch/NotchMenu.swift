import AppKit

/// The right-click menu on the notch, the pill or the panel.
extension NotchController {
    func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(String(localized: "Uso…")) { [weak self] in self?.onOpenUsage() })
        menu.addItem(ClosureMenuItem(String(localized: "Configuración…")) { [weak self] in self?.onOpenSettings() })
        if let update = Updater.shared.available {
            let version = update.version.description
            menu.addItem(ClosureMenuItem(String(localized: "Actualizar a Mate \(version)…")) { Updater.shared.offerInstall() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Actualizar ahora")) { [weak self] in self?.store.refreshNow() })
        let paused = store.isPaused
        menu.addItem(ClosureMenuItem(paused ? String(localized: "Reanudar") : String(localized: "Pausar")) { [weak self] in
            self?.store.setPaused(!paused)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Salir de Mate")) { NSApp.terminate(nil) })
        // Synchronous: returns when the menu closes.
        menuWillOpen()
        NSMenu.popUpContextMenu(menu, with: event, for: root)
        menuDidClose()
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
