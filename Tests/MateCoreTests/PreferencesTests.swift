import Testing
import Foundation
@testable import MateCore

@Test func defaultsHaveEveryKey() {
    for key in PrefKey.allCases {
        #expect(Preferences.defaults[key.rawValue] != nil, "missing default for \(key.rawValue)")
    }
}
