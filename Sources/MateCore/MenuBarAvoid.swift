import CoreGraphics

/// Where the closed shape goes on a display whose notch Mate draws itself: macOS moves the menus around a real
/// notch, not around Mate's, so the shape slides (and drops its left ear) to stay off the frontmost app's menus.
public enum MenuBarAvoid {
    /// Room kept between the shape and the app's menus or the status items.
    public static let margin: CGFloat = 8

    /// What the menu bar holds on the notch's screen, in Cocoa x coordinates.
    public struct Extents: Equatable, Sendable {
        /// Right end of the frontmost app's menus.
        public var appMaxX: CGFloat
        /// Left end of the status items / menu extras.
        public var statusMinX: CGFloat

        public init(appMaxX: CGFloat, statusMinX: CGFloat) {
            self.appMaxX = appMaxX
            self.statusMinX = statusMinX
        }
    }

    /// Where the mate's (or the music's) ear goes: left of the notch as always, right of it in the pill's place
    /// while the pill is hidden, or not drawn.
    public enum EarSide: Equatable, Sendable {
        case left, right, hidden
    }

    public struct Placement: Equatable, Sendable {
        /// Horizontal offset of the whole closed shape from its centered spot.
        public var shift: CGFloat
        /// Which side of the notch the left ear's content (mate or music) is drawn on.
        public var ear: EarSide

        public init(shift: CGFloat, ear: EarSide) {
            self.shift = shift
            self.ear = ear
        }

        /// As today: centered, nothing dropped.
        public static let centered = Placement(shift: 0, ear: .left)
    }

    /// The free stretch of the menu bar between the app's menus and the status items, margins included, inside the
    /// screen.
    public static func gap(_ e: Extents, screen: CGRect) -> ClosedRange<CGFloat>? {
        let lo = max(e.appMaxX + margin, screen.minX)
        let hi = min(e.statusMinX - margin, screen.maxX)
        return lo <= hi ? lo...hi : nil
    }

    /// The closed shape's placement. `notch` is the centered fake notch (the body, always drawn), `leftEar` the
    /// left ear's width (nil when it shows nothing) and `rightEar` the pill's width (nil when hidden).
    /// 1. Centered when that already sits in the gap. 2. Else the smallest shift that fits it. 3. Too wide and the
    /// pill hidden: the ear right of the body, 1–2 again (as wide as the left one, so it only fits when that does
    /// too; kept so both notch kinds follow the same rule). 4. Without the ear, 1–2 again. Still too wide: body and right ear go where they cover the app's menus least,
    /// moving as little as possible and staying on the screen.
    public static func place(notch: CGRect, leftEar: CGFloat?, rightEar: CGFloat?, extents: Extents,
                             screen: CGRect) -> Placement {
        let right = notch.maxX + (rightEar ?? 0)
        let gap = gap(extents, screen: screen)
        if let leftEar, let gap, let s = fit(minX: notch.minX - leftEar, maxX: right, in: gap) {
            return Placement(shift: s, ear: .left)
        }
        if rightEar == nil, let leftEar, let gap, let s = fit(minX: notch.minX, maxX: notch.maxX + leftEar, in: gap) {
            return Placement(shift: s, ear: .right)
        }
        if let gap, let s = fit(minX: notch.minX, maxX: right, in: gap) {
            return Placement(shift: s, ear: .hidden)
        }
        // Clear of the menus if the screen allows it, else flush with the screen's right edge.
        let width = right - notch.minX
        var x = max(notch.minX, extents.appMaxX + margin)
        x = min(x, screen.maxX - width)
        x = max(x, screen.minX)
        return Placement(shift: x - notch.minX, ear: .hidden)
    }

    /// A real notch can't move, and macOS keeps the app's menus left of it but not left of the mate's ear: the ear
    /// is drawn left only when the menus end before it. No margin there: a menu item's rect already carries its own
    /// padding around the title. Otherwise, while the pill is hidden, the ear goes right of the notch if it ends
    /// `margin` before the status items; else it is dropped. The pill on the right always stays.
    public static func placeOnRealNotch(notch: CGRect, leftEar: CGFloat?, pill: Bool, extents: Extents) -> Placement {
        guard let leftEar else { return .centered }
        if notch.minX - leftEar >= extents.appMaxX { return .centered }
        if !pill && notch.maxX + leftEar <= extents.statusMinX - margin { return Placement(shift: 0, ear: .right) }
        return Placement(shift: 0, ear: .hidden)
    }

    /// The smallest shift that puts minX...maxX inside `gap`; nil when it is wider than the gap.
    private static func fit(minX: CGFloat, maxX: CGFloat, in gap: ClosedRange<CGFloat>) -> CGFloat? {
        guard maxX - minX <= gap.upperBound - gap.lowerBound else { return nil }
        if minX < gap.lowerBound { return gap.lowerBound - minX }
        if maxX > gap.upperBound { return gap.upperBound - maxX }
        return 0
    }

    // MARK: Reading the menu bar

    /// How far below a screen's top edge a menu-bar item may start.
    static let barDepth: CGFloat = 60

    /// Whether `item` sits in `screen`'s menu bar. Both in window-server coordinates (origin top-left of the main
    /// display, y down), where a screen's menu bar is at its minY.
    static func inMenuBar(_ item: CGRect, of screen: CGRect) -> Bool {
        item.width > 0 && item.minY >= screen.minY - 1 && item.minY < screen.minY + barDepth
            && item.midX >= screen.minX && item.midX < screen.maxX
    }

    /// Right end of the app's menus on `screen`, from the menu bar items' rects (Accessibility, window-server
    /// coordinates; x is the same as Cocoa's). Menus shown on another display's menu bar are mapped onto this one by
    /// their distance from that display's left edge (an inactive menu bar shows the same menus). Nil without items.
    public static func appMaxX(items: [CGRect], screen: CGRect, screens: [CGRect]) -> CGFloat? {
        let here = items.filter { inMenuBar($0, of: screen) }
        if let x = here.map(\.maxX).max() { return x }
        let offsets = items.compactMap { item in
            screens.first { inMenuBar(item, of: $0) }.map { item.maxX - $0.minX }
        }
        return offsets.max().map { screen.minX + $0 }
    }

    /// Left end of the status items on `screen`, from the status-layer windows' rects (window-server coordinates).
    /// Items shown only on another display are mapped by their distance from its right edge; none at all: the
    /// screen's right edge.
    public static func statusMinX(windows: [CGRect], screen: CGRect, screens: [CGRect]) -> CGFloat {
        let here = windows.filter { inMenuBar($0, of: screen) }
        if let x = here.map(\.minX).min() { return x }
        let offsets = windows.compactMap { w in
            screens.first { inMenuBar(w, of: $0) }.map { $0.maxX - w.minX }
        }
        return offsets.max().map { screen.maxX - $0 } ?? screen.maxX
    }
}
