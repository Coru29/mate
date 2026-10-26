import Foundation

/// A process holding power assertions, as `IOPMCopyAssertionsByProcess` reports it (plus what the app looks up about
/// the process: its executable path and its parent's name).
public struct AssertingProcess: Equatable, Sendable {
    public struct Assertion: Equatable, Sendable {
        public var type: String
        public var name: String
        /// 0: released (kIOPMAssertionLevelOff).
        public var level: Int

        public init(type: String, name: String, level: Int) {
            self.type = type
            self.name = name
            self.level = level
        }
    }

    public var pid: Int32
    public var name: String
    public var path: String?
    public var parentName: String?
    public var assertions: [Assertion]

    public init(pid: Int32, name: String, path: String?, parentName: String?, assertions: [Assertion]) {
        self.pid = pid
        self.name = name
        self.path = path
        self.parentName = parentName
        self.assertions = assertions
    }
}

/// Another process keeping the Mac awake (`caffeinate`, Amphetamine…).
public struct AwakeHolder: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var isCaffeinate: Bool
    /// `caffeinate` started from a shell or a terminal app.
    public var fromShell: Bool

    public init(pid: Int32, name: String, isCaffeinate: Bool, fromShell: Bool) {
        self.pid = pid
        self.name = name
        self.isCaffeinate = isCaffeinate
        self.fromShell = fromShell
    }
}

/// "Mantener la Mac despierta mientras trabajan los agentes": when Mate holds its own assertion, and who else holds one.
public enum KeepAwakePolicy {
    /// The name of Mate's own assertion (shown by `pmset -g assertions`).
    public static let assertionName = "Mate: agents working"
    /// Assertion types that keep the Mac (or its display) awake.
    public static let keepAwakeTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventUserIdleDisplaySleep",
    ]
    /// macOS's own daemons and apps (audio playback, sharing, backups) hold these too; they are not "keeping the Mac
    /// awake" in the sense the panel means. `caffeinate` lives in /usr/bin and is kept.
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/"]
    static let shells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "login", "tmux", "screen",
        "Terminal", "iTerm2", "Ghostty", "ghostty", "Warp", "stable", "alacritty", "kitty", "WezTerm", "wezterm-gui",
    ]

    public static func shouldHold(enabled: Bool, activeProviders: [ProviderID]) -> Bool {
        enabled && !activeProviders.isEmpty
    }

    /// Processes other than Mate holding an active keep-awake assertion, in the given order.
    public static func externalHolders(_ processes: [AssertingProcess], ownPID: Int32) -> [AwakeHolder] {
        processes.compactMap { p in
            guard p.pid != ownPID else { return nil }
            let active = p.assertions.filter { $0.level != 0 && keepAwakeTypes.contains($0.type) }
            guard !active.isEmpty, !active.contains(where: { $0.name == assertionName }) else { return nil }
            if let path = p.path, systemPrefixes.contains(where: path.hasPrefix) { return nil }
            let caffeinate = p.name == "caffeinate"
            let parent = p.parentName.map { $0.hasPrefix("-") ? String($0.dropFirst()) : $0 }
            return AwakeHolder(pid: p.pid, name: p.name, isCaffeinate: caffeinate,
                               fromShell: caffeinate && parent.map(shells.contains) == true)
        }
    }
}

/// When the mate left of the notch takes a sip: once in a while (12 to 25 minutes) while agents work, never with
/// Reduce Motion, nothing scheduled while idle.
public enum MateSip {
    public static let minDelay: TimeInterval = 12 * 60
    public static let maxDelay: TimeInterval = 25 * 60

    /// `unit` is a random number in 0...1.
    public static func delay(unit: Double) -> TimeInterval {
        minDelay + (maxDelay - minDelay) * min(max(unit, 0), 1)
    }

    public static func shouldArm(earShown: Bool, agentsActive: Bool, reduceMotion: Bool) -> Bool {
        earShown && agentsActive && !reduceMotion
    }

    public static func shouldPlay(mateVisible: Bool, sawActivity: Bool, reduceMotion: Bool) -> Bool {
        mateVisible && sawActivity && !reduceMotion
    }
}

/// When the mate's ear shows left of the notch: with the pill, and also whenever the Mac is kept awake (by Mate or by
/// another process such as `caffeinate`), even with the pill hidden. Never over another app's full-screen menu bar.
public enum MateEar {
    public static func shown(showMate: Bool, menuBarVisible: Bool, pillShown: Bool, keptAwake: Bool) -> Bool {
        showMate && menuBarVisible && (pillShown || keptAwake)
    }
}
