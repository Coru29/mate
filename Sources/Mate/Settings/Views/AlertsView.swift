import SwiftUI
import MateCore

/// "Alertas": thresholds, alerts per provider, system notifications.
struct AlertsView: View {
    @ObservedObject var backend: SettingsBackend
    private static let maxThresholds = 5

    var body: some View {
        let thresholds = backend.thresholds
        Form {
            Section {
                ForEach(Array(thresholds.enumerated()), id: \.element) { index, value in
                    HStack {
                        Picker("Umbral \(index + 1)", selection: Binding(get: { value }, set: { new in
                            var all = thresholds
                            all[index] = new
                            backend.setThresholds(all)
                        })) {
                            ForEach(Array(stride(from: AlertThresholds.range.lowerBound,
                                                 through: AlertThresholds.range.upperBound,
                                                 by: AlertThresholds.step)), id: \.self) { n in
                                Text(verbatim: NotchText.percent(Double(n))).tag(n)
                            }
                        }
                        Button {
                            backend.setThresholds(thresholds.filter { $0 != value })
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(thresholds.count <= 1)
                        .help(Text("Quitar este umbral"))
                        .accessibilityLabel(Text("Quitar este umbral"))
                    }
                }
                if thresholds.count < Self.maxThresholds, let free = nextFree(thresholds) {
                    Button("Agregar umbral") { backend.setThresholds(thresholds + [free]) }
                }
            } header: {
                Text("Umbrales")
            } footer: {
                Text("Una alerta por cruce y por período de cada ventana, y otra cuando una ventana se reinicia después de pasar el \(NotchText.percent(75)).")
            }
            Section("Alertas por proveedor") {
                ForEach(backend.providerOrder, id: \.self) { p in
                    Toggle(isOn: Binding(get: { backend.alertsOn(p) }, set: { backend.setAlerts(p, $0) })) {
                        Text(verbatim: p.displayName)
                    }
                }
            }
            Section {
                Toggle("Además, mandar una notificación del sistema",
                       isOn: backend.binding(.systemNotifications, default: false))
            } footer: {
                Text("Las alertas siempre bajan desde el notch. macOS pide permiso la primera vez.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    /// The first step not in use, from 75 % up, then down.
    private func nextFree(_ used: [Int]) -> Int? {
        let all = Array(stride(from: AlertThresholds.range.lowerBound, through: AlertThresholds.range.upperBound,
                               by: AlertThresholds.step))
        return all.filter { $0 >= 75 }.first { !used.contains($0) } ?? all.reversed().first { !used.contains($0) }
    }
}
