import CoreGraphics

/// A display as the layout sees it, in Cocoa coordinates (origin bottom-left, y up).
public struct ScreenInfo: Equatable, Sendable {
    public var id: UInt32
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var safeTop: CGFloat
    public var leftAux: CGRect?
    public var rightAux: CGRect?
    public var builtIn: Bool
    public var hasMenuBar: Bool

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect, safeTop: CGFloat, leftAux: CGRect?,
                rightAux: CGRect?, builtIn: Bool, hasMenuBar: Bool) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeTop = safeTop
        self.leftAux = leftAux
        self.rightAux = rightAux
        self.builtIn = builtIn
        self.hasMenuBar = hasMenuBar
    }
}

public enum ScreenChoice: String, Sendable {
    case builtIn, main, mouse
}

public enum NotchLayout {
    static let fakeNotchSize = CGSize(width: 200, height: 32)
    static let pillWidth: CGFloat = 56
    /// Extra room for the "sem" tag when the pill shows a window other than the session.
    static let pillTagWidth: CGFloat = 24
    static let panelWidth: CGFloat = 380
    /// The mate's ear left of the notch: an 18 pt mate with the ring's 7 pt padding on each side.
    public static let mateEarWidth: CGFloat = 32
    /// The mate's sprite cell (the gourd fills about 18 pt of it; the thermos pours in from its top).
    public static let mateIconSize: CGFloat = 24
    /// The music ear: 7 pt padding, the 18 pt album art, a 6 pt gap, 9 pt of equalizer bars, 8 pt padding.
    public static let musicEarWidth: CGFloat = 48
    public static let musicArtSize: CGFloat = 18
    public static let musicBarsSize = CGSize(width: 9, height: 12)

    public static func pickScreen(_ screens: [ScreenInfo], choice: ScreenChoice, mouseScreen: UInt32?) -> ScreenInfo? {
        let main = screens.first(where: \.hasMenuBar) ?? screens.first
        switch choice {
        case .builtIn: return screens.first(where: \.builtIn) ?? main
        case .main: return main
        case .mouse: return screens.first(where: { $0.id == mouseScreen }) ?? main
        }
    }

    public static func notchRect(on s: ScreenInfo) -> (rect: CGRect, isFake: Bool) {
        if let left = s.leftAux, let right = s.rightAux, s.safeTop > 0 {
            let rect = CGRect(x: left.maxX, y: s.frame.maxY - s.safeTop, width: right.minX - left.maxX, height: s.safeTop)
            return (rect, false)
        }
        let size = fakeNotchSize
        return (CGRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height,
                       width: size.width, height: size.height), true)
    }

    /// Whether the cursor at `p` is over `rect`, edges included. `CGRect.contains` is half-open and leaves out the
    /// max edges, but a cursor pinned against the top of the screen sits exactly at y == screen.frame.maxY, the top
    /// edge of every notch window: with `contains` it reads as outside and the panel closes under it.
    public static func hoverContains(_ rect: CGRect, _ p: CGPoint) -> Bool {
        !rect.isNull && p.x >= rect.minX && p.x <= rect.maxX && p.y >= rect.minY && p.y <= rect.maxY
    }

    public static func pillRect(notch: CGRect, tagged: Bool = false) -> CGRect {
        CGRect(x: notch.maxX, y: notch.minY, width: pillWidth + (tagged ? pillTagWidth : 0), height: notch.height)
    }

    /// The mate's ear, the mirror of the pill left of the notch.
    public static func mateRect(notch: CGRect) -> CGRect {
        CGRect(x: notch.minX - mateEarWidth, y: notch.minY, width: mateEarWidth, height: notch.height)
    }

    /// The sprite cell, centered in the mate's ear.
    public static func mateIconRect(notch: CGRect) -> CGRect {
        let ear = mateRect(notch: notch)
        return CGRect(x: ear.midX - mateIconSize / 2, y: ear.midY - mateIconSize / 2, width: mateIconSize,
                      height: mateIconSize)
    }

    /// The music ear (album art and equalizer bars while music plays), in place of the mate's ear.
    public static func musicRect(notch: CGRect) -> CGRect {
        CGRect(x: notch.minX - musicEarWidth, y: notch.minY, width: musicEarWidth, height: notch.height)
    }

    public static func musicArtRect(notch: CGRect) -> CGRect {
        let ear = musicRect(notch: notch)
        return CGRect(x: ear.minX + 7, y: ear.midY - musicArtSize / 2, width: musicArtSize, height: musicArtSize)
    }

    public static func musicBarsRect(notch: CGRect) -> CGRect {
        let art = musicArtRect(notch: notch)
        return CGRect(x: art.maxX + 6, y: art.midY - musicBarsSize.height / 2, width: musicBarsSize.width,
                      height: musicBarsSize.height)
    }

    /// The left ear for what it shows; nil when it shows nothing.
    public static func leftEarRect(notch: CGRect, content: LeftEarContent) -> CGRect? {
        switch content {
        case .none: nil
        case .mate: mateRect(notch: notch)
        case .music: musicRect(notch: notch)
        }
    }

    public static func panelRect(notch: CGRect, contentHeight: CGFloat, screen: ScreenInfo) -> CGRect {
        let height = min(contentHeight, screen.visibleFrame.height)
        var x = notch.midX - panelWidth / 2
        x = min(x, screen.frame.maxX - panelWidth)
        x = max(x, screen.frame.minX)
        return CGRect(x: x, y: screen.frame.maxY - height, width: panelWidth, height: height)
    }
}
