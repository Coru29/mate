import Testing
@testable import MateCore

struct AppVersionTests {
    @Test func parsesTagsWithOrWithoutV() {
        #expect(AppVersion("v1.2.3")?.parts == [1, 2, 3])
        #expect(AppVersion("1.2.3")?.parts == [1, 2, 3])
        #expect(AppVersion(" 2.0 ")?.parts == [2, 0])
    }

    @Test func rejectsGarbage() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("1..2") == nil)
    }

    @Test func comparesNumericallyNotAlphabetically() {
        #expect(AppVersion("1.10.0")! > AppVersion("1.9.9")!)
        #expect(AppVersion("0.10.0")! > AppVersion("0.9.1")!)
        #expect(AppVersion("1.0.0")! > AppVersion("0.99.99")!)
    }

    @Test func missingComponentsCountAsZero() {
        #expect(AppVersion("1.0")! == AppVersion("1.0.0")!)
        #expect(!(AppVersion("1.0")! < AppVersion("1.0.0")!))
    }

    @Test func preReleaseSuffixIsIgnored() {
        #expect(AppVersion("v0.2.0-beta.1")?.parts == [0, 2, 0])
    }

    @Test func zeroMajorIsPreStable() {
        #expect(AppVersion("0.1.0")!.isPreStable)
        #expect(!AppVersion("1.0.0")!.isPreStable)
    }
}
