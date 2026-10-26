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
    /// Keep-awake engaged: the mate sips once the ears' opening spring has settled.
    private static let sipAfterEngage: TimeInterval = 0.8

    var onOpenUsage: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    private enum Mode { case closed, open, alert }

    let store: UsageStore
    let window = NotchWindow()
    let root = NotchShapeView()
    private let pill = PillView()
    private let mate = MateIconView()
    private let music = MusicEarView()
    private let nowPlaying = NowPlayingCenter.shared
    private let banner = AlertBanner()

    private var screenInfo: ScreenInfo?
    /// The notch where it is (real) or where Mate draws it (fake, centered); the open panel and alerts hang from it.
    private var homeNotch = CGRect.zero
    /// The closed shape's notch: `homeNotch`, slid off the app's menus on a fake notch (`MenuBarAvoid`).
    private var notch = CGRect.zero
    /// Where the closed content views were last placed (x of `notch`), so a shift slides them along.
    private var drawnNotchX: CGFloat = 0
    private let menuBar = MenuBarWatcher.shared
    private var fakeNotch = false
    private var menuBarVisible = true
    private var pillShown = false
    /// The pill view is on screen (not faded out); it hides while the panel or an alert is open.
    private var pillVisible = false
    /// What the left ear shows closed (`NowPlayingUI.leftEar`): the album art while music plays, else the mate
    /// (`MateEar`: with the pill, or while the Mac is kept awake), else nothing.
    private var leftEar = LeftEarContent.none
    private var mateShown: Bool { leftEar == .mate }
    private var musicShown: Bool { leftEar == .music }
    /// The mate view is on screen (not faded out); like the pill, it hides while the panel or an alert is open.
    private var mateOnScreen = false
    /// The music ear's view is on screen (its bars bounce only then).
    private var musicOnScreen = false
    /// "Mostrar el mate junto al notch": the mate's ear shows left of the notch whenever the pill shows.
    private var showMate = NotchPrefs.showMateIcon
    /// The next sip of the mate (one-shot, armed only while agents work and the mate's ear shows).
    private var sipTimer: Timer?
    /// An agent worked since the sip timer was armed.
    private var sawActivity = false
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
    /// Target of the mate's ear (left of the notch); nil when not drawn.
    private var leftEarRect: CGRect?
    private var panelRect = CGRect.zero
    private var alertRect = CGRect.zero
    /// Bumped by every shape transition, so a superseded animation's completion does nothing.
    private var generation = 0

    private var panelView: PanelPager?
    /// The step of the swipe that changed the selection, so the slide goes the way the fingers went.
    private var pendingStep: Int?
    private var alertView: NSView?
    /// What a click on the alert on screen does.
    private var alertAction: AlertBanner.Item.Action = .openPanel
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
    private var storeChanges: [AnyCancellable] = []
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
        if DebugCLI.isInvisible {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
        window.contentView = root
        root.content.addSubview(pill)
        root.content.addSubview(mate)
        root.content.addSubview(music)
        root.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        root.onClick = { [weak self] event in self?.clicked(event) }
        root.onRightClick = { [weak self] event in self?.showMenu(event) }

        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observe(center, NSApplication.didChangeScreenParametersNotification) { $0.layout() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.spaceChanged() }
        observe(center, UserDefaults.didChangeNotification) { $0.preferencesChanged() }
        observeStore()
        observeKeepAwake()
        observeNowPlaying()
        menuBar.onChange = { [weak self] in self?.queueRefresh() }
        // The permission row comes and goes with the trust flag while the panel is open.
        storeChanges.append(menuBar.objectWillChange.sink { [weak self] _ in self?.queueRefresh() })

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

    /// A background update check found `version`: one alert ("click to install"), shown when the notch is closed.
    func presentUpdate(_ version: String) {
        let text = String(localized: "Mate \(version) disponible — click para instalar")
        Log.info("alert: \(text)")
        banner.enqueue(AlertBanner.Item(text: text, tone: .ok, action: .installUpdate))
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
        // Before the page is built, so its keep-awake and permission rows are measured with the panel's first height.
        KeepAwake.shared.checkExternal()
        menuBar.recheckTrust()
        // The controller lives as long as the app.
        nowPlaying.panelOpen = true
        let container = PanelPager(store: store, accountID: store.panelAccount?.id, topInset: notch.height) {
            [unowned self] id, hasDots, cardSpace in
            self.makePanel(accountID: id, hasDots: hasDots, cardSpace: cardSpace)
        }
        panelRect = NotchLayout.panelRect(notch: homeNotch, contentHeight: container.fittingHeight, screen: info)
        panelView = container
        root.content.addSubview(container, positioned: .below, relativeTo: pill)
        mode = .open
        // The panel grows symmetrically out of the notch; the pill retracts into it (the panel shows the numbers).
        hideClosedContent()
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
        nowPlaying.panelOpen = false
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
        guard let info = NotchLayout.pickScreen(screens.map { DebugCLI.notchScreen($0.info) }, choice: screenChoice,
                                                mouseScreen: mouseID),
              let screen = screens.first(where: { $0.displayID == info.id }) else {
            endWithoutAnimation()
            screenInfo = nil
            menuBar.update(screen: nil, fakeNotch: false)
            window.orderOut(nil)
            return
        }
        screenInfo = info
        (homeNotch, fakeNotch) = NotchLayout.notchRect(on: info)
        notch = homeNotch
        menuBar.update(screen: info, fakeNotch: fakeNotch)
        menuBarVisible = screen.isMenuBarVisible
        recheckMenuBar()
        endWithoutAnimation()
        updatePill()
        shapeRect = closedRect
        shapeRadius = Self.closedRadius
        earRect = pillShown ? pillEar : nil
        leftEarRect = leftEarShape
        pillVisible = pillShown
        mateOnScreen = mateShown
        musicOnScreen = musicShown
        music.setPlaying(musicOnScreen)
        drawnNotchX = notch.minX
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
            nowPlaying.panelOpen = false
            store.panelDidClose()
        }
        if mode == .alert { removeAlertView() }
        mode = .closed
        closing = false
        generation += 1
        flushRetired()
        // A hide that was in flight must not leave the pill (or the mate) held invisible.
        NotchMotion.restore(pill)
        NotchMotion.restore(mate)
        NotchMotion.restore(music)
    }

    private var pillRect: CGRect { NotchLayout.pillRect(notch: notch, tagged: pillTagged) }

    /// What the window covers when closed: the notch (hover opens the panel even with the pill hidden) and the pill.
    /// A fake notch with the menu bar hidden (another app in full screen) keeps only a 2 pt edge at the very top,
    /// so it takes no clicks from that app.
    private var stripRect: CGRect {
        if pillShown || leftEar != .none {
            return notch.union(pillShown ? pillRect : .null).union(leftRect ?? .null)
        }
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

    /// The left ear's content rect for what it shows (the mate's, or the wider music one); nil when nothing.
    private var leftRect: CGRect? { NotchLayout.leftEarRect(notch: notch, content: leftEar) }

    /// The left ear's shape, the mirror of `pillEar`: it ends inside the notch, past the notch's rounded corner.
    private var leftEarShape: CGRect? {
        leftRect.map { CGRect(x: $0.minX, y: notch.minY, width: $0.width + 2 * Self.closedRadius, height: notch.height) }
    }

    /// The left ear retracted into the notch.
    private var tuckedLeftEar: CGRect {
        CGRect(x: notch.minX, y: notch.minY, width: 2 * Self.closedRadius, height: notch.height)
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
        mate.frame = local(NotchLayout.mateIconRect(notch: notch))
        music.frame = local(NotchLayout.musicRect(notch: notch))
        if pillVisible || final { pill.isHidden = !pillVisible }
        if mateOnScreen || final { mate.isHidden = !mateOnScreen }
        if musicOnScreen || final { music.isHidden = !musicOnScreen }
        panelView?.frame = local(panelRect)
        alertView?.frame = local(CGRect(x: alertRect.minX, y: alertRect.minY, width: alertRect.width,
                                        height: AlertBanner.lineHeight))
        root.set(.body, NotchShapeView.path(local(shapeRect), radius: shapeRadius))
        root.set(.ear, earRect.map { NotchShapeView.path(local($0), radius: Self.closedRadius) })
        root.set(.leftEar, leftEarRect.map { NotchShapeView.path(local($0), radius: Self.closedRadius) })
        syncHover()
    }

    private enum Ear { case keep, show, hide }

    /// Morphs the body to `target` (and the ears out of or into the notch) with the top edge pinned to the screen
    /// top. The window is set once to hold both shapes (with room for the spring's overshoot sideways and downward,
    /// never upward), the shape animates inside it, and the window shrinks to the final shape when both parts end.
    private func transition(to target: CGRect, radius: CGFloat, spring: NotchShapeView.Spring = .open,
                            delay: CFTimeInterval = 0, ear: Ear = .keep, then completion: (() -> Void)? = nil) {
        generation += 1
        let gen = generation
        let oldOrigin = window.frame.origin
        let bodyInFlight = root.isAnimating(.body) ? root.presentedPath(.body) : nil
        let earInFlight = root.isAnimating(.ear) ? root.presentedPath(.ear) : nil
        let leftInFlight = root.isAnimating(.leftEar) ? root.presentedPath(.leftEar) : nil
        let fromRect = visual(shapeRect), fromRadius = shapeRadius
        let toRect = visual(target)
        let oldEar = earRect, oldLeft = leftEarRect
        let newEar: CGRect?, newLeft: CGRect?
        switch ear {
        case .keep: (newEar, newLeft) = (oldEar, oldLeft)
        case .show: (newEar, newLeft) = (pillShown ? pillEar : nil, leftEarShape)
        case .hide: (newEar, newLeft) = (nil, nil)
        }

        // Room for an underdamped spring's overshoot; a critically damped one (closing) needs none. When the window
        // already holds everything (closing from the panel) it is left alone: no resize at the start of the motion.
        let both = fromRect.union(toRect).union(shapeRect).union(target).union(stripRect)
            .union(oldEar ?? .null).union(newEar ?? .null).union(oldLeft ?? .null).union(newLeft ?? .null)
        let slack: CGFloat = spring.damping < 1 ? 12 : 0
        let needed = CGRect(x: both.minX - slack, y: both.minY - slack, width: both.width + 2 * slack,
                            height: both.height + slack).integral
        setWindowFrame(window.frame.contains(needed) ? window.frame : needed, final: false)
        shapeRect = target
        shapeRadius = radius
        earRect = newEar
        leftEarRect = newLeft
        // An ear that comes out while the shape slides starts tucked where the notch was, not where it goes.
        let moved = drawnNotchX - notch.minX
        drawnNotchX = notch.minX

        // An interrupted animation continues from where it is, moved into the new window's coordinates.
        var shift = CGAffineTransform(translationX: oldOrigin.x - window.frame.minX, y: oldOrigin.y - window.frame.minY)
        let from = bodyInFlight?.copy(using: &shift) ?? NotchShapeView.path(local(fromRect), radius: fromRadius)
        let to = NotchShapeView.path(local(toRect), radius: radius)
        let earFrom = earInFlight?.copy(using: &shift)
            ?? NotchShapeView.path(local(oldEar ?? tuckedEar.offsetBy(dx: moved, dy: 0)), radius: Self.closedRadius)
        let earTo = NotchShapeView.path(local(newEar ?? tuckedEar), radius: Self.closedRadius)
        let moveEar = oldEar != nil || newEar != nil
        let leftFrom = leftInFlight?.copy(using: &shift)
            ?? NotchShapeView.path(local(oldLeft ?? tuckedLeftEar.offsetBy(dx: moved, dy: 0)), radius: Self.closedRadius)
        let leftTo = NotchShapeView.path(local(newLeft ?? tuckedLeftEar), radius: Self.closedRadius)
        let moveLeft = oldLeft != nil || newLeft != nil

        let finish = { [weak self] in
            guard let self, gen == self.generation else { return }
            self.flushRetired()
            self.setWindowFrame(target.union(self.stripRect).union(self.earRect ?? .null)
                .union(self.leftEarRect ?? .null))
            completion?()
        }
        if NotchMotion.reduceMotion {
            root.crossfade(body: to, ear: newEar.map { NotchShapeView.path(local($0), radius: Self.closedRadius) },
                           leftEar: newLeft.map { NotchShapeView.path(local($0), radius: Self.closedRadius) },
                           completion: finish)
            return
        }
        var pending = 1 + (moveEar ? 1 : 0) + (moveLeft ? 1 : 0)
        let partDone = {
            pending -= 1
            if pending == 0 { finish() }
        }
        root.animate(.body, from: from, to: to, spring: spring, delay: delay, completion: partDone)
        if moveEar {
            root.animate(.ear, from: earFrom, to: earTo, spring: newEar == nil ? .close : spring, delay: delay,
                         completion: partDone)
        }
        if moveLeft {
            root.animate(.leftEar, from: leftFrom, to: leftTo, spring: newLeft == nil ? .close : spring, delay: delay,
                         completion: partDone)
        }
    }

    /// Closes in one motion: the body retracts straight into the closed shape while the content fades out, and the
    /// ears grow back with the pill and the mate fading in from about 40 % of the way.
    private func slideClosed() {
        closing = true
        let wasKey = window.isKeyWindow
        showClosedContent(revealDelay: Self.pillReturnDelay)
        transition(to: closedRect, radius: Self.closedRadius, spring: .close, ear: .show) { [weak self] in
            guard let self else { return }
            self.closing = false
            // The pill or the mate may have appeared or gone, or the menu bar changed, while closing.
            if self.shapeRect != self.closedRect || (self.earRect != nil) != self.pillShown
                || self.leftEarRect != self.leftEarShape || self.pillVisible != self.pillShown
                || self.mateOnScreen != self.mateShown || self.musicOnScreen != self.musicShown {
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

    /// The closed shape changed (pill or mate shown or hidden, menu bar shown or hidden, panel just closed): each ear
    /// slides out of the notch's side with its content fading in, or fades and retracts into the notch. One ear can
    /// come while the other goes; the spring is the opening one when anything comes.
    /// A shift off the menu bar's menus slides the whole shape, its content along with it, on the opening spring.
    private func transitionClosed() {
        let growing = (pillShown && earRect == nil)
            || (leftEarShape.map { $0.width > (leftEarRect?.width ?? 0) } ?? false)
        let dx = notch.minX - drawnNotchX
        let moving = growing || dx != 0
        let onScreen = [pill, mate, music].filter { !$0.isHidden }
        showClosedContent()
        let spring: NotchShapeView.Spring = moving ? .open : .close
        transition(to: closedRect, radius: Self.closedRadius, spring: spring, delay: moving ? 0 : 0.05, ear: .show)
        if dx != 0 && !NotchMotion.reduceMotion {
            for view in onScreen { NotchMotion.slide(view, by: dx, spring: spring) }
        }
    }

    /// Shows the pill and the mate that are wanted closed and hides the others: a view that comes cancels any held
    /// or in-flight fade-out and fades in if it was not on screen.
    private func showClosedContent(revealDelay: CFTimeInterval = 0.1) {
        pillVisible = setOnScreen(pill, pillShown, was: pillVisible, revealDelay: revealDelay)
        mateOnScreen = setOnScreen(mate, mateShown, was: mateOnScreen, revealDelay: revealDelay)
        musicOnScreen = setOnScreen(music, musicShown, was: musicOnScreen, revealDelay: revealDelay)
    }

    /// Fades the pill and the mate out and holds them invisible until `showClosedContent`.
    private func hideClosedContent() {
        pillVisible = setOnScreen(pill, false, was: pillVisible, revealDelay: 0)
        mateOnScreen = setOnScreen(mate, false, was: mateOnScreen, revealDelay: 0)
        musicOnScreen = setOnScreen(music, false, was: musicOnScreen, revealDelay: 0)
    }

    private func setOnScreen(_ view: NSView, _ on: Bool, was: Bool, revealDelay: CFTimeInterval) -> Bool {
        if on {
            view.isHidden = false
            NotchMotion.restore(view)
            if !was { NotchMotion.reveal(view, delay: revealDelay, duration: 0.14) }
            if view === music { music.setPlaying(true) }
        } else if was {
            if NotchMotion.reduceMotion { view.isHidden = true } else { NotchMotion.fadeOut(view, duration: 0.08) }
            if view === mate { mate.stop() }
            if view === music { music.setPlaying(false) }
        }
        return on
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
        let left = NowPlayingUI.leftEar(showMusic: nowPlaying.enabled, playing: nowPlaying.current?.state == .playing,
                                        showMate: showMate, menuBarVisible: menuBarVisible, pillShown: wanted,
                                        keptAwake: KeepAwake.shared.showsDot)
        let placement = closedPlacement(left: left, pill: wanted)
        notch = homeNotch.offsetBy(dx: placement.shift, dy: 0)
        pillShown = wanted
        leftEar = placement.showsLeftEar ? left : .none
    }

    /// On a fake notch with the menu bar showing and its extents known: off the app's menus (`MenuBarAvoid`);
    /// otherwise centered, as on a real notch.
    private func closedPlacement(left: LeftEarContent, pill: Bool) -> MenuBarAvoid.Placement {
        guard fakeNotch, menuBarVisible, menuBar.active, let extents = menuBar.extents, let info = screenInfo
        else { return .centered }
        return MenuBarAvoid.place(notch: homeNotch, leftEar: NotchLayout.leftEarRect(notch: homeNotch, content: left)?.width,
                                  rightEar: pill ? NotchLayout.pillRect(notch: homeNotch, tagged: pillTagged).width : nil,
                                  extents: extents, screen: info.frame)
    }

    /// Only the store changes that can change what the notch shows (`NotchRefresh`): closed, an agent streaming
    /// its log (new aggregates every batch) costs the notch nothing.
    private func observeStore() {
        func on<V>(_ change: NotchRefresh.Change, _ publisher: Published<V>.Publisher) -> AnyCancellable {
            // dropFirst: a @Published publisher replays its current value on subscription.
            publisher.dropFirst().sink { [weak self] _ in
                guard let self, NotchRefresh.needed(for: change, panelOpen: self.mode == .open) else { return }
                self.queueRefresh()
            }
        }
        storeChanges = [
            on(.accounts, store.$accounts), on(.snapshots, store.$snapshots),
            on(.activeProvider, store.$activeProvider), on(.selection, store.$selectedAccountID),
            on(.paused, store.$isPaused), on(.aggregates, store.$aggregates),
            on(.activeProvider, store.$workingProviders),
        ]
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        // @Published publishes before the change: read the store on the next turn of the run loop.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshQueued = false
                self?.refresh()
            }
        }
    }

    private func refresh() {
        guard screenInfo != nil else { return }
        let wasShown = pillShown, wasTagged = pillTagged, wasLeft = leftEar, wasNotch = notch
        updatePill()
        mate.showsDot = KeepAwake.shared.showsDot
        music.showsDot = KeepAwake.shared.showsDot
        music.setArtwork(nowPlaying.artwork)
        updateSip()
        switch mode {
        case .closed:
            let changed = wasShown != pillShown || (pillShown && wasTagged != pillTagged) || wasLeft != leftEar
                || wasNotch != notch
            if changed && !closing { transitionClosed() }
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
        let target = NotchLayout.panelRect(notch: homeNotch, contentHeight: pager.fittingHeight, screen: info)
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

    private func makePanel(accountID: String?, hasDots: Bool, cardSpace: CGFloat) -> PanelView {
        PanelView(store: store, accountID: accountID, hasDots: hasDots, topInset: notch.height + cardSpace,
                  hint: showHint) {
            [weak self] in self?.onOpenUsage()
        }
    }

    // MARK: Mate

    /// The mate's dot and the panel's keep-awake row follow `KeepAwake`; the mate sips once when keep-awake engages.
    private func observeKeepAwake() {
        let awake = KeepAwake.shared
        storeChanges.append(awake.objectWillChange.sink { [weak self] _ in self?.queueRefresh() })
        // Keep-awake engages when agents start working, which is also when the pill (and the mate) slide out: sip
        // once they are out.
        storeChanges.append(awake.$held.removeDuplicates().dropFirst().sink { [weak self] held in
            guard held else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sipAfterEngage) { self?.sip() }
        })
    }

    // MARK: Now playing

    /// The art ear and the panel's card follow the player (track, play/pause, artwork, permission). The card's
    /// clock ticks on its own object, so it never reaches here.
    private func observeNowPlaying() {
        storeChanges.append(nowPlaying.objectWillChange.sink { [weak self] _ in self?.queueRefresh() })
    }

    /// The mate is on screen, at rest or sipping.
    private var mateVisible: Bool { mode == .closed && !closing && mateOnScreen }

    /// Plays one sip if the mate is on screen (never with Reduce Motion).
    private func sip() {
        guard MateSip.shouldPlay(mateVisible: mateVisible, sawActivity: true, reduceMotion: NotchMotion.reduceMotion)
        else { return }
        mate.play()
    }

    /// Arms the next sip (12 to 25 minutes) while agents work and the mate's ear shows; cancels it otherwise. While
    /// armed and the agents go idle, it stays: it fires once, plays if an agent worked meanwhile, and re-arms only if
    /// they are still working.
    private func updateSip() {
        let working = !store.workingProviders.isEmpty
        let reduce = NotchMotion.reduceMotion
        guard mateShown, !reduce else {
            cancel(&sipTimer)
            return
        }
        if working { sawActivity = true }
        guard sipTimer == nil, MateSip.shouldArm(earShown: mateShown, agentsActive: working, reduceMotion: reduce)
        else { return }
        sipTimer = oneShot(MateSip.delay(unit: Double.random(in: 0...1))) { [weak self] in self?.sipFired() }
    }

    private func sipFired() {
        sipTimer = nil
        if MateSip.shouldPlay(mateVisible: mateVisible, sawActivity: sawActivity, reduceMotion: NotchMotion.reduceMotion) {
            mate.play()
        }
        sawActivity = false
        updateSip()
    }

    /// `--snapshot-anim`: starts a sip now, whatever the schedule.
    func debugSip() { mate.play() }

    // MARK: Alerts

    private func showNextAlert() {
        guard mode == .closed, !closing, let info = screenInfo, let item = banner.next() else { return }
        let view = banner.makeView(item)
        alertAction = item.action
        let width = min(max(view.fittingSize.width, 260), min(520, info.frame.width - 20))
        var x = homeNotch.midX - width / 2
        x = min(max(x, info.frame.minX), info.frame.maxX - width)
        alertRect = CGRect(x: x, y: info.frame.maxY - notch.height - AlertBanner.lineHeight, width: width,
                           height: notch.height + AlertBanner.lineHeight)
        alertView = view
        view.wantsLayer = true
        root.content.addSubview(view, positioned: .below, relativeTo: pill)
        mode = .alert
        hideClosedContent()
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
        } else if mode == .alert && alertAction == .installUpdate {
            dismissAlert()
            Updater.shared.offerInstall()
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
        recheckMenuBar()
    }

    /// The window list lags a space switch, and a display that was just connected has no menu bar window for a
    /// second or two: look again 1 s later and 2 s after that, or the notch stays hidden until the next space switch.
    private func recheckMenuBar(waits: ArraySlice<TimeInterval> = [1, 2]) {
        cancel(&recheckTimer)
        guard let wait = waits.first else { return }
        recheckTimer = oneShot(wait) { [weak self] in
            self?.recheckTimer = nil
            self?.updateMenuBarVisibility()
            self?.recheckMenuBar(waits: waits.dropFirst())
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
        // "Esquivar los menús": starts or stops the watcher; its extents change refreshes the shape.
        menuBar.update(screen: screenInfo, fakeNotch: fakeNotch)
        let always = NotchPrefs.showPillAlways
        let withMate = NotchPrefs.showMateIcon
        if always != showAlways || withMate != showMate {
            showAlways = always
            showMate = withMate
            refreshClosedShape()
            updateSip()
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
