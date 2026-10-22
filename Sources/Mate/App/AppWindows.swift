import AppKit

/// Mate's own titled windows (Configuración, the welcome guide). Mate stays an agent app with no Dock icon; the
/// main menu is installed (never shown in the menu bar) so ⌘W, ⌘Q and ⌘C / ⌘V in text fields work while one of
/// them is key.
@MainActor
enum AppWindows {
    /// Brings `window` to the front and activates Mate.
    static func present(_ window: NSWindow) {
        installMainMenuIfNeeded()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // If macOS declines to activate Mate, the window must still be seen.
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func installMainMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let mainMenu = NSMenu()

        let appMenu = submenu(titled: "Mate", in: mainMenu)
        appMenu.addItem(withTitle: String(localized: "Salir de Mate"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = submenu(titled: String(localized: "Archivo"), in: mainMenu)
        fileMenu.addItem(withTitle: String(localized: "Cerrar"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = submenu(titled: String(localized: "Edición"), in: mainMenu)
        editMenu.addItem(withTitle: String(localized: "Deshacer"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: String(localized: "Rehacer"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cortar"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copiar"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Pegar"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Seleccionar todo"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    private static func submenu(titled title: String, in menu: NSMenu) -> NSMenu {
        let item = NSMenuItem()
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        menu.addItem(item)
        return submenu
    }
}
