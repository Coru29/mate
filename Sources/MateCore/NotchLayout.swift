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
    static let panelWidth: CGFloat = 380

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

    public static func pillRect(notch: CGRect) -> CGRect {
        CGRect(x: notch.maxX, y: notch.minY, width: pillWidth, height: notch.height)
    }

    public static func panelRect(notch: CGRect, contentHeight: CGFloat, screen: ScreenInfo) -> CGRect {
        let height = min(contentHeight, screen.visibleFrame.height)
        var x = notch.midX - panelWidth / 2
        x = min(x, screen.frame.maxX - panelWidth)
        x = max(x, screen.frame.minX)
        return CGRect(x: x, y: screen.frame.maxY - height, width: panelWidth, height: height)
    }
}
