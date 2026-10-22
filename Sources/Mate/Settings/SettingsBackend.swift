import AppKit
import SwiftUI
import MateCore

/// What the settings window and the welcome guide read and change: the preferences (re-published whenever the
/// defaults change, from here or anywhere else), the login item and Grok's key. In `--fake` runs the login item and
/// the Grok key live in memory, so a test run never registers a login item or writes the keychain.
@MainActor
final class SettingsBackend: ObservableObject {
    let store: UsageStore
    let fake: Bool
    private var observer: NSObjectProtocol?
    private var fakeLaunchAtLogin = false
    private var fakeGrokTeam: String?

    init(store: UsageStore, fake: Bool) {
        self.store = store
        self.fake = fake
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Preferences

    private var defaults: UserDefaults { .mate }

    func value<T>(_ key: PrefKey) -> T? {
        defaults.object(forKey: key.rawValue) as? T ?? Preferences.defaults[key.rawValue] as? T
    }

    func set(_ value: Any, _ key: PrefKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    func binding<T>(_ key: PrefKey, default fallback: T) -> Binding<T> {
        Binding(get: { [unowned self] in value(key) ?? fallback }, set: { [unowned self] in set($0, key) })
    }

    /// "system", "es" or "en". macOS picks the app's language at launch from `AppleLanguages` in the app's own
    /// domain, so the change applies the next time Mate opens.
    var language: String {
        get { value(.language) ?? "system" }
        set {
            set(newValue, .language)
            if let langs = Preferences.appleLanguages(for: newValue) {
                defaults.set(langs, forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
        }
    }

    // MARK: Providers

    var providerOrder: [ProviderID] { Preferences.providerOrder(value(.providerOrder) ?? []) }

    func moveProviders(from source: IndexSet, to destination: Int) {
        var order = providerOrder
        order.move(fromOffsets: source, toOffset: destination)
        set(order.map(\.rawValue), .providerOrder)
    }

    func isEnabled(_ p: ProviderID) -> Bool { !(value(.disabledProviders) ?? [String]()).contains(p.rawValue) }

    /// A provider turned back on is read and fetched right away.
    func setEnabled(_ p: ProviderID, _ on: Bool) {
        var disabled: [String] = value(.disabledProviders) ?? []
        disabled.removeAll { $0 == p.rawValue }
        if !on { disabled.append(p.rawValue) }
        set(disabled, .disabledProviders)
        if on { Task { await store.reloadProvider(p) } }
    }

    func alertsOn(_ p: ProviderID) -> Bool { !(value(.alertsDisabledProviders) ?? [String]()).contains(p.rawValue) }

    func setAlerts(_ p: ProviderID, _ on: Bool) {
        var muted: [String] = value(.alertsDisabledProviders) ?? []
        muted.removeAll { $0 == p.rawValue }
        if !on { muted.append(p.rawValue) }
        set(muted, .alertsDisabledProviders)
    }

    var thresholds: [Int] { AlertThresholds.normalize(value(.alertThresholds) ?? []) }

    func setThresholds(_ values: [Int]) { set(AlertThresholds.normalize(values), .alertThresholds) }

    // MARK: Launch at login

    var launchAtLogin: Bool { fake ? fakeLaunchAtLogin : LoginItem.isEnabled }
    var launchAtLoginNeedsApproval: Bool { fake ? false : LoginItem.needsApproval }

    func setLaunchAtLogin(_ on: Bool) {
        defer { objectWillChange.send() }
        if fake { fakeLaunchAtLogin = on; return }
        do { try LoginItem.set(on) } catch { Log.error("login item: \(error)") }
    }

    func openLoginItemsSettings() { LoginItem.openApprovalSettings() }

    // MARK: Grok

    /// The team whose management key is stored (from the keychain item's attributes; the key is never read here).
    var grokTeamID: String? { fake ? fakeGrokTeam : GrokProvider.storedTeamID }

    var grokBudget: Double { value(.grokMonthlyBudget) ?? 0 }

    /// Stores the key for the team (replacing any other team's) and reloads Grok.
    func saveGrokKey(_ key: String, teamID: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !team.isEmpty else { return }
        if fake { fakeGrokTeam = team } else { try GrokProvider.setKey(key, teamID: team) }
        objectWillChange.send()
        reloadGrok()
    }

    func setGrokBudget(_ budget: Double) {
        guard budget.isFinite, budget >= 0, budget != grokBudget else { return }
        set(budget, .grokMonthlyBudget)
        reloadGrok()
    }

    /// Deletes the key and the Grok account (deleting the account removes its key).
    func deleteGrokKey() {
        for a in store.accounts where a.provider == .grok { store.removeAccount(a.id) }
        if fake {
            fakeGrokTeam = nil
        } else {
            do { try GrokProvider.deleteKeys() } catch { Log.error("grok: could not delete the key: \(error)") }
        }
        objectWillChange.send()
        reloadGrok()
    }

    private func reloadGrok() { Task { await store.reloadProvider(.grok) } }
}
