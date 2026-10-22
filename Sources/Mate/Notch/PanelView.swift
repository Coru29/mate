import SwiftUI
import MateCore

/// The hover panel. Lives in an `NSHostingView` that exists only while the panel is open; the black shape behind
/// it is drawn by the window's root view.
struct PanelView: View {
    @ObservedObject var store: UsageStore
    /// Height of the notch strip at the top of the panel (content starts below it).
    let topInset: CGFloat
    let onHeader: () -> Void

    var body: some View {
        let now = Date()
        let accounts = store.notchAccounts
        VStack(alignment: .leading, spacing: 14) {
            if let account = store.panelAccount {
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
            } else {
                Text("No hay cuentas. Iniciá sesión en un agente o sumá una cuenta en Configuración.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(NotchPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if accounts.count > 1 { dots(accounts) }
        }
        .padding(.horizontal, 20)
        .padding(.top, topInset + 10)
        .padding(.bottom, accounts.count > 1 ? 10 : 18)
        .frame(width: NotchController.panelWidth, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
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
        case .error("keychainDenied"):
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
        case .stale, .error:
            if let fetchedAt { age(fetchedAt, now: now) }
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
                .help(session == nil ? Text(verbatim: "") : liveHelp(provider))
            }
        }
    }

    private func liveHelp(_ provider: ProviderID) -> Text {
        let tool = provider == .claude ? "Claude Code" : provider.displayName
        return Text("Proyecto, tiempo y tokens de la sesión de \(tool) en curso (incluye caché)")
    }

    private func dots(_ accounts: [Account]) -> some View {
        let selected = store.panelAccount?.id
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(accounts) { a in
                Button {
                    store.selectedAccountID = a.id
                } label: {
                    Circle()
                        .fill(a.id == selected ? NotchPalette.onNotch : Color.white.opacity(0.28))
                        .frame(width: 7, height: 7)
                        .scaleEffect(a.id == selected ? 1.15 : 1)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: "\(a.provider.displayName) · \(a.name)"))
            }
            Spacer(minLength: 0)
        }
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
