import Foundation
import Testing
@testable import MateCore

@Suite struct KeepAwakeTests {
    @Test func holdsOnlyWithTheOptionOnAndAnAgentWorking() {
        #expect(KeepAwakePolicy.shouldHold(enabled: true, activeProviders: [.claude]))
        #expect(!KeepAwakePolicy.shouldHold(enabled: true, activeProviders: []))
        #expect(!KeepAwakePolicy.shouldHold(enabled: false, activeProviders: [.claude, .codex]))
        #expect(!KeepAwakePolicy.shouldHold(enabled: false, activeProviders: []))
    }

    func process(_ pid: Int32, _ name: String, _ path: String?, _ types: [String], level: Int = 255,
                 names: [String] = [], parent: String? = nil) -> AssertingProcess {
        AssertingProcess(pid: pid, name: name, path: path, parentName: parent,
                         assertions: types.enumerated().map { i, t in
                             .init(type: t, name: i < names.count ? names[i] : "x", level: level)
                         })
    }

    @Test func listsOtherKeepAwakeHolders() {
        let raw = [
            process(10, "caffeinate", "/usr/bin/caffeinate", ["PreventUserIdleSystemSleep"], parent: "zsh"),
            process(11, "Amphetamine", "/Applications/Amphetamine.app/Contents/MacOS/Amphetamine",
                    ["PreventUserIdleDisplaySleep"]),
            process(12, "Mate", "/Applications/Mate.app/Contents/MacOS/Mate", ["PreventUserIdleSystemSleep"],
                    names: [KeepAwakePolicy.assertionName]),
        ]
        let holders = KeepAwakePolicy.externalHolders(raw, ownPID: 999)
        #expect(holders == [AwakeHolder(pid: 10, name: "caffeinate", isCaffeinate: true, fromShell: true),
                            AwakeHolder(pid: 11, name: "Amphetamine", isCaffeinate: false, fromShell: false)])
    }

    @Test func skipsItselfOtherTypesReleasedAssertionsAndSystemDaemons() {
        let raw = [
            process(1, "Mate", nil, ["PreventUserIdleSystemSleep"]),
            process(2, "Music", "/System/Applications/Music.app/Contents/MacOS/Music", ["PreventUserIdleSystemSleep"]),
            process(3, "coreaudiod", "/usr/sbin/coreaudiod", ["PreventUserIdleSystemSleep"]),
            process(4, "powerd", "/System/Library/CoreServices/powerd.bundle/powerd", ["PreventSystemSleep"]),
            process(5, "Tool", "/usr/local/bin/tool", ["UserIsActive", "BackgroundTask"]),
            process(6, "Off", "/usr/local/bin/off", ["PreventSystemSleep"], level: 0),
            process(7, "sharingd", "/usr/libexec/sharingd", ["PreventUserIdleSystemSleep"]),
        ]
        #expect(KeepAwakePolicy.externalHolders(raw, ownPID: 1).isEmpty)
    }

    @Test func caffeinateFromAnAppIsNotFromAShell() {
        let raw = [process(20, "caffeinate", "/usr/bin/caffeinate", ["PreventSystemSleep"], parent: "Xcode"),
                   process(21, "caffeinate", "/usr/bin/caffeinate", ["PreventSystemSleep"], parent: "Terminal"),
                   process(22, "caffeinate", "/usr/bin/caffeinate", ["PreventSystemSleep"], parent: "-zsh")]
        #expect(KeepAwakePolicy.externalHolders(raw, ownPID: 1).map(\.fromShell) == [false, true, true])
    }
}

@Suite struct MateSipTests {
    @Test func delayIsBetweenTwelveAndTwentyFiveMinutes() {
        #expect(MateSip.delay(unit: 0) == 12 * 60)
        #expect(MateSip.delay(unit: 1) == 25 * 60)
        #expect(MateSip.delay(unit: 0.5) == 18.5 * 60)
        #expect(MateSip.delay(unit: -3) == 12 * 60)
        #expect(MateSip.delay(unit: 7) == 25 * 60)
    }

    @Test func armsOnlyWithTheEarShownAndAnAgentWorking() {
        #expect(MateSip.shouldArm(earShown: true, agentsActive: true, reduceMotion: false))
        #expect(!MateSip.shouldArm(earShown: true, agentsActive: false, reduceMotion: false))
        #expect(!MateSip.shouldArm(earShown: false, agentsActive: true, reduceMotion: false))
        #expect(!MateSip.shouldArm(earShown: true, agentsActive: true, reduceMotion: true))
    }

    @Test func playsOnlyIfAnAgentWorkedInTheIntervalAndTheMateIsVisible() {
        #expect(MateSip.shouldPlay(mateVisible: true, sawActivity: true, reduceMotion: false))
        #expect(!MateSip.shouldPlay(mateVisible: true, sawActivity: false, reduceMotion: false))
        #expect(!MateSip.shouldPlay(mateVisible: false, sawActivity: true, reduceMotion: false))
        #expect(!MateSip.shouldPlay(mateVisible: true, sawActivity: true, reduceMotion: true))
    }
}

@Suite struct MateEarTests {
    @Test func showsWithThePillOrWhileTheMacIsKeptAwake() {
        // With the pill, as before.
        #expect(MateEar.shown(showMate: true, menuBarVisible: true, pillShown: true, keptAwake: false))
        // caffeinate (or Mate's own assertion) running: the mate shows even with the pill hidden.
        #expect(MateEar.shown(showMate: true, menuBarVisible: true, pillShown: false, keptAwake: true))
        #expect(MateEar.shown(showMate: true, menuBarVisible: true, pillShown: true, keptAwake: true))
        // Neither: hidden.
        #expect(!MateEar.shown(showMate: true, menuBarVisible: true, pillShown: false, keptAwake: false))
    }

    @Test func thePreferenceAndAHiddenMenuBarWin() {
        #expect(!MateEar.shown(showMate: false, menuBarVisible: true, pillShown: true, keptAwake: true))
        // Another app in full screen: nothing over its menu bar area.
        #expect(!MateEar.shown(showMate: true, menuBarVisible: false, pillShown: false, keptAwake: true))
    }
}
