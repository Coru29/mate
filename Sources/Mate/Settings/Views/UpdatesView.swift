import SwiftUI

/// "Actualizaciones": the daily check against the GitHub releases.
struct UpdatesView: View {
    @ObservedObject var backend: SettingsBackend

    var body: some View {
        Form {
            Section {
                Toggle("Buscar actualizaciones automáticamente", isOn: backend.binding(.checkUpdates, default: true))
                LabeledContent("Versión instalada") { Text(AboutView.versionText).textSelection(.enabled) }
            } footer: {
                Text("Una vez por día Mate mira los releases de Mate en GitHub (api.github.com). No manda ningún dato tuyo.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}
