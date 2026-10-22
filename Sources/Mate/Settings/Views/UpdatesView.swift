import SwiftUI

/// "Actualizaciones": the daily check against the GitHub releases.
struct UpdatesView: View {
    @ObservedObject var backend: SettingsBackend
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            Section {
                Toggle("Buscar actualizaciones automáticamente", isOn: backend.binding(.checkUpdates, default: true))
                LabeledContent("Versión instalada") { Text(AboutView.versionText).textSelection(.enabled) }
                if let update = updater.available {
                    LabeledContent {
                        Button("Instalar") { updater.offerInstall() }
                            .disabled(updater.isInstalling)
                    } label: {
                        Text("Mate \(update.version.description) disponible")
                    }
                }
                LabeledContent {
                    Button("Buscar ahora") { Task { await Updater.shared.check(userInitiated: true) } }
                        .disabled(backend.fake)
                } label: {
                    Text("Buscar una versión nueva")
                }
            } footer: {
                Text("Una vez por día Mate mira los releases de Mate en GitHub (api.github.com). No manda ningún dato tuyo.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}
