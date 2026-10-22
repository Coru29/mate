import SwiftUI

/// The pages of the settings window, in sidebar order.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, accounts, alerts, grok, updates, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .accounts: String(localized: "Cuentas")
        case .alerts: String(localized: "Alertas")
        case .grok: String(localized: "Grok")
        case .updates: String(localized: "Actualizaciones")
        case .about: String(localized: "Acerca de")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.2"
        case .alerts: "bell"
        case .grok: "bolt"
        case .updates: "arrow.down.circle"
        case .about: "info.circle"
        }
    }
}

/// Sidebar plus the selected page.
struct SettingsRoot: View {
    static let minimumSize = CGSize(width: 720, height: 540)

    @ObservedObject var backend: SettingsBackend
    @ObservedObject var store: UsageStore
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        // A constant visibility keeps the sidebar from being dragged shut: nothing in the window could reopen it.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $navigation.selection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            page(for: navigation.selection ?? .general)
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
    }

    @ViewBuilder
    private func page(for section: SettingsSection) -> some View {
        switch section {
        case .general: GeneralView(backend: backend)
        case .accounts: AccountsView(backend: backend, store: store)
        case .alerts: AlertsView(backend: backend)
        case .grok: GrokView(backend: backend)
        case .updates: UpdatesView(backend: backend)
        case .about: AboutView()
        }
    }
}
