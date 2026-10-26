import CoreGraphics
import Testing
@testable import MateCore

@Suite struct NotchLayoutTests {
    func macbook(id: UInt32 = 1, builtIn: Bool = true, menuBar: Bool = true) -> ScreenInfo {
        ScreenInfo(id: id, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                   visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), safeTop: 32,
                   leftAux: CGRect(x: 0, y: 950, width: 662, height: 32),
                   rightAux: CGRect(x: 850, y: 950, width: 662, height: 32),
                   builtIn: builtIn, hasMenuBar: menuBar)
    }

    func external(id: UInt32 = 2, menuBar: Bool = false) -> ScreenInfo {
        ScreenInfo(id: id, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                   visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055), safeTop: 0,
                   leftAux: nil, rightAux: nil, builtIn: false, hasMenuBar: menuBar)
    }

    @Test func notchBetweenAuxiliaryAreas() {
        let n = NotchLayout.notchRect(on: macbook())
        #expect(n.rect == CGRect(x: 662, y: 950, width: 188, height: 32))
        #expect(!n.isFake)
    }

    @Test func screenWithoutNotchGetsFakeNotch() {
        let n = NotchLayout.notchRect(on: external())
        #expect(n.rect == CGRect(x: 1512 + 960 - 100, y: 1080 - 32, width: 200, height: 32))
        #expect(n.isFake)
    }

    @Test func pickBuiltInWhenPresent() {
        let screens = [external(menuBar: true), macbook(menuBar: false)]
        #expect(NotchLayout.pickScreen(screens, choice: .builtIn, mouseScreen: nil)?.id == 1)
    }

    @Test func pickBuiltInFallsBackToMain() {
        let screens = [external(id: 2, menuBar: false), external(id: 3, menuBar: true)]
        #expect(NotchLayout.pickScreen(screens, choice: .builtIn, mouseScreen: nil)?.id == 3)
        #expect(NotchLayout.pickScreen(screens, choice: .main, mouseScreen: nil)?.id == 3)
        #expect(NotchLayout.pickScreen(screens, choice: .mouse, mouseScreen: 2)?.id == 2)
        #expect(NotchLayout.pickScreen(screens, choice: .mouse, mouseScreen: 99)?.id == 3)
        #expect(NotchLayout.pickScreen([], choice: .main, mouseScreen: nil) == nil)
    }

    @Test func pillRightOfNotch() {
        let n = NotchLayout.notchRect(on: macbook()).rect
        #expect(NotchLayout.pillRect(notch: n) == CGRect(x: 850, y: 950, width: 56, height: 32))
    }

    /// A cursor slammed against the top of the screen sits at y == screen.frame.maxY (Cocoa's y is
    /// mainHeight - CG y, and CG's top row is 0), which half-open `CGRect.contains` puts outside a window that
    /// touches the top.
    @Test func pointOnTopEdgeIsInside() {
        let panel = CGRect(x: 770, y: 783, width: 380, height: 297) // top at 1080, the screen's top
        #expect(!panel.contains(CGPoint(x: 960, y: 1080))) // the bug: half-open
        #expect(NotchLayout.hoverContains(panel, CGPoint(x: 960, y: 1080)))
        // The top corners of a panel clamped to the screen's edges count too.
        #expect(NotchLayout.hoverContains(panel, CGPoint(x: 770, y: 1080)))
        #expect(NotchLayout.hoverContains(panel, CGPoint(x: 1150, y: 1080)))
        #expect(NotchLayout.hoverContains(panel, CGPoint(x: 960, y: 900)))
    }

    @Test func pointJustBelowBottomIsOutside() {
        let panel = CGRect(x: 770, y: 783, width: 380, height: 297)
        #expect(!NotchLayout.hoverContains(panel, CGPoint(x: 960, y: 782.5)))
        #expect(!NotchLayout.hoverContains(panel, CGPoint(x: 769.5, y: 1000)))
        #expect(!NotchLayout.hoverContains(panel, CGPoint(x: 1150.5, y: 1000)))
        #expect(!NotchLayout.hoverContains(.null, CGPoint(x: 960, y: 1080)))
    }

    @Test func mateEarLeftOfNotch() {
        let n = NotchLayout.notchRect(on: macbook()).rect
        // 7 pt of padding each side of an 18 pt mate, like the ring's padding on the right.
        #expect(NotchLayout.mateEarWidth == 32)
        #expect(NotchLayout.mateRect(notch: n) == CGRect(x: 630, y: 950, width: 32, height: 32))
        // The 24 pt sprite cell is centered in the ear, and vertically in the notch.
        #expect(NotchLayout.mateIconRect(notch: n) == CGRect(x: 634, y: 954, width: 24, height: 24))
        // Fake notch too.
        let f = NotchLayout.notchRect(on: external()).rect
        #expect(NotchLayout.mateRect(notch: f) == CGRect(x: f.minX - 32, y: f.minY, width: 32, height: 32))
    }

    @Test func mateEarRightOfNotch() {
        let n = NotchLayout.notchRect(on: macbook()).rect
        // In the pill's place: same width, starting at the notch's right edge, the sprite centered in it.
        #expect(NotchLayout.mateRect(notch: n, onRight: true) == CGRect(x: n.maxX, y: 950, width: 32, height: 32))
        #expect(NotchLayout.mateIconRect(notch: n, onRight: true) == CGRect(x: n.maxX + 4, y: 954, width: 24, height: 24))
        #expect(NotchLayout.leftEarRect(notch: n, content: .mate, onRight: true)
            == NotchLayout.mateRect(notch: n, onRight: true))
    }

    @Test func taggedPillIsWider() {
        let n = NotchLayout.notchRect(on: macbook()).rect
        #expect(NotchLayout.pillRect(notch: n, tagged: true) == CGRect(x: 850, y: 950, width: 80, height: 32))
    }

    @Test func panelCenteredAndClampedToScreen() {
        let m = macbook()
        let n = NotchLayout.notchRect(on: m).rect
        #expect(NotchLayout.panelRect(notch: n, contentHeight: 400, screen: m) == CGRect(x: 566, y: 582, width: 380, height: 400))
        // Taller than the visible frame: clamped, top stays at the screen top.
        #expect(NotchLayout.panelRect(notch: n, contentHeight: 5000, screen: m) == CGRect(x: 566, y: 32, width: 380, height: 950))
        // Notch near the left edge: panel shifts to stay inside.
        let edge = ScreenInfo(id: 5, frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                              visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 780), safeTop: 0,
                              leftAux: nil, rightAux: nil, builtIn: false, hasMenuBar: true)
        let p = NotchLayout.panelRect(notch: CGRect(x: 10, y: 768, width: 200, height: 32), contentHeight: 300, screen: edge)
        #expect(p == CGRect(x: 0, y: 500, width: 380, height: 300))
    }
}
