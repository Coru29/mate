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
