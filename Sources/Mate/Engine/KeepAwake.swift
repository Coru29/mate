import AppKit
import Combine
import IOKit.pwr_mgt
import MateCore

/// "Mantener la Mac despierta mientras trabajan los agentes": holds Mate's power assertion while the store reports
/// working agents and the option is on. Follows the store's activity changes (which the activity expiry's one-shot
/// timer already drives) and the preference; nothing polls. Who else keeps the Mac awake (`caffeinate`, Amphetamine)
/// is re-read when powerd announces an assertion change, coalesced into one read per burst.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    /// Mate holds its assertion now.
    @Published private(set) var held = false
    /// Other processes keeping the Mac awake, as of the last `checkExternal()`.
    @Published private(set) var external: [AwakeHolder] = []
    /// The option's value, published so the panel follows it.
    @Published private(set) var enabled = NotchPrefs.keepAwake

    private var assertion: IOPMAssertionID?
    private var working: [ProviderID] = []
    private var subscriptions: [AnyCancellable] = []
    private var notifyTokens: [Int32] = []
    private var recheckTimer: Timer?
    /// Assertion changes come in bursts (an app takes and drops several at once): one read per this window.
    static let coalesce: TimeInterval = 1

    func start(store: UsageStore) {
        guard subscriptions.isEmpty else { return }
        working = store.workingProviders
        // @Published sends the new value before it is stored: use the value, not the store.
        store.$workingProviders.dropFirst().sink { [weak self] providers in
            self?.working = providers
            self?.apply()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let on = NotchPrefs.keepAwake
                    if on != self.enabled { self.enabled = on }
                    self.apply()
                }
            }.store(in: &subscriptions)
        apply()
        notifyTokens = PowerAssertions.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.assertionsChanged() }
        }
        checkExternal()
    }

    private func assertionsChanged() {
        guard recheckTimer == nil else { return }
        let t = Timer(timeInterval: Self.coalesce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recheckTimer = nil
                self?.checkExternal()
            }
        }
        t.tolerance = Self.coalesce * 0.2
        RunLoop.main.add(t, forMode: .common)
        recheckTimer = t
    }

    private func apply() {
        let hold = KeepAwakePolicy.shouldHold(enabled: enabled, activeProviders: working)
        if hold, assertion == nil {
            assertion = PowerAssertions.preventIdleSleep()
            if assertion != nil { Log.info("keep awake: holding (\(working.map(\.rawValue).joined(separator: ", ")))") }
        } else if !hold, let id = assertion {
            PowerAssertions.release(id)
            assertion = nil
            Log.info("keep awake: released")
        }
        let isHeld = assertion != nil
        if held != isHeld { held = isHeld }
    }

    /// Releases the assertion (quitting).
    func stop() {
        subscriptions.removeAll()
        PowerAssertions.stopObserving(notifyTokens)
        notifyTokens = []
        recheckTimer?.invalidate()
        recheckTimer = nil
        if let id = assertion { PowerAssertions.release(id) }
        assertion = nil
        held = false
    }

    /// Reads who else holds keep-awake assertions (at launch, after each burst of assertion changes, and when the
    /// panel opens). Mate's own assertion is never in the list, so its changes publish nothing.
    func checkExternal() {
        let holders = KeepAwakePolicy.externalHolders(PowerAssertions.processes(), ownPID: getpid())
        guard holders != external else { return }
        Log.info("keep awake: other holders \(holders.isEmpty ? "none" : holders.map { "\($0.name)(\($0.pid))" }.joined(separator: ", "))")
        external = holders
    }

    /// The panel's status line, nil when it shows nothing.
    var statusText: String? {
        if held { return String(localized: "Mac despierta · agentes trabajando") }
        if let first = external.first {
            var text: String
            if first.isCaffeinate {
                text = first.fromShell ? String(localized: "caffeinate activo desde una terminal")
                    : String(localized: "caffeinate activo")
            } else {
                text = String(localized: "\(first.name) mantiene la Mac despierta")
            }
            if external.count > 1 { text += " (+\(external.count - 1))" }
            return text
        }
        if enabled { return String(localized: "La Mac va a quedar despierta mientras trabajen los agentes") }
        return nil
    }

    /// The Mac is kept awake (the mate's ear shows, with its green dot): by Mate, or by another process at the last
    /// check.
    var showsDot: Bool { held || !external.isEmpty }

    /// `--dump`: the option, whether a Mate holds its assertion, and the other holders.
    static func dumpLine() -> String {
        let processes = PowerAssertions.processes()
        let holders = KeepAwakePolicy.externalHolders(processes, ownPID: getpid()).map { h in
            h.isCaffeinate ? "caffeinate (pid \(h.pid)\(h.fromShell ? ", from a shell" : ""))" : "\(h.name) (pid \(h.pid))"
        }
        return "keep-awake: option=\(NotchPrefs.keepAwake ? "on" : "off")  held-by-mate=\(PowerAssertions.mateHolds(in: processes) ? "yes" : "no")"
            + "  external=\(holders.isEmpty ? "none" : holders.joined(separator: ", "))"
    }
}
