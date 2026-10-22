import AppKit
import Combine
import SwiftUI
import MateCore

/// The notch UI: one window whose frame always equals the visible black shape (plus the hover strip over the
/// notch). Closed it shows the pill; hovering opens the panel; alerts drop from the notch. Everything is driven by
/// events and one-shot timers; animations run only while the shape changes.
@MainActor
final class NotchController {
    static let panelWidth: CGFloat = 380
    private static let closedRadius: CGFloat = 10
    private static let openRadius: CGFloat = 18
    private static let openDelay: TimeInterval = 0.15
    private static let closeDelay: TimeInterval = 0.4
    private static let scrollThreshold: CGFloat = 24

    var onOpenUsage: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    private enum Mode { case closed, open, alert }

    let store: UsageStore
    private let window = NotchWindow()
    let root = NotchShapeView()
    private let pill = PillView()
    private let banner = AlertBanner()

    private var screenInfo: ScreenInfo?
    private var notch = CGRect.zero
    private var fakeNotch = false
    private var menuBarVisible = true
    private var pillShown = false

    private var mode = Mode.closed
    /// The shape is sliding back to its closed size; alerts wait for it.
    private var closing = false
    private var hovering = false
    /// The right-click menu is up: the mouse is on the menu, so leaving the shape must not close the panel.
    private var menuOpen = false
    /// Target of the black shape, in screen coordinates.
    private var shapeRect = CGRect.zero
    private var shapeRadius = closedRadius
    private var panelRect = CGRect.zero
    private var alertRect = CGRect.zero
    /// Bumped by every shape transition, so a superseded animation's completion does nothing.
    private var generation = 0

    private var hosting: PanelHostingView?
    private var alertView: NSView?
    private var openTimer: Timer?
    private var closeTimer: Timer?
    private var alertTimer: Timer?
    private var recheckTimer: Timer?
    private var monitors: [Any] = []
    private var scrollAccumulated: CGFloat = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var storeChanges: AnyCancellable?
    private var refreshQueued = false
    private var showAlways = NotchPrefs.showPillAlways
    private var screenChoice = NotchPrefs.screenChoice
    private var notifications = NotchPrefs.systemNotifications

    init(store: UsageStore) {
        self.store = store
    }

    // MARK: Public API

    func show() {
        window.contentView = root
        root.addSubview(pill)
        root.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        root.onClick = { [weak self] event in self?.clicked(event) }
        root.onRightClick = { [weak self] event in self?.showMenu(event) }

        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observe(center, NSApplication.didChangeScreenParametersNotification) { $0.layout() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.spaceChanged() }
        observe(center, UserDefaults.didChangeNotification) { $0.preferencesChanged() }
        storeChanges = store.objectWillChange.sink { [weak self] _ in self?.queueRefresh() }

        layout()
        window.orderFrontRegardless()
    }

    func presentAlert(_ e: AlertEvent) {
        guard let account = store.accounts.first(where: { $0.id == e.accountID }) else { return }
        let window = store.snapshots[e.accountID]?.windows.first { $0.kind == e.window }
        let pace = window.flatMap { store.pace(e.accountID, $0, now: Date()) }
        let text = NotchText.alert(e, title: "\(account.provider.displayName) · \(account.name)", pace: pace)
        let tone: Tone
        switch e.kind {
        case .reset: tone = .ok
        case .threshold(let n): tone = n >= 90 ? .hot : .warn
        }
        Log.info("alert: \(text)")
        if NotchPrefs.systemNotifications { AlertBanner.post(text) }
        banner.enqueue(AlertBanner.Item(text: text, tone: tone))
        if mode == .closed && !closing { showNextAlert() }
    }

    /// Opens the panel right away (hover after the delay, a click, an alert click, `--open-panel`).
    func openPanel() {
        guard mode != .open, let info = screenInfo else { return }
        cancel(&openTimer)
        cancel(&closeTimer)
        if mode == .alert { removeAlertView() }
        closing = false
        let host = PanelHostingView(rootView: makePanel())
        hosting = host
        panelRect = NotchLayout.panelRect(notch: notch, contentHeight: host.fittingSize.height, screen: info)
        host.alphaValue = 0
        root.addSubview(host, positioned: .below, relativeTo: pill)
        mode = .open
        transition(to: panelRect, radius: Self.openRadius)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            host.animator().alphaValue = 1
        }
        addMonitors()
        store.panelDidOpen()
        Log.info("panel opened")
    }

    /// The window's content view, for `--snapshot`.
    var debugView: NSView { root }

    /// `--open-panel`: close the panel it opened, unless the user is looking at it.
    func closePanelUnlessHovered() {
        if !hovering { closePanel() }
    }

    func closePanel() {
        guard mode == .open else { return }
        cancel(&closeTimer)
        removeMonitors()
        mode = .closed
        store.panelDidClose()
        Log.info("panel closed")
        if let host = hosting {
            hosting = nil
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                host.animator().alphaValue = 0
            }, completionHandler: { host.removeFromSuperview() })
        }
        slideClosed()
    }

    // MARK: Layout

    private func layout() {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        let mouseID = screens.first { NSMouseInRect(mouse, $0.frame, false) }?.displayID
        guard let info = NotchLayout.pickScreen(screens.map(\.info), choice: screenChoice, mouseScreen: mouseID),
              let screen = screens.first(where: { $0.displayID == info.id }) else {
            endWithoutAnimation()
            screenInfo = nil
            window.orderOut(nil)
            return
        }
        screenInfo = info
        (notch, fakeNotch) = NotchLayout.notchRect(on: info)
        menuBarVisible = screen.isMenuBarVisible
        endWithoutAnimation()
        updatePill()
        shapeRect = closedRect
        shapeRadius = Self.closedRadius
        setWindowFrame(stripRect)
        if !window.isVisible { window.orderFrontRegardless() }
        showNextAlert()
    }

    /// A screen change ends whatever was showing, without animation.
    private func endWithoutAnimation() {
        if mode == .open {
            removeMonitors()
            cancel(&closeTimer)
            hosting?.removeFromSuperview()
            hosting = nil
            store.panelDidClose()
        }
        if mode == .alert { removeAlertView() }
        mode = .closed
        closing = false
        generation += 1
    }

    private var pillRect: CGRect { NotchLayout.pillRect(notch: notch) }

    /// What the window covers when closed: the notch (hover opens the panel even with the pill hidden) and the pill.
    /// A fake notch with the menu bar hidden (another app in full screen) keeps only a 2 pt edge at the very top,
    /// so it takes no clicks from that app.
    private var stripRect: CGRect {
        if pillShown { return notch.union(pillRect) }
        if fakeNotch && !menuBarVisible { return CGRect(x: notch.minX, y: notch.maxY - 2, width: notch.width, height: 2) }
        return notch
    }

    /// The closed black shape. A real notch needs no drawing; a fake one is drawn while the menu bar shows.
    private var closedRect: CGRect {
        if pillShown { return stripRect }
        if fakeNotch && menuBarVisible { return notch }
        return CGRect(x: notch.minX, y: notch.maxY, width: notch.width, height: 0)
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }

    /// Moves the window and re-places everything in it (the shape without animation).
    private func setWindowFrame(_ frame: CGRect) {
        window.setFrame(frame.integral, display: false)
        root.frame = CGRect(origin: .zero, size: window.frame.size)
        pill.frame = local(pillRect)
        pill.isHidden = !pillShown
        hosting?.frame = local(panelRect)
        alertView?.frame = local(CGRect(x: alertRect.minX, y: alertRect.minY, width: alertRect.width,
                                        height: AlertBanner.lineHeight))
        root.setShape(NotchShapeView.path(local(shapeRect), radius: shapeRadius), animated: false)
        syncHover()
    }

    /// Springs the shape to `target`. The window first grows to hold both sizes, then shrinks to the new one.
    private func transition(to target: CGRect, radius: CGFloat, then completion: (() -> Void)? = nil) {
        generation += 1
        let gen = generation
        setWindowFrame(shapeRect.union(target).union(stripRect))
        shapeRect = target
        shapeRadius = radius
        root.setShape(NotchShapeView.path(local(target), radius: radius), animated: true) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.setWindowFrame(target.union(self.stripRect))
            completion?()
        }
    }

    private func slideClosed() {
        closing = true
        let wasKey = window.isKeyWindow
        transition(to: closedRect, radius: Self.closedRadius) { [weak self] in
            guard let self else { return }
            self.closing = false
            // The pill may have appeared or gone while sliding.
            if self.shapeRect != self.closedRect { self.transition(to: self.closedRect, radius: Self.closedRadius) }
            // Hand the keyboard back to the app the user was in (the panel became key only through a click).
            if wasKey || self.window.isKeyWindow {
                self.window.orderOut(nil)
                self.window.orderFrontRegardless()
            }
            self.showNextAlert()
        }
    }

    // MARK: Pill

    private func updatePill() {
        let account = store.pillAccount
        let wanted = account != nil && menuBarVisible && (store.activeProvider != nil || showAlways)
        let now = Date()
        if let account {
            let w = tightestWindow(store.snapshots[account.id]?.windows ?? [], now: now)
            pill.update(percent: w?.usedPercent, tone: Tone(w.flatMap { store.pace(account.id, $0, now: now) }))
        }
        pillShown = wanted
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        // objectWillChange fires before the change: read the store on the next turn of the run loop.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshQueued = false
                self?.refresh()
            }
        }
    }

    private func refresh() {
        guard screenInfo != nil else { return }
        let wasShown = pillShown
        updatePill()
        switch mode {
        case .closed:
            if wasShown != pillShown && !closing { transition(to: closedRect, radius: Self.closedRadius) }
        case .open:
            resizePanel()
        case .alert:
            break
        }
    }

    /// The selected account or its data changed while open: follow the content's height.
    private func resizePanel() {
        guard let host = hosting, let info = screenInfo else { return }
        host.rootView = makePanel()
        let target = NotchLayout.panelRect(notch: notch, contentHeight: host.fittingSize.height, screen: info)
        guard abs(target.height - panelRect.height) > 0.5 else { return }
        panelRect = target
        transition(to: target, radius: Self.openRadius)
    }

    private func makePanel() -> PanelView {
        PanelView(store: store, topInset: notch.height) { [weak self] in self?.onOpenUsage() }
    }

    // MARK: Alerts

    private func showNextAlert() {
        guard mode == .closed, !closing, let info = screenInfo, let item = banner.next() else { return }
        let view = banner.makeView(item)
        let width = min(max(view.fittingSize.width, 260), min(520, info.frame.width - 20))
        var x = notch.midX - width / 2
        x = min(max(x, info.frame.minX), info.frame.maxX - width)
        alertRect = CGRect(x: x, y: info.frame.maxY - notch.height - AlertBanner.lineHeight, width: width,
                           height: notch.height + AlertBanner.lineHeight)
        alertView = view
        view.alphaValue = 0
        root.addSubview(view, positioned: .below, relativeTo: pill)
        mode = .alert
        transition(to: alertRect, radius: Self.openRadius)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            view.animator().alphaValue = 1
        }
        alertTimer = oneShot(AlertBanner.visibleFor) { [weak self] in self?.dismissAlert() }
    }

    private func dismissAlert() {
        guard mode == .alert else { return }
        removeAlertView()
        mode = .closed
        slideClosed()
    }

    private func removeAlertView() {
        cancel(&alertTimer)
        alertView?.removeFromSuperview()
        alertView = nil
    }

    // MARK: Mouse and keyboard

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        if inside {
            cancel(&closeTimer)
            // An alert dropping under a still cursor must not turn into the panel; a click still opens it.
            if mode == .closed && openTimer == nil {
                openTimer = oneShot(Self.openDelay) { [weak self] in
                    guard let self else { return }
                    self.openTimer = nil
                    if self.hovering { self.openPanel() }
                }
            }
        } else {
            cancel(&openTimer)
            if mode == .open && closeTimer == nil && !menuOpen {
                closeTimer = oneShot(Self.closeDelay) { [weak self] in
                    self?.closeTimer = nil
                    self?.closePanel()
                }
            }
        }
    }

    /// Frame changes under a still mouse send no enter/exit events: compare by hand.
    func menuWillOpen() { menuOpen = true }

    /// The mouse may have left while the menu was up (no close was scheduled then): decide now.
    func menuDidClose() {
        menuOpen = false
        hoverChanged(window.frame.contains(NSEvent.mouseLocation))
    }

    private func syncHover() {
        let inside = window.frame.contains(NSEvent.mouseLocation)
        if inside != hovering { hoverChanged(inside) }
    }

    private func clicked(_ event: NSEvent) {
        let point = window.convertPoint(toScreen: event.locationInWindow)
        if pillShown && pillRect.contains(point) {
            onOpenUsage()
        } else if mode != .open {
            openPanel()
        }
    }

    private func addMonitors() {
        guard monitors.isEmpty else { return }
        // Local monitors see only events sent to Mate's own windows, and live only while the panel is open.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            MainActor.assumeIsolated { self?.closePanel() }
            return nil
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let e = event
            let consumed = MainActor.assumeIsolated { self?.scrolled(e) ?? false }
            return consumed ? nil : event
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    /// One account per gesture step; momentum is ignored so a flick does not run through every account.
    /// Returns whether the event was used.
    private func scrolled(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        if !event.momentumPhase.isEmpty { return true }
        if event.phase == .began { scrollAccumulated = 0 }
        // A mouse wheel reports lines: one notch must reach the threshold on its own.
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * Self.scrollThreshold
        let deltaX = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * Self.scrollThreshold
        scrollAccumulated += abs(deltaX) > abs(delta) ? -deltaX : delta
        if abs(scrollAccumulated) >= Self.scrollThreshold {
            store.selectAccount(step: scrollAccumulated < 0 ? 1 : -1)
            scrollAccumulated = 0
        }
        return true
    }

    // MARK: Notifications

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping (NotchController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
        observers.append((center, token))
    }

    private func spaceChanged() {
        updateMenuBarVisibility()
        // The window list can lag the space switch: look once more a moment later.
        cancel(&recheckTimer)
        recheckTimer = oneShot(1) { [weak self] in
            self?.recheckTimer = nil
            self?.updateMenuBarVisibility()
        }
    }

    private func updateMenuBarVisibility() {
        guard let info = screenInfo, let screen = NSScreen.screens.first(where: { $0.displayID == info.id }) else { return }
        let visible = screen.isMenuBarVisible
        guard visible != menuBarVisible else { return }
        menuBarVisible = visible
        refreshClosedShape()
    }

    private func refreshClosedShape() {
        updatePill()
        if mode == .closed && !closing { transition(to: closedRect, radius: Self.closedRadius) }
    }

    private func preferencesChanged() {
        let notify = NotchPrefs.systemNotifications
        if notify && !notifications { AlertBanner.requestPermission() }
        notifications = notify
        let choice = NotchPrefs.screenChoice
        if choice != screenChoice {
            screenChoice = choice
            layout()
        }
        let always = NotchPrefs.showPillAlways
        if always != showAlways {
            showAlways = always
            refreshClosedShape()
        }
    }

    // MARK: Timers

    private func oneShot(_ interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: false) { _ in MainActor.assumeIsolated { block() } }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func cancel(_ timer: inout Timer?) {
        timer?.invalidate()
        timer = nil
    }
}
