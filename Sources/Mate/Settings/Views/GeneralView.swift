import AppKit
import SwiftUI
import MateCore

/// "General": launch at login, which screen, when the pill and the mate show, keeping the Mac awake, language.
struct GeneralView: View {
    @ObservedObject var backend: SettingsBackend

    var body: some View {
        Form {
            Section {
                Toggle("Iniciar con la sesión", isOn: Binding(get: { backend.launchAtLogin },
                                                               set: { backend.setLaunchAtLogin($0) }))
                if backend.launchAtLoginNeedsApproval {
                    HStack {
                        Text("macOS pide que lo apruebes en Ítems de inicio.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Abrir Ítems de inicio") { backend.openLoginItemsSettings() }
                    }
                }
            }
            Section {
                Picker("Pantalla", selection: backend.binding(.screenChoice, default: ScreenChoice.builtIn.rawValue)) {
                    Text("La integrada").tag(ScreenChoice.builtIn.rawValue)
                    Text("La principal").tag(ScreenChoice.main.rawValue)
                    Text("La que tiene el cursor").tag(ScreenChoice.mouse.rawValue)
                }
                Picker("Mostrar el pill", selection: backend.binding(.showPillAlways, default: false)) {
                    Text("Solo con un agente activo").tag(false)
                    Text("Siempre").tag(true)
                }
                Toggle("Mostrar el mate junto al notch", isOn: backend.binding(.showMateIcon, default: true))
                Toggle("Mostrar lo que estás escuchando", isOn: backend.binding(.showNowPlaying, default: true))
            } footer: {
                Text("Sin notch, Mate dibuja uno propio arriba al centro. Pasar el mouse por el notch abre el panel aunque el pill no se vea.")
            }
            Section {
                Toggle("Mantener la Mac despierta mientras trabajan los agentes",
                       isOn: backend.binding(.keepAwake, default: false))
            } footer: {
                Text("Evita que la Mac se duerma sola mientras un agente trabaja. La pantalla puede apagarse igual.")
            }
            Section {
                Picker("Idioma", selection: Binding(get: { backend.language }, set: { backend.language = $0 })) {
                    Text("El del sistema").tag("system")
                    Text(verbatim: "Español").tag("es")
                    Text(verbatim: "English").tag("en")
                }
            } footer: {
                Text("El idioma cambia la próxima vez que abras Mate.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        // The user may change the login item in System Settings while this window is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            backend.objectWillChange.send()
        }
    }
}
