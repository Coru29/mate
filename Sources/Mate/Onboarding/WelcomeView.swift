import AppKit
import SwiftUI
import MateCore

/// The welcome guide: one step at a time, page dots and Atrás / Siguiente underneath.
struct WelcomeView: View {
    static let size = CGSize(width: 560, height: 440)

    @ObservedObject var model: WelcomeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch model.page {
                case .welcome: IntroPage().transition(.opacity)
                case .agents: AgentsPage(model: model).transition(.opacity)
                case .keychain: KeychainPage().transition(.opacity)
                case .launch: LaunchPage(backend: model.backend).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.page)
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var footer: some View {
        ZStack {
            HStack(spacing: 2) {
                ForEach(WelcomePage.allCases, id: \.self) { page in
                    Circle()
                        .fill(page == model.page ? Color.primary.opacity(0.75) : Color.primary.opacity(0.2))
                        .frame(width: 7, height: 7)
                        .padding(5)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Paso \(model.page.rawValue + 1) de \(WelcomePage.allCases.count)"))
            HStack {
                if !model.isFirst { Button("Atrás", action: model.back) }
                Spacer()
                Button(action: model.advance) {
                    if model.isLast { Text("Empezar") } else if model.page == .keychain { Text("Entendido") } else { Text("Siguiente") }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .frame(height: 60)
    }
}

/// A step's heading: a small colored tile with a symbol, then the title.
private struct PageHeader: View {
    let symbol: String
    let tint: Color
    let title: Text

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            title.font(.title2.bold())
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 1. Bienvenida

private struct IntroPage: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 100, height: 100)
                .accessibilityHidden(true)
            Text("Bienvenido a Mate")
                .font(.largeTitle.bold())
                .padding(.top, 12)
            Text("Mate muestra en el notch cuánto te queda de los límites de Claude Code, Codex, Cursor, Gemini, Copilot y Grok, y te avisa antes de que se acaben.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
                .padding(.top, 8)
            Text("Todo queda en esta Mac: las sesiones se usan solo para consultar a su propio proveedor.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(.top, 18)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 2. Agentes encontrados

private struct AgentsPage: View {
    @ObservedObject var model: WelcomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "magnifyingglass", tint: .blue, title: Text("Agentes en esta Mac"))
            Text("Mate encontró estas sesiones. Todavía no leyó ninguna clave: eso pasa en el paso siguiente.")
                .fixedSize(horizontal: false, vertical: true)
            if let detected = model.detected {
                VStack(spacing: 0) {
                    ForEach(Array(model.backend.providerOrder.filter { $0 != .grok && model.backend.isEnabled($0) }.enumerated()), id: \.element) { i, p in
                        if i > 0 { Divider() }
                        row(p, sessions: detected[p] ?? [])
                    }
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                Text("Grok se configura después, en Configuración. Más cuentas se suman desde Configuración → Cuentas.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Buscando…").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
    }

    private func row(_ p: ProviderID, sessions: [ObservedSession]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: sessions.isEmpty ? "circle.dashed" : "checkmark.circle.fill")
                .foregroundStyle(sessions.isEmpty ? Color.secondary : Color.green)
                .accessibilityHidden(true)
            Text(verbatim: p.agentToolName).font(.body.weight(.medium))
            Spacer(minLength: 8)
            if sessions.isEmpty {
                Text("Sin sesión").foregroundStyle(.secondary)
            } else {
                Text(verbatim: sessions.map { $0.email ?? $0.identity }.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 3. El llavero

private struct KeychainPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(symbol: "key.fill", tint: .orange, title: Text("El aviso del llavero"))
            Text("Claude Code guarda su sesión en el llavero de macOS. Mate la lee con «security», la herramienta de Apple, así que si macOS pregunta, el aviso dice «security quiere usar tu información confidencial…».")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Image(systemName: "hand.tap.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Escribí la contraseña de tu Mac y tocá «Permitir siempre».")
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Con «Permitir» a secas, macOS vuelve a preguntar cada vez. Mate solo lee la sesión para consultar tu uso a Anthropic; nunca la cambia ni la manda a otro lado. Si tocás «Denegar», podés reintentar desde el panel.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
    }
}

// MARK: - 4. Iniciar con la sesión

private struct LaunchPage: View {
    @ObservedObject var backend: SettingsBackend

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(symbol: "power", tint: .green, title: Text("Listo"))
            Text("Mate vive en el notch: pasá el mouse por arriba para ver tus límites y hacé click derecho para el menú. Abrir Mate de nuevo desde Aplicaciones abre la Configuración.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(get: { backend.launchAtLogin }, set: { backend.setLaunchAtLogin($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Iniciar con la sesión").font(.body.weight(.medium))
                    Text("Mate se abre solo cuando entrás a tu Mac.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(14)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if backend.launchAtLoginNeedsApproval {
                HStack {
                    Text("macOS pide que lo apruebes en Ítems de inicio.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Abrir Ítems de inicio") { backend.openLoginItemsSettings() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
    }
}
