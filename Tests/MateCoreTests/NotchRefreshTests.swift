import Foundation
import Testing
@testable import MateCore

@Suite struct NotchRefreshTests {
    @Test func aggregatesOnlyMatterWhileThePanelIsOpen() {
        #expect(!NotchRefresh.needed(for: .aggregates, panelOpen: false))
        #expect(NotchRefresh.needed(for: .aggregates, panelOpen: true))
    }

    @Test func whatThePillShowsAlwaysMatters() {
        for c in [NotchRefresh.Change.accounts, .snapshots, .activeProvider, .selection, .paused] {
            #expect(NotchRefresh.needed(for: c, panelOpen: false))
        }
    }

    @Test func logWatchLatencyFollowsThePanel() {
        #expect(NotchRefresh.logLatency(panelOpen: true) == 1)
        #expect(NotchRefresh.logLatency(panelOpen: false) == 5)
    }
}
