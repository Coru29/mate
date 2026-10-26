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
        #expect(place(app: 2400, status: 3000) == .init(shift: 68, showsLeftEar: true)) // 2408 - 2340
        #expect(place(app: 2333, status: 3000) == .init(shift: 1, showsLeftEar: true))
    }

    // Step 2, crowded by the status items: slides left.
    @Test func slidesLeftOffTheStatusItems() {
        #expect(place(app: 1800, status: 2600) == .init(shift: -36, showsLeftEar: true)) // 2592 - 2628
    }

    // Step 2 at an exact fit: the gap is as wide as the shape (288 pt).
    @Test func exactFitShifts() {
        let p = place(app: 2392, status: 2696) // gap 2400...2688
        #expect(p == .init(shift: 60, showsLeftEar: true))
        // One point narrower: the left ear goes.
        #expect(place(app: 2393, status: 2696).showsLeftEar == false)
    }

    // Step 3: without the left ear, body and pill (256 pt) fit, centered or shifted.
    @Test func dropsTheLeftEarWhenTooNarrow() {
        // Gap 2364...2636 (272 pt): too narrow for 288, body + pill (2372...2628) fit where they are.
        #expect(place(app: 2356, status: 2644) == .init(shift: 0, showsLeftEar: false))
        // Gap 2450...2720 (270 pt): body + pill slide right to start at 2450.
        #expect(place(app: 2442, status: 2728) == .init(shift: 78, showsLeftEar: false))
        // Gap 2300...2560 (260 pt): crowded from the right, they slide left.
        #expect(place(app: 2292, status: 2568) == .init(shift: -68, showsLeftEar: false))
        // Exact fit for body + pill: 256 pt.
        #expect(place(app: 2442, status: 2714) == .init(shift: 78, showsLeftEar: false))
    }

    // Past step 3: the body is never dropped; body + pill go where they cover the app's menus least.
    @Test func tooNarrowKeepsBodyClearOfTheAppMenus() {
        // Gap 2508...2600: too narrow; starts right after the app's menus and covers status items.
        #expect(place(app: 2500, status: 2608) == .init(shift: 136, showsLeftEar: false))
        // Already clear of the app's menus (status items crowd it): stays where it is.
        #expect(place(app: 2300, status: 2500) == .init(shift: 0, showsLeftEar: false))
    }

    @Test func tooNarrowStaysOnScreen() {
        // The app's menus reach almost the right edge: flush with the screen's right edge (3432 - 256).
        #expect(place(app: 3300, status: 3400) == .init(shift: 3176 - 2372, showsLeftEar: false))
    }

    @Test func narrowScreen() {
        // A 1024 pt screen at 0: notch 412...612; the shape 380...668.
        let small = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let n = CGRect(x: 412, y: 736, width: 200, height: 32)
        #expect(place(app: 300, status: 800, screen: small, notch: n) == .centered)
        #expect(place(app: 500, status: 900, screen: small, notch: n) == .init(shift: 128, showsLeftEar: true))
        #expect(place(app: 700, status: 980, screen: small, notch: n) == .init(shift: 296, showsLeftEar: false))
        // Menus to 900 on a 1024 pt screen: as far right as the screen allows (1024 - 256).
        #expect(place(app: 900, status: 1000, screen: small, notch: n) == .init(shift: 356, showsLeftEar: false))
    }

    @Test func withoutEars() {
        // No pill, no ear: the body alone (200 pt) slides.
        #expect(place(app: 2400, status: 3000, left: nil, right: nil) == .init(shift: 36, showsLeftEar: false))
        // Mate ear but no pill: 232 pt.
        #expect(place(app: 2400, status: 3000, right: nil) == .init(shift: 68, showsLeftEar: true))
        // Tagged pill (80 pt) is wider: 312 pt, sliding left.
        #expect(place(app: 1800, status: 2600, right: 80) == .init(shift: -60, showsLeftEar: true))
    }
}
