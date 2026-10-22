import AppKit
import SwiftUI
import MateCore

/// "Cuentas": providers (on/off, order) and every account grouped by provider, with its source, owner and status;
/// rename, color, hide, delete; "Agregar cuenta…" and "Agregar carpeta…" for Claude and Codex.
struct AccountsView: View {
    @ObservedObject var backend: SettingsBackend
    @ObservedObject var store: UsageStore
    /// The provider whose sign-in or folder is being added.
    @State private var busy: ProviderID?
    @State private var message: (provider: ProviderID, text: String, failed: Bool)?

    var body: some View {
        let order = backend.providerOrder
        Form {
            Section {
                ForEach(order, id: \.self) { p in
                    Toggle(isOn: Binding(get: { backend.isEnabled(p) }, set: { backend.setEnabled(p, $0) })) {
                        Label {
                            Text(verbatim: p.displayName)
                        } icon: {
                            Image(systemName: p.symbolName)
                        }
                    }
                }
                .onMove { backend.moveProviders(from: $0, to: $1) }
            } header: {
                Text("Proveedores")
            } footer: {
                Text("Arrastrá para cambiar el orden en el panel. Un proveedor apagado no se muestra ni se consulta.")
            }
            ForEach(order, id: \.self) { p in
                providerSection(p)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private func providerSection(_ p: ProviderID) -> some View {
        let accounts = store.accounts.filter { $0.provider == p }
        Section {
            if accounts.isEmpty {
                Text(Self.emptyText(p))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(accounts) { a in
                AccountRow(account: a, store: store, fetchedAt: store.snapshots[a.id]?.fetchedAt,
                           busy: busy != nil, signIn: { signIn(p) })
            }
            if p == .claude || p == .codex {
                HStack {
                    Button("Agregar cuenta…") { signIn(p) }
                    Button("Agregar carpeta…") { addFolder(p) }
                    if busy == p { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .disabled(busy != nil)
            }
            if let message, message.provider == p {
                Text(verbatim: message.text)
                    .font(.callout)
                    .foregroundStyle(message.failed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            HStack {
                Text(verbatim: p.displayName)
                if !backend.isEnabled(p) {
                    Text("Apagado").foregroundStyle(.secondary)
                }
            }
        } footer: {
            if p == .claude || p == .codex {
                Text(p == .claude
                     ? "«Agregar carpeta…» es para otra instancia de Claude Code con su propio CLAUDE_CONFIG_DIR."
                     : "«Agregar carpeta…» es para otra instancia de Codex con su propio CODEX_HOME.")
            }
        }
    }

    private static func emptyText(_ p: ProviderID) -> String {
        switch p {
        case .claude, .codex: String(localized: "Sin cuentas. Iniciá sesión en \(p.agentToolName) o agregá una cuenta.")
        case .grok: String(localized: "Se configura en la página Grok.")
        default: String(localized: "Sin cuentas. Mate suma la sesión de \(p.agentToolName) cuando aparece.")
        }
    }

    // MARK: Adding

    private func signIn(_ p: ProviderID) {
        guard busy == nil else { return }
        busy = p
        message = nil
        Task {
            do {
                let a = try await store.addLogin(provider: p)
                message = (p, String(localized: "Cuenta agregada: \(a.name)."), false)
            } catch {
                message = (p, (error as? LocalizedError)?.errorDescription ?? String(describing: error), true)
            }
            busy = nil
        }
    }

    private func addFolder(_ p: ProviderID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true   // config folders are usually hidden (~/.claude-work)
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = String(localized: "Agregar")
        panel.message = p == .claude ? String(localized: "Elegí la carpeta de configuración de Claude Code (CLAUDE_CONFIG_DIR).")
            : String(localized: "Elegí la carpeta de configuración de Codex (CODEX_HOME).")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            busy = p
            message = nil
            Task {
                do {
                    let dir = UsageStore.canonicalDir(url.path)
                    switch try await store.addConfigDir(provider: p, path: url.path) {
                    case .added: message = (p, String(localized: "Mate vigila \(dir) desde ahora."), false)
                    case .alreadyWatched: message = (p, String(localized: "Mate ya vigilaba \(dir)."), false)
                    case .isDefaultDir: message = (p, String(localized: "\(dir) es la carpeta de siempre: Mate ya la vigila."), false)
                    }
                } catch {
                    message = (p, (error as? LocalizedError)?.errorDescription ?? String(describing: error), true)
                }
                busy = nil
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}

/// One account: color, editable name, source, owner, status, hide and delete.
private struct AccountRow: View {
    let account: Account
    let store: UsageStore
    let fetchedAt: Date?
    let busy: Bool
    let signIn: () -> Void
    @State private var name = ""
    @State private var confirmDelete = false
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            colorMenu
            VStack(alignment: .leading, spacing: 4) {
                // Label hidden: in a grouped form a labelled field puts its text on the far right.
                TextField("Nombre", text: $name)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .focused($editing)
                    .onSubmit(commitName)
                    .onChange(of: editing) { _, now in if !now { commitName() } }
                    .accessibilityLabel(Text("Nombre de la cuenta"))
                Text(verbatim: detailLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if let owner = ownerBadge {
                        Text(verbatim: owner)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    status
                }
            }
            Spacer(minLength: 8)
            Button {
                store.setAccountHidden(account.id, !account.hidden)
            } label: {
                Image(systemName: account.hidden ? "eye.slash" : "eye")
                    .foregroundStyle(account.hidden ? .secondary : .primary)
            }
            .buttonStyle(.borderless)
            .help(account.hidden ? Text("Mostrar en el panel") : Text("Ocultar del panel"))
            .accessibilityLabel(account.hidden ? Text("Mostrar en el panel") : Text("Ocultar del panel"))
            Button {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(Text("Borrar la cuenta"))
            .accessibilityLabel(Text("Borrar la cuenta"))
        }
        .opacity(account.hidden ? 0.6 : 1)
        .onAppear { name = account.name }
        .onChange(of: account.name) { _, new in if !editing { name = new } }
        .confirmationDialog(Text("¿Borrar la cuenta \(account.name)?"), isPresented: $confirmDelete) {
            Button("Borrar", role: .destructive) { store.removeAccount(account.id) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(verbatim: deleteMessage)
        }
    }

    private func commitName() {
        if name != account.name { store.renameAccount(account.id, to: name) }
        if let fixed = store.accounts.first(where: { $0.id == account.id })?.name { name = fixed }
    }

    private var colorMenu: some View {
        Menu {
            ForEach(NotchPalette.accountColors.indices, id: \.self) { i in
                Button {
                    store.setAccountColor(account.id, i)
                } label: {
                    Label {
                        Text("Color \(i + 1)")
                    } icon: {
                        Image(nsImage: Self.swatch(NotchPalette.accountColor(i), size: 12))
                    }
                }
            }
        } label: {
            // A borderless menu draws an image label, not a SwiftUI shape.
            Image(nsImage: Self.swatch(NotchPalette.accountColor(account.colorIndex), size: 14))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.top, 2)
        .help(Text("Color de la cuenta"))
        .accessibilityLabel(Text("Color de la cuenta"))
    }

    /// Menu items draw images, not SwiftUI shapes.
    private static func swatch(_ color: NSColor, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private var detailLine: String {
        var parts: [String] = []
        if let email = account.email, email != account.name { parts.append(email) }
        switch account.source {
        case .detected: parts.append(String(localized: "Detectada"))
        case .login: parts.append(String(localized: "Agregada con inicio de sesión"))
        case .configDir(let dir): parts.append(String(localized: "Carpeta \(dir)"))
        }
        return parts.joined(separator: " · ")
    }

    private var ownerBadge: String? {
        let p = account.provider
        if p == .grok { return String(localized: "Guardada en Mate") }
        switch account.owner {
        case .agent: return String(localized: "La usa \(p.agentToolName)")
        // An agent-only provider keeps no copy: its ended session shows as "Sin sesión" instead.
        case .mate: return account.status == .error(AccountRegistry.noSession) ? nil : String(localized: "Guardada en Mate")
        }
    }

    @ViewBuilder
    private var status: some View {
        let now = Date()
        switch account.status {
        case .ok:
            if let fetchedAt {
                Label { Text(verbatim: NotchText.age(fetchedAt, now: now)) } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                Text("Todavía sin datos").font(.callout).foregroundStyle(.secondary)
            }
        case .stale:
            Group {
                if account.provider.waitsForItsApp {
                    Text("Esperando a \(account.provider.agentAppName)")
                } else if let fetchedAt {
                    Text(verbatim: NotchText.age(fetchedAt, now: now))
                } else {
                    Text("Todavía sin datos")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .error("keychainDenied"):
            HStack(spacing: 6) {
                Text("Sin acceso al llavero").foregroundStyle(.red)
                Button("Reintentar") { store.refreshNow() }.controlSize(.small)
            }
            .font(.callout)
        case .expired:
            HStack(spacing: 6) {
                Text("Sesión vencida").foregroundStyle(.red)
                if account.provider == .claude || account.provider == .codex {
                    Button("Volver a entrar", action: signIn).controlSize(.small).disabled(busy)
                }
            }
            .font(.callout)
        case .error(AccountRegistry.noSession):
            Text("Sin sesión").font(.callout).foregroundStyle(.secondary)
        case .error(let why):
            Text("No disponible: \(PanelView.reason(why))")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private var deleteMessage: String {
        if account.provider == .grok { return String(localized: "Mate borra la management key guardada.") }
        if account.owner == .agent {
            return String(localized: "Mate borra lo que guardó de esta cuenta, pero no toca la sesión de \(account.provider.agentToolName): mientras siga con esta cuenta, vuelve a aparecer. Para no verla, ocultala.")
        }
        return String(localized: "Mate borra su copia de la sesión. Las sesiones de los agentes no se tocan.")
    }
}

extension ProviderID {
    /// The program that holds the session, as the owner badge names it ("La usa Claude Code").
    var agentToolName: String {
        switch self {
        case .claude: "Claude Code"
        case .gemini: "Gemini CLI"
        default: displayName
        }
    }
}
