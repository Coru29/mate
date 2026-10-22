import AppKit
import MateCore

/// Borderless, non-activating panel above the menu bar. The controller keeps its frame equal to the visible black
/// shape (notch strip, pill, open panel or alert), so everything outside it gets the clicks.
final class NotchWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Not `isFloatingPanel`: setting it resets `level` to .floating, below the menu bar, which then takes the mouse.
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
    }

    /// Key only after a click inside (so Esc works); hovering never takes the keyboard from the user's app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The panel lives over the menu bar: never let AppKit push it below.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var info: ScreenInfo {
        ScreenInfo(id: displayID, frame: frame, visibleFrame: visibleFrame, safeTop: safeAreaInsets.top,
                   leftAux: auxiliaryTopLeftArea, rightAux: auxiliaryTopRightArea,
                   builtIn: CGDisplayIsBuiltin(displayID) != 0, hasMenuBar: self == NSScreen.screens.first)
    }

    /// Whether this screen's menu bar is on screen (false in another app's full-screen space or with an auto-hidden
    /// menu bar). Reads the window list once; no permission needed for owner, layer and bounds.
    var isMenuBarVisible: Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
              let mainHeight = NSScreen.screens.first?.frame.height else { return true }
        // Window-list bounds are in global coordinates with the origin at the top-left of the main display.
        let top = mainHeight - frame.maxY
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        return list.contains { w in
            guard w[kCGWindowLayer as String] as? Int == menuLevel,
                  w[kCGWindowOwnerName as String] as? String == "Window Server",
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { return false }
            return abs(rect.minY - top) < 1 && rect.height < 80 && rect.minX < frame.maxX && rect.maxX > frame.minX
        }
    }
}

/// The window's content: the black shape as two `CAShapeLayer`s (the body: notch, panel or alert; and the ear: the
/// pill's part right of the notch), plus hover and click handling for the whole window. Two parts let the body grow
/// symmetrically out of the notch while the ear retracts into it. Hover comes from an `NSTrackingArea`, never from a
/// global monitor.
final class NotchShapeView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onClick: (NSEvent) -> Void = { _ in }
    var onRightClick: (NSEvent) -> Void = { _ in }

    enum Part { case body, ear }

    private let body = CAShapeLayer()
    private let ear = CAShapeLayer()
    /// Holds the pill, panel and alert views; masked by the same paths as the black shape, so content never shows
    /// outside it while the shape morphs (the pill slides out of the notch, the panel is uncovered as it grows).
    let content = NotchContentView()
    private let clipBody = CAShapeLayer()
    private let clipEar = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Barely there, so the window server routes the mouse to the whole frame even where nothing is drawn
        // (the hover strip over a hidden fake notch).
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.004).cgColor
        for l in [body, ear, clipBody, clipEar] { l.fillColor = NSColor.black.cgColor }
        layer?.addSublayer(body)
        layer?.addSublayer(ear)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        let clip = CALayer()
        clip.addSublayer(clipBody)
        clip.addSublayer(clipEar)
        content.layer?.mask = clip
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func mouseDown(with event: NSEvent) { onClick(event) }
    override func rightMouseDown(with event: NSEvent) { onRightClick(event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Spring as SwiftUI describes it (response, damping fraction), turned into Core Animation's terms.
    struct Spring {
        var response: Double
        var damping: Double
        /// Cut-off for the animation's duration: the tail of a spring is invisible, and the window shrinks only
        /// when it ends.
        var maxDuration: Double

        static let open = Spring(response: 0.42, damping: 0.82, maxDuration: 0.7)
        static let close = Spring(response: 0.22, damping: 1, maxDuration: 0.26)
    }

    private func layers(_ part: Part) -> [CAShapeLayer] {
        part == .body ? [body, clipBody] : [ear, clipEar]
    }

    func isAnimating(_ part: Part) -> Bool { layers(part)[0].animation(forKey: "path") != nil }

    /// What is on screen now (mid-animation, the in-flight path), in this view's coordinates.
    func presentedPath(_ part: Part) -> CGPath? {
        let l = layers(part)[0]
        return l.presentation()?.path ?? l.path
    }

    /// Sets a part at once (nil: not drawn).
    func set(_ part: Part, _ path: CGPath?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in layers(part) {
            l.removeAnimation(forKey: "path")
            l.path = path
        }
        CATransaction.commit()
    }

    /// Springs a part from `from` to `to`, starting after `delay`; `completion` runs when it ends (or is replaced by
    /// a newer animation).
    func animate(_ part: Part, from: CGPath, to: CGPath, spring s: Spring, delay: CFTimeInterval = 0,
                 completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let spring = CASpringAnimation(keyPath: "path")
        spring.fromValue = from
        spring.toValue = to
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / s.response, 2)
        spring.damping = 4 * .pi * s.damping / s.response
        spring.duration = min(spring.settlingDuration, s.maxDuration)
        if delay > 0 {
            spring.beginTime = CACurrentMediaTime() + delay
            spring.fillMode = .backwards
        }
        CATransaction.setCompletionBlock(completion)
        for l in layers(part) {
            l.add(spring, forKey: "path")
            l.path = to
        }
        CATransaction.commit()
    }

    /// Reduce Motion: the new state crossfades in, nothing moves.
    func crossfade(body bodyPath: CGPath, ear earPath: CGPath?, completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        CATransaction.setCompletionBlock(completion)
        layer?.add(fade, forKey: "crossfade")
        for (part, path) in [(Part.body, Optional(bodyPath)), (.ear, earPath)] {
            for l in layers(part) {
                l.removeAnimation(forKey: "path")
                l.path = path
            }
        }
        CATransaction.commit()
    }

    /// A rect with a flat top and rounded bottom corners. Always the same elements, so paths of different sizes
    /// interpolate smoothly.
    static func path(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height))
        let k: CGFloat = 0.552 // cubic approximation of a quarter circle
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r))
        p.addCurve(to: CGPoint(x: rect.maxX - r, y: rect.minY),
                   control1: CGPoint(x: rect.maxX, y: rect.minY + r * (1 - k)),
                   control2: CGPoint(x: rect.maxX - r * (1 - k), y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + r),
                   control1: CGPoint(x: rect.minX + r * (1 - k), y: rect.minY),
                   control2: CGPoint(x: rect.minX, y: rect.minY + r * (1 - k)))
        p.closeSubpath()
        return p
    }
}

/// The masked layer for the notch's content views. Empty areas fall through to `NotchShapeView`, which routes
/// clicks by rect and takes the first click.
final class NotchContentView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    /// The mask is not a sublayer, so nothing sizes it: keep it on the whole view.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.mask?.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
