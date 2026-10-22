import AppKit
import SwiftUI
import MateCore

/// The steps of the welcome guide, in order.
enum WelcomePage: Int, CaseIterable {
    case welcome, agents, keychain, launch
}

/// What the guide shows: the step, and the agents found on this Mac. Detection reads session files and keychain
/// attributes only; the agents' credentials are read (and macOS shows its keychain prompt) only once the user
/// moves past the keychain step, through `startReading`.
@MainActor
final class WelcomeModel: ObservableObject {
    @Published private(set) var page: WelcomePage = .welcome
    /// nil while looking.
    @Published private(set) var detected: [ProviderID: [ObservedSession]]?
    let backend: SettingsBackend
    var startReading: () -> Void = {}
    var finish: () -> Void = {}
    private(set) var finished = false

    init(backend: SettingsBackend) {
        self.backend = backend
        Task { [weak self] in
            guard let self else { return }
            let found = await backend.store.detectSessions()
            self.detected = found
        }
    }

    var isFirst: Bool { page == .welcome }
    var isLast: Bool { page == .launch }

    /// The forward button and ⏎: the next step; leaving the keychain step starts reading the agents' sessions.
    func advance() {
        if page == .keychain { startReading() }
        if isLast {
            finished = true
            finish()
        } else if let next = WelcomePage(rawValue: page.rawValue + 1) {
            page = next
        }
    }

    func back() {
        if let previous = WelcomePage(rawValue: page.rawValue - 1) { page = previous }
    }

    /// `--snapshot-welcome`.
    func debugGo(to page: WelcomePage) { self.page = page }
}

/// The welcome guide, shown on the first launch (`hasOnboarded`). Created on open, released on close. Closing it
/// part way still starts Mate and counts as seen.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    private var window: WelcomeWindow?
    private(set) var model: WelcomeModel?
    private var onStart: () -> Void = {}
    private var onFinish: () -> Void = {}

    var isOpen: Bool { window != nil }
    var debugWindowNumber: Int? { window?.windowNumber }

    static var hasOnboarded: Bool { UserDefaults.mate.bool(forKey: PrefKey.hasOnboarded.rawValue) }

    /// `onStart` begins reading the agents' sessions (it may run before the window closes); `onFinish` runs after the
    /// window closed through the last step's button.
    func show(backend: SettingsBackend, onStart: @escaping () -> Void, onFinish: @escaping () -> Void) {
        if let window {
            AppWindows.present(window)
            return
        }
        self.onStart = onStart
        self.onFinish = onFinish
        let model = WelcomeModel(backend: backend)
        model.startReading = { onStart() }
        let w = WelcomeWindow(contentRect: NSRect(origin: .zero, size: WelcomeView.size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = String(localized: "Bienvenida a Mate")
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.moveToActiveSpace]
        w.contentView = NSHostingView(rootView: WelcomeView(model: model))
        w.onReturn = { [weak model] in model?.advance() }
        model.finish = { [weak w] in w?.close() }
        w.delegate = self
        w.center()
        window = w
        self.model = model
        AppWindows.present(w)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        UserDefaults.mate.set(true, forKey: PrefKey.hasOnboarded.rawValue)
        let finished = model?.finished ?? false
        closing.delegate = nil
        window = nil
        model = nil
        onStart()
        let done = onFinish
        onStart = {}
        onFinish = {}
        DispatchQueue.main.async {
            closing.contentView = nil
            if finished { done() }
        }
    }
}

/// ⏎ goes to the next step, ⎋ and ⌘W close, when no control in the window wants the key.
final class WelcomeWindow: NSWindow {
    var onReturn: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.type == .keyDown, !event.isARepeat else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return false
    }
}
