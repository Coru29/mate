import SwiftUI
import MateCore

/// One page of the hover panel: one account's header, status, meters and live row. Lives in an `NSHostingView`
/// that exists only while the panel is open (two during a slide between accounts, see `PanelPager`); the black shape
/// behind it is drawn by the window's root view. The dots are `PanelDots`, below the page.
struct PanelView: View {
    @ObservedObject var store: UsageStore
    /// The account this page shows (pinned, so the outgoing page keeps its account while it slides away).
    let accountID: String?
    /// The dots sit below the page: no bottom margin of its own then.
    let hasDots: Bool
    /// Height of the notch strip at the top of the panel (content starts below it).
    let topInset: CGFloat
    /// The welcome guide's "Mate vive acá" line, on the first opening only.
    var hint = false
    let onHeader: () -> Void
    @ObservedObject private var awake = KeepAwake.shared
    @ObservedObject private var menuBar = MenuBarWatcher.shared

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 14) {
            if hint { hintRow }
            if let account = store.notchAccounts.first(where: { $0.id == accountID }) {
                header(account)
                status(account, now: now)
                if let snapshot = store.snapshots[account.id], !snapshot.windows.isEmpty {
                    ForEach(snapshot.windows, id: \.kind) { w in
                        Meter(window: w, pace: store.pace(account.id, w, now: now), now: now)
                    }
                } else {
                    Text("Todavía no hay datos de esta cuenta.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(NotchPalette.muted)
                }
                live(account.provider, now: now)
                keepAwakeRow
                menuBarRow
            } else {
                Text("No hay cuentas. Iniciá sesión en un agente o sumá una cuenta en Configuración.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(NotchPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, topInset + 10)
        .padding(.bottom, hasDots ? 0 : 18)
        .frame(width: NotchController.panelWidth, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    private var hintRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Tone.ok.color)
            Text("Mate vive acá: pasá el mouse por el notch para ver tus límites.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(NotchPalette.onNotch)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func header(_ account: Account) -> some View {
        HStack(spacing: 10) {
            Image(systemName: account.provider.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NotchPalette.onNotch)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: account.provider.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NotchPalette.onNotch)
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(nsColor: NotchPalette.accountColor(account.colorIndex)))
                        .frame(width: 7, height: 7)
                    Text(verbatim: account.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(NotchPalette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onHeader)
        .help(Text("Abrir la ventana de uso"))
    }

    @ViewBuilder
    private func status(_ account: Account, now: Date) -> some View {
        let fetchedAt = store.snapshots[account.id]?.fetchedAt
        switch account.status {
        case .error(AccountRegistry.keychainDenied):
            HStack(spacing: 10) {
                Text("Sin acceso al llavero")
                    .foregroundStyle(Tone.hot.color)
                Spacer(minLength: 0)
                Button {
                    store.refreshNow()
                } label: {
                    Text("Reintentar")
                }
                .controlSize(.small)
            }
            .font(.system(size: 12))
        case .expired:
            Text("Sesión vencida")
                .font(.system(size: 12))
                .foregroundStyle(Tone.hot.color)
        case .ok:
            // Fine status but old data (the panel was closed and nothing was fetched for a while).
            if let fetchedAt, now.timeIntervalSince(fetchedAt) > FetchSchedule.idleInterval + 300 {
                age(fetchedAt, now: now)
            }
        case .error(AccountRegistry.noSession):
            // An agent-only account whose session ended: its last data stays below.
            HStack(spacing: 6) {
                Text("Sin sesión")
                if let fetchedAt { Text(verbatim: "· " + NotchText.age(fetchedAt, now: now)) }
            }
            .font(.system(size: 12))
            .foregroundStyle(NotchPalette.muted)
        case .stale where account.provider.waitsForItsApp:
            // Cursor and Gemini CLI refresh their own tokens; Mate waits for them.
            HStack(spacing: 6) {
                Text("Esperando a \(account.provider.agentAppName)")
                if let fetchedAt { Text(verbatim: "· " + NotchText.age(fetchedAt, now: now)) }
            }
            .font(.system(size: 12))
            .foregroundStyle(NotchPalette.muted)
        case .error(let why) where fetchedAt == nil:
            // A failing endpoint with no earlier data to fall back on.
            Text("No disponible: \(Self.reason(why))")
                .font(.system(size: 12))
                .foregroundStyle(Tone.hot.color)
                .fixedSize(horizontal: false, vertical: true)
        case .stale, .error:
            if let fetchedAt { age(fetchedAt, now: now) }
        }
    }

    /// The readable form of an `AccountStatus.error` code (free text, such as "HTTP 503", passes through).
    static func reason(_ code: String) -> String {
        switch code {
        case "rateLimited": String(localized: "demasiados pedidos, probá más tarde")
        case "response": String(localized: "respuesta inesperada del servidor")
        case "unauthorized": String(localized: "la sesión no es válida")
        case "credentials", "keychain": String(localized: "no se pudo leer la sesión")
        default: code
        }
    }

    private func age(_ date: Date, now: Date) -> some View {
        Text(verbatim: NotchText.age(date, now: now))
            .font(.system(size: 12))
            .foregroundStyle(NotchPalette.muted)
    }

    /// Live Claude Code session: "Sesión actual · rambla" left, "34 min · 182 k tokens" right; only the project
    /// (gray dot) when nothing is live.
    @ViewBuilder
    private func live(_ provider: ProviderID, now: Date) -> some View {
        let session = store.aggregates.liveSession(provider: provider, now: now)
        if let project = session?.project ?? store.aggregates.lastProject(provider: provider, now: now) {
            VStack(spacing: 12) {
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                HStack(spacing: 7) {
                    Circle()
                        .fill(session == nil ? Color.white.opacity(0.28) : Tone.ok.color)
                        .frame(width: 7, height: 7)
                    Group {
                        if session != nil {
                            Text("Sesión actual · \(project)")
                        } else {
                            Text(verbatim: project)
                        }
                    }
                    .fontWeight(.medium)
                    .foregroundStyle(NotchPalette.onNotch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let session {
                        Text(verbatim: NotchText.duration(now.timeIntervalSince(session.startedAt))
                             + " · " + NotchText.tokens(session.tokens))
                            .monospacedDigit()
                            .foregroundStyle(NotchPalette.muted)
                    }
                }
                .font(.system(size: 12))
                .help(ifLive: session == nil ? nil : liveHelp(provider))
            }
        }
    }

    /// Who keeps the Mac awake (Mate while agents work, or another app); hidden when nobody does and the option is
    /// off. Status only: the switch lives in Configuración and the right-click menu.
    @ViewBuilder
    private var keepAwakeRow: some View {
        if let text = awake.statusText {
            HStack(spacing: 7) {
                if let glyph = MateIconView.glyph {
                    Image(nsImage: glyph)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .overlay(alignment: .bottomTrailing) {
                            if awake.showsDot {
                                Circle().fill(Tone.ok.color).frame(width: 5, height: 5)
                            }
                        }
                }
                Text(verbatim: text)
                    .fontWeight(.medium)
                    .foregroundStyle(awake.showsDot ? NotchPalette.onNotch : NotchPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.top, -4)
        }
    }

    /// On a display without a notch, Mate needs Accessibility to see where the menus end; asked only from here.
    @ViewBuilder
    private var menuBarRow: some View {
        if menuBar.needsPermission {
            HStack(spacing: 7) {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NotchPalette.muted)
                    .frame(width: 16, height: 16)
                Text("Para no tapar los menús, Mate necesita permiso de Accesibilidad")
                    .fontWeight(.medium)
                    .foregroundStyle(NotchPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { menuBar.requestPermission() } label: { Text("Permitir") }
                    .controlSize(.small)
            }
            .font(.system(size: 12))
            .padding(.top, -4)
        }
    }

    private func liveHelp(_ provider: ProviderID) -> Text {
        let tool = provider == .claude ? "Claude Code" : provider.displayName
        return Text("Proyecto, tiempo y tokens de la sesión de \(tool) en curso (incluye caché)")
    }
}

/// One dot per account under the panel's pages; the selected one is a wider, brighter capsule, and the change
/// springs like the page slide. A click selects the account (the controller slides the page).
struct PanelDots: View {
    @ObservedObject var store: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 46

    var body: some View {
        let selected = store.panelAccount?.id
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(store.notchAccounts) { a in
                Button {
                    store.selectedAccountID = a.id
                } label: {
                    Capsule()
                        .fill(a.id == selected ? NotchPalette.onNotch : Color.white.opacity(0.28))
                        .frame(width: a.id == selected ? 16 : 7, height: 7)
                        .frame(height: 22)
                        .padding(.horizontal, 7.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: "\(a.provider.displayName) · \(a.name)"))
            }
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.86), value: selected)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: NotchController.panelWidth, height: Self.height)
        // Opaque like the panel: while the panel grows, the incoming page's lower rows pass under the dots.
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

extension ProviderID {
    /// Generic SF Symbol per provider (no brand marks).
    var symbolName: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        case .gemini: "sparkles"
        case .copilot: "airplane"
        case .grok: "bolt.fill"
        }
    }
}

extension UsageStore {
    /// Visible accounts of enabled providers: providers in the order of Configuración, accounts within each.
    var notchAccounts: [Account] {
        let order = NotchPrefs.providerOrder
        let disabled = NotchPrefs.disabledProviders
        return accounts.enumerated()
            .filter { !$0.element.hidden && !disabled.contains($0.element.provider.rawValue) }
            .sorted {
                let a = order.firstIndex(of: $0.element.provider.rawValue) ?? Int.max
                let b = order.firstIndex(of: $1.element.provider.rawValue) ?? Int.max
                return a != b ? a < b : $0.offset < $1.offset
            }
            .map(\.element)
    }

    /// The account the panel shows: the selected one, else the first visible one.
    var panelAccount: Account? {
        let all = notchAccounts
        return all.first { $0.id == selectedAccountID } ?? all.first
    }

    /// The account the pill shows: of the active provider, the selected account if it is one of its own, else the
    /// one the agent is logged in to, else its first. Without an active provider, the panel's account.
    var pillAccount: Account? {
        guard let p = activeProvider else { return panelAccount }
        let mine = notchAccounts.filter { $0.provider == p }
        return mine.first { $0.id == selectedAccountID } ?? mine.first { $0.owner == .agent } ?? mine.first
    }

    func pace(_ accountID: String, _ window: LimitWindow, now: Date) -> PaceState? {
        MateCore.pace(for: window, samples: samples(for: accountID, window: window.kind), now: now)
    }

    /// Moves the selection by `step` dots, wrapping around.
    func selectAccount(step: Int) {
        let all = notchAccounts
        guard !all.isEmpty else { return }
        let current = all.firstIndex { $0.id == panelAccount?.id } ?? 0
        selectedAccountID = all[((current + step) % all.count + all.count) % all.count].id
    }
}

private extension View {
    /// A tooltip only when there is one to show (an empty `.help` still installs a tooltip).
    @ViewBuilder
    func help(ifLive text: Text?) -> some View {
        if let text { help(text) } else { self }
    }
}
