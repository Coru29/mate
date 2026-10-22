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
    private static let closeDelay: TimeInterval = 0.15
    private static let scrollThreshold: CGFloat = 40
    /// About when an opening spring reaches 60 % of its travel.
    private static let contentDelay: CFTimeInterval = 0.12
    /// Closing: the content fades out this fast, while the shape is already retracting.
    private static let contentFadeOut: CFTimeInterval = 0.08
    /// Closing: the pill fades back in from about 40 % of the retract.
    private static let pillReturnDelay: CFTimeInterval = 0.09

    var onOpenUsage: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    private enum Mode { case closed, open, alert }

    let store: UsageStore
    let window = NotchWindow()
    let root = NotchShapeView()
    private let pill = PillView()
    private let banner = AlertBanner()

    private var screenInfo: ScreenInfo?
    private var notch = CGRect.zero
    private var fakeNotch = false
    private var menuBarVisible = true
    private var pillShown = false
    /// The pill view is on screen (not faded out); it hides while the panel or an alert is open.
    private var pillVisible = false
    /// `--snapshot-anim`: hides the pill as if it had no reason to show, to check interrupted hides.
    private var debugHidePill = false
    /// The pill shows a weekly window instead of the session, with a tag (and a wider shape).
    private var pillTagged = false

    private var mode = Mode.closed
    /// The shape is sliding back to its closed size; alerts wait for it.
    private var closing = false
    private var hovering = false
    /// The right-click menu is up: the mouse is on the menu, so leaving the shape must not close the panel.
    private var menuOpen = false
    /// Target of the black shape, in screen coordinates.
    private var shapeRect = CGRect.zero
    private var shapeRadius = closedRadius
    /// Target of the pill's ear (the black part right of the notch), in screen coordinates; nil when not drawn.
    private var earRect: CGRect?
    private var panelRect = CGRect.zero
    private var alertRect = CGRect.zero
    /// Bumped by every shape transition, so a superseded animation's completion does nothing.
    private var generation = 0

    private var panelView: PanelPager?
    /// The step of the swipe that changed the selection, so the slide goes the way the fingers went.
    private var pendingStep: Int?
    private var alertView: NSView?
    /// Panel or alert views fading out while the shape closes; removed when the shape is at rest, so nothing is
    /// re-laid out mid-animation.
    private var retired: [NSView] = []
    private var openTimer: Timer?
    private var closeTimer: Timer?
    private var alertTimer: Timer?
    private var recheckTimer: Timer?
    private var monitors: [Any] = []
    private var swipe = SwipeStepper(threshold: scrollThreshold)
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var storeChanges: AnyCancellable?
    private var refreshQueued = false
    private var showAlways = NotchPrefs.showPillAlways
    private var screenChoice = NotchPrefs.screenChoice
    private var notifications = NotchPrefs.systemNotifications
    private var shownProviders = (NotchPrefs.providerOrder, NotchPrefs.disabledProviders)
    /// The panel shows the welcome guide's hint until it closes.
    private var showHint = false

    init(store: UsageStore) {
        self.store = store
    }

    // MARK: Public API

    func show() {
        window.contentView = root
        root.content.addSubview(pill)
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
        scheduleAnimationSnapshots()
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

    /// Opens the panel right away (hover after the delay, a click, an alert click, `--open-panel`). `hint` adds the
    /// "Mate vive acá" line, for the first opening after the welcome guide.
    func openPanel(hint: Bool = false) {
        guard mode != .open, let info = screenInfo else { return }
        showHint = hint
        resetSwipe()
        cancel(&openTimer)
        cancel(&closeTimer)
        if mode == .alert { removeAlertView() }
        closing = false
        // The controller lives as long as the app.
        let container = PanelPager(store: store, accountID: store.panelAccount?.id) { [unowned self] id, hasDots in
            self.makePanel(accountID: id, hasDots: hasDots)
        }
        panelRect = NotchLayout.panelRect(notch: notch, contentHeight: container.fittingHeight, screen: info)
        panelView = container
        root.content.addSubview(container, positioned: .below, relativeTo: pill)
        mode = .open
        // The panel grows symmetrically out of the notch; the pill retracts into it (the panel shows the numbers).
        hidePill()
        transition(to: panelRect, radius: Self.openRadius, ear: .hide)
        // The content comes in once the shape is about 60 % open.
        NotchMotion.reveal(container, delay: Self.contentDelay)
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
        showHint = false
        store.panelDidClose()
        Log.info("panel closed")
        if let container = panelView {
            panelView = nil
            retire(container)
        }
        slideClosed()
    }

    /// Fades a panel or alert view out (as a frozen bitmap) and keeps it until the shape is at rest.
    private func retire(_ view: NSView) {
        if let layer = view.layer {
            layer.rasterizationScale = window.backingScaleFactor
            layer.shouldRasterize = true
        }
        NotchMotion.fadeOut(view, duration: Self.contentFadeOut)
        retired.append(view)
    }

    private func flushRetired() {
        for view in retired { view.removeFromSuperview() }
        retired.removeAll()
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
        earRect = pillShown ? pillEar : nil
        pillVisible = pillShown
        setWindowFrame(stripRect)
        if !window.isVisible { window.orderFrontRegardless() }
        showNextAlert()
    }

    /// A screen change ends whatever was showing, without animation.
    private func endWithoutAnimation() {
        if mode == .open {
            removeMonitors()
            cancel(&closeTimer)
            panelView?.removeFromSuperview()
            panelView = nil
            store.panelDidClose()
        }
        if mode == .alert { removeAlertView() }
        mode = .closed
        closing = false
        generation += 1
        flushRetired()
        // A hide that was in flight must not leave the pill held invisible.
        NotchMotion.restore(pill)
    }

    private var pillRect: CGRect { NotchLayout.pillRect(notch: notch, tagged: pillTagged) }

    /// What the window covers when closed: the notch (hover opens the panel even with the pill hidden) and the pill.
    /// A fake notch with the menu bar hidden (another app in full screen) keeps only a 2 pt edge at the very top,
    /// so it takes no clicks from that app.
    private var stripRect: CGRect {
        if pillShown { return notch.union(pillRect) }
        if fakeNotch && !menuBarVisible { return CGRect(x: notch.minX, y: notch.maxY - 2, width: notch.width, height: 2) }
        return notch
    }

    /// The closed black body (the pill's ear is drawn apart). A real notch needs no drawing; a fake one is drawn
    /// while the menu bar shows.
    private var closedRect: CGRect {
        if fakeNotch && menuBarVisible { return notch }
        return CGRect(x: notch.minX, y: notch.maxY, width: notch.width, height: 0)
    }

    /// The ear behind the pill. It starts inside the notch, past the notch's own rounded corner, so the two join
    /// with a flat bottom.
    private var pillEar: CGRect {
        CGRect(x: notch.maxX - 2 * Self.closedRadius, y: notch.minY, width: pillRect.maxX - notch.maxX + 2 * Self.closedRadius,
               height: notch.height)
    }

    /// The ear retracted into the notch.
    private var tuckedEar: CGRect {
        CGRect(x: notch.maxX - 2 * Self.closedRadius, y: notch.minY, width: 2 * Self.closedRadius, height: notch.height)
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }

    /// The shape to animate from or to for `rect`. On a real notch the invisible closed shape (zero height) is
    /// animated as the notch itself, so the panel morphs out of the notch and back into it.
    private func visual(_ rect: CGRect) -> CGRect {
        rect.height == 0 && !fakeNotch ? notch : rect
    }

    /// Moves the window (never animated) and re-places everything in it, the shape at rest.
    /// `final` is false at the start of a transition: a pill that is going away stays until the shape is back.
    private func setWindowFrame(_ frame: CGRect, final: Bool = true) {
        if frame.integral != window.frame {
            window.setFrame(frame.integral, display: false)
            root.frame = CGRect(origin: .zero, size: window.frame.size)
        }
        pill.frame = local(pillRect)
        if pillVisible || final { pill.isHidden = !pillVisible }
        panelView?.frame = local(panelRect)
        alertView?.frame = local(CGRect(x: alertRect.minX, y: alertRect.minY, width: alertRect.width,
                                        height: AlertBanner.lineHeight))
        root.set(.body, NotchShapeView.path(local(shapeRect), radius: shapeRadius))
        root.set(.ear, earRect.map { NotchShapeView.path(local($0), radius: Self.closedRadius) })
        syncHover()
    }

    private enum Ear { case keep, show, hide }

    /// Morphs the body to `target` (and the ear out of or into the notch) with the top edge pinned to the screen
    /// top. The window is set once to hold both shapes (with room for the spring's overshoot sideways and downward,
    /// never upward), the shape animates inside it, and the window shrinks to the final shape when both parts end.
    private func transition(to target: CGRect, radius: CGFloat, spring: NotchShapeView.Spring = .open,
                            delay: CFTimeInterval = 0, ear: Ear = .keep, then completion: (() -> Void)? = nil) {
        generation += 1
        let gen = generation
        let oldOrigin = window.frame.origin
        let bodyInFlight = root.isAnimating(.body) ? root.presentedPath(.body) : nil
        let earInFlight = root.isAnimating(.ear) ? root.presentedPath(.ear) : nil
        let fromRect = visual(shapeRect), fromRadius = shapeRadius
        let toRect = visual(target)
        let oldEar = earRect
        let newEar: CGRect?
        switch ear {
        case .keep: newEar = oldEar
        case .show: newEar = pillEar
        case .hide: newEar = nil
        }

        // Room for an underdamped spring's overshoot; a critically damped one (closing) needs none. When the window
        // already holds everything (closing from the panel) it is left alone: no resize at the start of the motion.
        let both = fromRect.union(toRect).union(shapeRect).union(target).union(stripRect)
            .union(oldEar ?? .null).union(newEar ?? .null)
        let slack: CGFloat = spring.damping < 1 ? 12 : 0
        let needed = CGRect(x: both.minX - slack, y: both.minY - slack, width: both.width + 2 * slack,
                            height: both.height + slack).integral
        setWindowFrame(window.frame.contains(needed) ? window.frame : needed, final: false)
        shapeRect = target
        shapeRadius = radius
        earRect = newEar

        // An interrupted animation continues from where it is, moved into the new window's coordinates.
        var shift = CGAffineTransform(translationX: oldOrigin.x - window.frame.minX, y: oldOrigin.y - window.frame.minY)
        let from = bodyInFlight?.copy(using: &shift) ?? NotchShapeView.path(local(fromRect), radius: fromRadius)
        let to = NotchShapeView.path(local(toRect), radius: radius)
        let earFrom = earInFlight?.copy(using: &shift)
            ?? NotchShapeView.path(local(oldEar ?? tuckedEar), radius: Self.closedRadius)
        let earTo = NotchShapeView.path(local(newEar ?? tuckedEar), radius: Self.closedRadius)
        let moveEar = oldEar != nil || newEar != nil

        let finish = { [weak self] in
            guard let self, gen == self.generation else { return }
            self.flushRetired()
            self.setWindowFrame(target.union(self.stripRect).union(self.earRect ?? .null))
            completion?()
        }
        if NotchMotion.reduceMotion {
            root.crossfade(body: to, ear: newEar.map { NotchShapeView.path(local($0), radius: Self.closedRadius) },
                           completion: finish)
            return
        }
        var pending = moveEar ? 2 : 1
        let partDone = {
            pending -= 1
            if pending == 0 { finish() }
        }
        root.animate(.body, from: from, to: to, spring: spring, delay: delay, completion: partDone)
        if moveEar {
            root.animate(.ear, from: earFrom, to: earTo, spring: newEar == nil ? .close : spring, delay: delay,
                         completion: partDone)
        }
    }

    /// Closes in one motion: the body retracts straight into the closed shape while the content fades out, and the
    /// pill's ear grows back with the pill fading in from about 40 % of the way.
    private func slideClosed() {
        closing = true
        let wasKey = window.isKeyWindow
        if pillShown { showPill(revealDelay: Self.pillReturnDelay) }
        transition(to: closedRect, radius: Self.closedRadius, spring: .close,
                   ear: pillShown ? .show : .hide) { [weak self] in
            guard let self else { return }
            self.closing = false
            // The pill may have appeared or gone, or the menu bar changed, while closing.
            if self.shapeRect != self.closedRect || (self.earRect != nil) != self.pillShown
                || self.pillVisible != self.pillShown {
                self.transitionClosed()
            }
            // Hand the keyboard back to the app the user was in (the panel became key only through a click).
            if wasKey || self.window.isKeyWindow {
                self.window.orderOut(nil)
                self.window.orderFrontRegardless()
            }
            self.showNextAlert()
        }
    }

    /// The closed shape changed (pill shown or hidden, menu bar shown or hidden, panel just closed): the pill slides
    /// out of the notch's right edge with its ring fading in, or fades and retracts into the notch.
    private func transitionClosed() {
        if pillShown { showPill() } else { hidePill() }
        transition(to: closedRect, radius: Self.closedRadius, spring: pillShown ? .open : .close,
                   delay: pillShown ? 0 : 0.05, ear: pillShown ? .show : .hide)
    }

    /// Makes the pill visible, cancelling any held or in-flight fade-out; fades it in if it was not visible.
    private func showPill(revealDelay: CFTimeInterval = 0.1) {
        pill.isHidden = false
        NotchMotion.restore(pill)
        if !pillVisible { NotchMotion.reveal(pill, delay: revealDelay, duration: 0.14) }
        pillVisible = true
    }

    /// Fades the pill out and holds it invisible until `showPill`.
    private func hidePill() {
        if pillVisible {
            if NotchMotion.reduceMotion { pill.isHidden = true } else { NotchMotion.fadeOut(pill, duration: 0.08) }
        }
        pillVisible = false
    }

    // MARK: Pill

    private func updatePill() {
        let account = store.pillAccount
        let wanted = account != nil && menuBarVisible && (store.activeProvider != nil || showAlways) && !debugHidePill
        let now = Date()
        if let account {
            let w = pillWindow(store.snapshots[account.id]?.windows ?? [], now: now)
            let tagged: Bool
            switch w?.kind {
            case .weekly, .weeklyModel: tagged = true
            default: tagged = false
            }
            pill.update(percent: w?.usedPercent, tone: Tone(w.flatMap { store.pace(account.id, $0, now: now) }),
                        tag: tagged ? NotchText.weekTag : nil)
            pillTagged = tagged
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
        let wasShown = pillShown, wasTagged = pillTagged
        updatePill()
        switch mode {
        case .closed:
            if (wasShown != pillShown || (pillShown && wasTagged != pillTagged)) && !closing { transitionClosed() }
        case .open:
            resizePanel()
        case .alert:
            break
        }
    }

    /// The selected account or its data changed while open: slide to the new account, or redraw the page, and
    /// follow the content's height with the black shape (on the page spring, top pinned).
    private func resizePanel() {
        guard let pager = panelView, let info = screenInfo else { return }
        let id = store.panelAccount?.id
        if id != pager.accountID {
            let forward = pendingStep.map { $0 > 0 } ?? isForward(from: pager.accountID, to: id)
            pager.slide(to: id, forward: forward)
        } else {
            pager.refresh()
        }
        pendingStep = nil
        let target = NotchLayout.panelRect(notch: notch, contentHeight: pager.fittingHeight, screen: info)
        guard abs(target.height - panelRect.height) > 0.5 else { return }
        panelRect = target
        transition(to: target, radius: Self.openRadius, spring: .page)
    }

    /// A dot click or any other change of selection: forward when the new account comes later in the dots.
    private func isForward(from old: String?, to new: String?) -> Bool {
        let ids = store.notchAccounts.map(\.id)
        guard let a = old.flatMap({ ids.firstIndex(of: $0) }), let b = new.flatMap({ ids.firstIndex(of: $0) }) else {
            return true
        }
        return b > a
    }

    /// `--snapshot-anim`: one swipe step, as from the trackpad.
    func debugSwipe(step: Int) {
        pendingStep = step
        store.selectAccount(step: step)
    }

    private func makePanel(accountID: String?, hasDots: Bool) -> PanelView {
        PanelView(store: store, accountID: accountID, hasDots: hasDots, topInset: notch.height, hint: showHint) {
            [weak self] in self?.onOpenUsage()
        }
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
        view.wantsLayer = true
        root.content.addSubview(view, positioned: .below, relativeTo: pill)
        mode = .alert
        hidePill()
        transition(to: alertRect, radius: Self.openRadius, ear: .hide)
        NotchMotion.reveal(view, delay: Self.contentDelay)
        alertTimer = oneShot(AlertBanner.visibleFor) { [weak self] in self?.dismissAlert() }
    }

    private func dismissAlert() {
        guard mode == .alert else { return }
        cancel(&alertTimer)
        if let view = alertView {
            alertView = nil
            retire(view)
        }
        mode = .closed
        slideClosed()
    }

    private func removeAlertView() {
        cancel(&alertTimer)
        alertView?.removeFromSuperview()
        alertView = nil
    }

    // MARK: Mouse and keyboard

    /// Where hovering counts. Closed, only the notch strip: while the shape retracts the window is still the panel's
    /// size, and a cursor that just left the panel must not reopen it from the empty area.
    private var hoverRect: CGRect { mode == .closed ? stripRect : window.frame }

    private func hoverChanged(_ entered: Bool) {
        let inside = entered && NotchLayout.hoverContains(hoverRect, NSEvent.mouseLocation)
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
        hoverChanged(NotchLayout.hoverContains(window.frame, NSEvent.mouseLocation))
    }

    private func syncHover() {
        let mouse = NSEvent.mouseLocation
        let inside = NotchLayout.hoverContains(window.frame, mouse) && NotchLayout.hoverContains(hoverRect, mouse)
        if inside != hovering { hoverChanged(inside) }
    }

    private func clicked(_ event: NSEvent) {
        let point = window.convertPoint(toScreen: event.locationInWindow)
        if mode == .closed && pillShown && NotchLayout.hoverContains(pillRect, point) {
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

    /// Account switching by a horizontal two-finger swipe on the trackpad only: exactly one account per physical
    /// swipe (`SwipeStepper`), fingers to the right for the next one. Vertical scrolling, mouse wheels and momentum
    /// are ignored (the panel was too easy to flip by accident). Returns whether the event was used.
    private func scrolled(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        // Trackpad gestures have precise deltas; a mouse wheel does not (and has no phase either).
        guard event.hasPreciseScrollingDeltas else { return true }
        // Content follows the fingers whatever the natural-scrolling setting (the sign lives in SwipeStepper).
        guard let step = swipe.feed(phase: Self.swipePhase(event.phase), momentum: !event.momentumPhase.isEmpty,
                                    deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                    invertedFromDevice: event.isDirectionInvertedFromDevice) else { return true }
        // No wrap-around: past the last account a swipe does nothing (wrapping read as skipping accounts).
        let ids = store.notchAccounts.map(\.id)
        guard let current = store.panelAccount.flatMap({ ids.firstIndex(of: $0.id) }),
              ids.indices.contains(current + step) else { return true }
        pendingStep = step
        store.selectedAccountID = ids[current + step]
        return true
    }

    private static func swipePhase(_ phase: NSEvent.Phase) -> SwipeStepper.Phase {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.mayBegin) { return .mayBegin }
        return .none
    }

    private func resetSwipe() {
        swipe.reset()
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

    func debugSetPillHidden(_ hidden: Bool) {
        debugHidePill = hidden
        refreshClosedShape()
    }

    private func refreshClosedShape() {
        updatePill()
        if mode == .closed && !closing { transitionClosed() }
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
        // The pill and an open panel follow the provider order and the enabled providers.
        let providers = (NotchPrefs.providerOrder, NotchPrefs.disabledProviders)
        if providers != shownProviders {
            shownProviders = providers
            queueRefresh()
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
