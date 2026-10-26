import AppKit
import ApplicationServices
import MateCore

/// Where the menu bar's menus end on the notch's screen, for `MenuBarAvoid` (with "Esquivar los menús de la barra"
/// on; on a real notch it decides only whether the mate's ear fits). The app's menus come from Accessibility (the frontmost
/// app's menu bar items; nothing else is read or controlled), the status items from the window list (no permission).
/// Event-driven: app activation, space and screen changes, and the frontmost app's window changes (an `AXObserver`)
/// each schedule one coalesced read; nothing runs while inactive.
@MainActor
final class MenuBarWatcher: ObservableObject {
    static let shared = MenuBarWatcher()

    /// Mate may use Accessibility (`AXIsProcessTrusted`, which never prompts).
    @Published private(set) var trusted = AXIsProcessTrusted()
    /// The notch is on a display without a real notch and the option is on.
    @Published private(set) var active = false
    /// What the menu bar holds, in Cocoa x; nil when not known (no permission yet, or a read failed).
    private(set) var extents: MenuBarAvoid.Extents?
    /// The extents changed.
    var onChange: () -> Void = {}

    /// The panel asks for the permission.
    var needsPermission: Bool { active && !trusted && DebugCLI.fakeMenuBar == nil }

    private var screenID: UInt32?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var axObserver: AXObserver?
    private var observedPID: pid_t?
    private var readTimer: Timer?
    private var trustTimer: Timer?
    private let queue = DispatchQueue(label: "io.github.coru29.Mate.menubar", qos: .utility)
    private var readID = 0

    private static let coalesce: TimeInterval = 0.25
    /// The trust flag lags the distributed notification a little.
    private static let trustLag: TimeInterval = 0.5
    /// A hung app cannot stall a read longer than this per call.
    private nonisolated static let messagingTimeout: Float = 0.5

    // MARK: Lifecycle

    /// The notch's screen and whether avoiding applies there; the controller calls it on every layout and option
    /// change. Starts or stops the observers and schedules a read.
    func update(screen: ScreenInfo?) {
        let on = NotchPrefs.avoidMenuBar && screen != nil
        let screenChanged = screen?.id != screenID
        screenID = screen?.id
        if on != active {
            active = on
            on ? startObserving() : stopObserving()
            if !on, extents != nil {
                extents = nil
                onChange()
            }
        }
        if on, screenChanged || extents == nil { scheduleRead() }
    }

    private func startObserving() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { w in
            w.recheckTrust()
            w.observeFrontmostApp()
            w.scheduleRead()
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.scheduleRead() }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.scheduleRead() }
        // Posted when any app's Accessibility permission changes.
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.accessibility.api")) { w in
            w.trustTimer?.invalidate()
            w.trustTimer = w.oneShot(Self.trustLag) { [weak w] in
                w?.trustTimer = nil
                w?.recheckTrust()
            }
        }
        recheckTrust()
        observeFrontmostApp()
    }

    private func stopObserving() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        removeAXObserver()
        readTimer?.invalidate()
        readTimer = nil
        trustTimer?.invalidate()
        trustTimer = nil
        readID += 1
    }

    /// Re-reads the permission (the panel opening, app activation, the distributed notification).
    func recheckTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        trusted = now
        Log.info("menu bar: accessibility \(now ? "granted" : "not granted")")
        if active {
            observeFrontmostApp()
            scheduleRead()
        }
    }

    /// "Permitir": macOS's own Accessibility prompt, and the pane in System Settings.
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: The frontmost app

    /// Follows the frontmost app's window changes (its menus can change per window).
    private func observeFrontmostApp() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard trusted, let pid, pid != getpid() else {
            removeAXObserver()
            return
        }
        guard pid != observedPID else { return }
        removeAXObserver()
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<MenuBarWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.scheduleRead() }
        }, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        observedPID = pid
    }

    private func removeAXObserver() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        observedPID = nil
    }

    // MARK: Reading

    /// One read a moment after a burst of events.
    func scheduleRead() {
        guard active else { return }
        readTimer?.invalidate()
        readTimer = oneShot(Self.coalesce) { [weak self] in
            self?.readTimer = nil
            self?.read()
        }
    }

    private func read() {
        guard active, let id = screenID else { return }
        if let fake = DebugCLI.fakeMenuBar {
            // Set once; `--snapshot-menubar` changes it from there.
            let minX = CGDisplayBounds(id).minX
            if extents == nil { set(MenuBarAvoid.Extents(appMaxX: minX + fake.app, statusMinX: minX + fake.status)) }
            return
        }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Mate's own menus (Configuración in front): keep what was read for the app before it.
        if pid == getpid() { return }
        let trusted = self.trusted
        readID += 1
        let token = readID
        queue.async {
            let result = Self.readExtents(display: id, pid: trusted ? pid : nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let w = MenuBarWatcher.shared
                    guard token == w.readID, w.active else { return }
                    w.set(result)
                }
            }
        }
    }

    private func set(_ new: MenuBarAvoid.Extents?) {
        guard new != extents else { return }
        extents = new
        Log.info("menu bar: \(new.map { "app menus end \(Int($0.appMaxX)), status items start \(Int($0.statusMinX))" } ?? "unknown")")
        onChange()
    }

    /// Both ends on `display`, or nil when the app's menus could not be read (`pid` nil: no permission).
    nonisolated static func readExtents(display: UInt32, pid: pid_t?) -> MenuBarAvoid.Extents? {
        guard let pid, let items = appMenuItems(pid: pid), let windows = statusWindows() else { return nil }
        let screen = CGDisplayBounds(display)
        let screens = displays()
        guard let app = MenuBarAvoid.appMaxX(items: items, screen: screen, screens: screens) else { return nil }
        return MenuBarAvoid.Extents(appMaxX: app,
                                    statusMinX: MenuBarAvoid.statusMinX(windows: windows, screen: screen, screens: screens))
    }

    /// Every active display's bounds, in window-server coordinates.
    nonisolated static func displays() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// The frontmost app's menu bar items (Accessibility): their rects, in window-server coordinates. Nil when the
    /// app does not answer (no permission, a timeout, no menu bar).
    nonisolated static func appMenuItems(pid: pid_t) -> [CGRect]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let bar = element(app, kAXMenuBarAttribute) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var rects: [CGRect] = []
        for child in children {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(child, attributes, [], &values) == .success,
                  let pair = values as? [AnyObject], pair.count == 2 else { return nil }
            var origin = CGPoint.zero, size = CGSize.zero
            guard CFGetTypeID(pair[0]) == AXValueGetTypeID(), CFGetTypeID(pair[1]) == AXValueGetTypeID(),
                  AXValueGetValue(pair[0] as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(pair[1] as! AXValue, .cgSize, &size) else { continue }
            rects.append(CGRect(origin: origin, size: size))
        }
        return rects
    }

    private nonisolated static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The status items and menu extras: windows on the status-item layer, other than Mate's own, in window-server
    /// coordinates. Nil when the window list cannot be read.
    nonisolated static func statusWindows() -> [CGRect]? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let layer = Int(CGWindowLevelForKey(.statusWindow))
        let own = Int(getpid())
        return list.compactMap { w in
            guard w[kCGWindowLayer as String] as? Int == layer, w[kCGWindowOwnerPID as String] as? Int != own,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.height < 60 else { return nil }
            return rect
        }
    }

    /// `--snapshot-menubar`: other extents, in points from the screen's left edge.
    func debugSet(app: CGFloat, status: CGFloat) {
        guard active, let id = screenID else { return }
        let minX = CGDisplayBounds(id).minX
        set(MenuBarAvoid.Extents(appMaxX: minX + app, statusMinX: minX + status))
    }

    // MARK: --dump

    /// `menu bar: fake=… permission=… app-menus=… status-items=… placement=…` for the screen Mate would use.
    static func dumpLine() -> String {
        let screens = NSScreen.screens
        let mouseID = screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?.displayID
        guard let info = NotchLayout.pickScreen(screens.map { DebugCLI.notchScreen($0.info) },
                                                choice: NotchPrefs.screenChoice, mouseScreen: mouseID) else { return "menu bar: no screen" }
        let (notch, fake) = NotchLayout.notchRect(on: info)
        let trusted = AXIsProcessTrusted()
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let extents: MenuBarAvoid.Extents?
        if let f = DebugCLI.fakeMenuBar {
            extents = .init(appMaxX: info.frame.minX + f.app, statusMinX: info.frame.minX + f.status)
        } else {
            extents = readExtents(display: info.id, pid: trusted && pid != getpid() ? pid : nil)
        }
        let status = DebugCLI.fakeMenuBar != nil ? extents?.statusMinX : statusWindows().map {
            MenuBarAvoid.statusMinX(windows: $0, screen: CGDisplayBounds(info.id), screens: displays())
        }
        var placement = "centered (as today)"
        // The mate's ear with the pill shown and with it hidden.
        func side(_ p: MenuBarAvoid.Placement) -> String {
            switch p.ear {
            case .left: "left"
            case .right: "right"
            case .hidden: "dropped"
            }
        }
        if !fake, NotchPrefs.avoidMenuBar, let extents {
            let ear = NotchLayout.mateEarWidth
            let withPill = MenuBarAvoid.placeOnRealNotch(notch: notch, leftEar: ear, pill: true, extents: extents)
            let alone = MenuBarAvoid.placeOnRealNotch(notch: notch, leftEar: ear, pill: false, extents: extents)
            placement = "real notch, mate ear \(side(withPill)) with the pill, \(side(alone)) without it"
        } else if fake, NotchPrefs.avoidMenuBar, let extents {
            let ear = NotchLayout.mateEarWidth
            let withPill = MenuBarAvoid.place(notch: notch, leftEar: ear, rightEar: 56, extents: extents,
                                              screen: info.frame)
            let alone = MenuBarAvoid.place(notch: notch, leftEar: ear, rightEar: nil, extents: extents,
                                           screen: info.frame)
            placement = "with the pill: shift \(Int(withPill.shift)) mate ear \(side(withPill));"
                + " without it: shift \(Int(alone.shift)) mate ear \(side(alone))"
        }
        return "menu bar: display=\(info.id) fake-notch=\(fake ? "yes" : "no")  option=\(NotchPrefs.avoidMenuBar ? "on" : "off")"
            + "  permission=\(trusted ? "granted" : "not granted")"
            + "  app-menus-end=\(extents.map { "\(Int($0.appMaxX))" } ?? "unknown")"
            + "  status-items-start=\(status.map { "\(Int($0))" } ?? "unknown")"
            + "  placement=\(placement)"
    }

    // MARK: Helpers

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping (MenuBarWatcher) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
        observers.append((center, token))
    }

    private func oneShot(_ interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: false) { _ in MainActor.assumeIsolated { block() } }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}
