import CoreGraphics
import Testing
@testable import MateCore

/// An external 1920 pt display at x 1512: the fake notch is 2372...2572, the mate's ear 32 pt left of it, the pill
/// 56 pt right of it, so the full closed shape spans 2340...2628.
@Suite struct MenuBarAvoidTests {
    let screen = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    let notch = CGRect(x: 2372, y: 1048, width: 200, height: 32)

    func place(app: CGFloat, status: CGFloat, left: CGFloat? = 32, right: CGFloat? = 56,
               screen: CGRect? = nil, notch: CGRect? = nil) -> MenuBarAvoid.Placement {
        MenuBarAvoid.place(notch: notch ?? self.notch, leftEar: left, rightEar: right,
                           extents: .init(appMaxX: app, statusMinX: status), screen: screen ?? self.screen)
    }

    @Test func gapKeepsMarginsAndStaysOnScreen() {
        #expect(MenuBarAvoid.gap(.init(appMaxX: 1900, statusMinX: 3000), screen: screen) == 1908...2992)
        #expect(MenuBarAvoid.gap(.init(appMaxX: 1000, statusMinX: 4000), screen: screen) == 1512...3432)
        #expect(MenuBarAvoid.gap(.init(appMaxX: 2500, statusMinX: 2510), screen: screen) == nil)
    }

    // Step 1.
    @Test func centeredWhenItAlreadyFits() {
        #expect(place(app: 2000, status: 3000) == .centered)
        // Exactly touching both margins still counts as inside.
        #expect(place(app: 2332, status: 2636) == .centered)
    }

    // Step 2, crowded by the app's menus: slides right, just enough.
    @Test func slidesRightPastTheAppMenus() {
        #expect(place(app: 2400, status: 3000) == .init(shift: 68, ear: .left)) // 2408 - 2340
        #expect(place(app: 2333, status: 3000) == .init(shift: 1, ear: .left))
    }

    // Step 2, crowded by the status items: slides left.
    @Test func slidesLeftOffTheStatusItems() {
        #expect(place(app: 1800, status: 2600) == .init(shift: -36, ear: .left)) // 2592 - 2628
    }

    // Step 2 at an exact fit: the gap is as wide as the shape (288 pt).
    @Test func exactFitShifts() {
        let p = place(app: 2392, status: 2696) // gap 2400...2688
        #expect(p == .init(shift: 60, ear: .left))
        // One point narrower: the left ear goes.
        #expect(place(app: 2393, status: 2696).ear == .hidden)
    }

    // Step 3: without the left ear, body and pill (256 pt) fit, centered or shifted.
    @Test func dropsTheLeftEarWhenTooNarrow() {
        // Gap 2364...2636 (272 pt): too narrow for 288, body + pill (2372...2628) fit where they are.
        #expect(place(app: 2356, status: 2644) == .init(shift: 0, ear: .hidden))
        // Gap 2450...2720 (270 pt): body + pill slide right to start at 2450.
        #expect(place(app: 2442, status: 2728) == .init(shift: 78, ear: .hidden))
        // Gap 2300...2560 (260 pt): crowded from the right, they slide left.
        #expect(place(app: 2292, status: 2568) == .init(shift: -68, ear: .hidden))
        // Exact fit for body + pill: 256 pt.
        #expect(place(app: 2442, status: 2714) == .init(shift: 78, ear: .hidden))
    }

    // Past step 3: the body is never dropped; body + pill go where they cover the app's menus least.
    @Test func tooNarrowKeepsBodyClearOfTheAppMenus() {
        // Gap 2508...2600: too narrow; starts right after the app's menus and covers status items.
        #expect(place(app: 2500, status: 2608) == .init(shift: 136, ear: .hidden))
        // Already clear of the app's menus (status items crowd it): stays where it is.
        #expect(place(app: 2300, status: 2500) == .init(shift: 0, ear: .hidden))
    }

    @Test func tooNarrowStaysOnScreen() {
        // The app's menus reach almost the right edge: flush with the screen's right edge (3432 - 256).
        #expect(place(app: 3300, status: 3400) == .init(shift: 3176 - 2372, ear: .hidden))
    }

    @Test func narrowScreen() {
        // A 1024 pt screen at 0: notch 412...612; the shape 380...668.
        let small = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let n = CGRect(x: 412, y: 736, width: 200, height: 32)
        #expect(place(app: 300, status: 800, screen: small, notch: n) == .centered)
        #expect(place(app: 500, status: 900, screen: small, notch: n) == .init(shift: 128, ear: .left))
        #expect(place(app: 700, status: 980, screen: small, notch: n) == .init(shift: 296, ear: .hidden))
        // Menus to 900 on a 1024 pt screen: as far right as the screen allows (1024 - 256).
        #expect(place(app: 900, status: 1000, screen: small, notch: n) == .init(shift: 356, ear: .hidden))
    }

    @Test func withoutEars() {
        // No pill, no ear: the body alone (200 pt) slides.
        #expect(place(app: 2400, status: 3000, left: nil, right: nil) == .init(shift: 36, ear: .hidden))
        // Mate ear but no pill: 232 pt.
        #expect(place(app: 2400, status: 3000, right: nil) == .init(shift: 68, ear: .left))
        // Tagged pill (80 pt) is wider: 312 pt, sliding left.
        #expect(place(app: 1800, status: 2600, right: 80) == .init(shift: -60, ear: .left))
    }

    // Pill hidden: the ear on the right ([body][ear], 232 pt) is tried before dropping it. It is as wide as
    // [ear][body], and the shape slides, so the ear stays left whenever either fits.
    @Test func pillHiddenKeepsTheEarLeftBySliding() {
        // Exact fit for body + ear: gap 2400...2632.
        #expect(place(app: 2392, status: 2640, right: nil) == .init(shift: 60, ear: .left))
        // Crowded from the right too.
        #expect(place(app: 1800, status: 2500, right: nil) == .init(shift: -80, ear: .left)) // 2492 - 2572
    }

    @Test func pillHiddenDropsTheEarWhenNeitherSideFits() {
        // Gap 2400...2631 (231 pt): the body alone slides right.
        #expect(place(app: 2392, status: 2639, right: nil) == .init(shift: 28, ear: .hidden))
    }
}

/// The built-in display at 0...1512 and an external one at 1512...3432, both with their tops at window-server y 0.
@Suite struct MenuBarReadTests {
    let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    var screens: [CGRect] { [builtIn, external] }

    @Test func appMenusOnTheScreenTakeTheirMaxX() {
        let items = [CGRect(x: 1520, y: 0, width: 30, height: 24), CGRect(x: 1550, y: 0, width: 60, height: 24),
                     CGRect(x: 1610, y: 0, width: 50, height: 24)]
        #expect(MenuBarAvoid.appMaxX(items: items, screen: external, screens: screens) == 1660)
        #expect(MenuBarAvoid.appMaxX(items: [], screen: external, screens: screens) == nil)
    }

    @Test func appMenusOnAnotherScreenMapByLeftEdge() {
        // Shown on the built-in's menu bar up to x 400: on the external one they end 400 pt from its left edge.
        let items = [CGRect(x: 10, y: 0, width: 40, height: 33), CGRect(x: 50, y: 0, width: 350, height: 33)]
        #expect(MenuBarAvoid.appMaxX(items: items, screen: external, screens: screens) == 1912)
    }

    @Test func itemsBelowTheMenuBarAreIgnored() {
        let items = [CGRect(x: 1520, y: 0, width: 30, height: 24), CGRect(x: 2000, y: 300, width: 80, height: 24),
                     CGRect(x: 2100, y: 0, width: 0, height: 24)]
        #expect(MenuBarAvoid.appMaxX(items: items, screen: external, screens: screens) == 1550)
    }

    @Test func statusItemsTakeTheirMinX() {
        let windows = [CGRect(x: 3300, y: 0, width: 40, height: 24), CGRect(x: 3200, y: 0, width: 100, height: 24),
                       CGRect(x: 970, y: 0, width: 38, height: 33)]
        #expect(MenuBarAvoid.statusMinX(windows: windows, screen: external, screens: screens) == 3200)
        // Only on the built-in (970, 542 pt from its right edge): mapped onto the external's right edge.
        #expect(MenuBarAvoid.statusMinX(windows: [windows[2]], screen: external, screens: screens) == 2890)
        // None at all: the screen's right edge.
        #expect(MenuBarAvoid.statusMinX(windows: [], screen: external, screens: screens) == 3432)
    }
}

/// A real notch (built-in 1512 pt display, notch 665...850, status items from 967): it never moves; the mate's ear
/// (32 pt, 633...665) shows left of it while the app's menus end before it, else right of it (850...882) when the
/// pill is hidden and the status items leave room.
@Suite struct RealNotchPlacementTests {
    let real = CGRect(x: 665, y: 950, width: 185, height: 32)

    func place(app: CGFloat, status: CGFloat = 967, left: CGFloat? = 32, pill: Bool = true) -> MenuBarAvoid.Placement {
        MenuBarAvoid.placeOnRealNotch(notch: real, leftEar: left, pill: pill,
                                      extents: .init(appMaxX: app, statusMinX: status))
    }

    @Test func keepsTheEarLeftWhenTheMenusEndBeforeIt() {
        #expect(place(app: 500) == .init(shift: 0, ear: .left))
        #expect(place(app: 500, pill: false) == .init(shift: 0, ear: .left))
        // Menus ending exactly where the ear starts still fit.
        #expect(place(app: 633).ear == .left)
        #expect(place(app: 633, pill: false).ear == .left)
    }

    @Test func dropsTheEarUnderTheMenusWhenThePillShows() {
        #expect(place(app: 634) == .init(shift: 0, ear: .hidden))
        #expect(place(app: 900, left: nil) == .centered)
    }

    @Test func movesTheEarRightWhenThePillIsHidden() {
        #expect(place(app: 634, pill: false) == .init(shift: 0, ear: .right))
        // The wider music ear (48 pt, 850...898) too.
        #expect(place(app: 700, left: 48, pill: false) == .init(shift: 0, ear: .right))
    }

    @Test func dropsTheEarWhenTheStatusItemsLeaveNoRoomOnTheRight() {
        // The ear would end at 882; status items need it to end 8 pt before them.
        #expect(place(app: 634, status: 890, pill: false).ear == .right)
        #expect(place(app: 634, status: 889, pill: false) == .init(shift: 0, ear: .hidden))
        #expect(place(app: 700, status: 905, left: 48, pill: false).ear == .hidden)
    }
}
