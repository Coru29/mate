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
        isFloatingPanel = true
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

/// The window's content: the black shape (notch, pill ear, panel or alert) as one `CAShapeLayer`, plus hover and
/// click handling for the whole window. Hover comes from an `NSTrackingArea`, never from a global monitor.
final class NotchShapeView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onClick: (NSEvent) -> Void = { _ in }
    var onRightClick: (NSEvent) -> Void = { _ in }

    private let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Barely there, so the window server routes the mouse to the whole frame even where nothing is drawn
        // (the hover strip over a hidden fake notch).
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.004).cgColor
        shape.fillColor = NSColor.black.cgColor
        layer?.addSublayer(shape)
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

    /// Sets the black shape; `animated` uses a spring and calls `completion` when it settles.
    func setShape(_ path: CGPath, animated: Bool, completion: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated, let from = shape.presentation()?.path ?? shape.path {
            let spring = CASpringAnimation(keyPath: "path")
            spring.fromValue = from
            spring.toValue = path
            spring.mass = 1
            spring.stiffness = 260
            spring.damping = 26
            spring.duration = spring.settlingDuration
            CATransaction.setCompletionBlock(completion)
            shape.add(spring, forKey: "path")
        } else {
            shape.removeAnimation(forKey: "path")
            CATransaction.setCompletionBlock(completion)
        }
        shape.path = path
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
