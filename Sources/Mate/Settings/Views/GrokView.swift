import SwiftUI
import MateCore

/// "Grok": the xAI management key and team id (Mate's keychain) and the monthly budget. Grok shows once both are set.
struct GrokView: View {
    @ObservedObject var backend: SettingsBackend
    @State private var key = ""
    @State private var team = ""
    @State private var budget = ""
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        let stored = backend.grokTeamID
        Form {
            Section {
                SecureField("Management key", text: $key, prompt: stored == nil ? Text(verbatim: "xai-…") : Text("Guardada; pegá otra para cambiarla"))
                TextField("Team id", text: $team)
                HStack {
                    Button("Guardar la clave", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty
                                  || team.trimmingCharacters(in: .whitespaces).isEmpty)
                    if stored != nil {
                        Button("Borrar la clave", role: .destructive) { confirmDelete = true }
                    }
                    Spacer()
                }
                if let error {
                    Text(verbatim: error).font(.callout).foregroundStyle(.red)
                } else if let stored {
                    Text("Clave guardada para el equipo \(stored).").font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Clave de la API de xAI")
            } footer: {
                Text("Se crea en console.x.ai, en Management keys, con permiso de lectura de facturación. Se guarda en tu llavero y solo se envía a management-api.x.ai. Para cambiar de equipo, pegá la clave otra vez.")
            }
            Section {
                LabeledContent("Presupuesto mensual (USD)") {
                    TextField("Presupuesto mensual (USD)", text: $budget, prompt: Text(verbatim: "20"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .onSubmit(saveBudget)
                }
                Button("Guardar el presupuesto", action: saveBudget)
                    .disabled(parsedBudget == nil || parsedBudget == backend.grokBudget)
            } footer: {
                Text("El medidor de Grok es el gasto del mes contra este presupuesto. Con 0, Grok no se muestra.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            team = stored ?? ""
            budget = backend.grokBudget > 0 ? Self.format(backend.grokBudget) : ""
        }
        .confirmationDialog(Text("¿Borrar la clave de Grok?"), isPresented: $confirmDelete) {
            Button("Borrar", role: .destructive) {
                backend.deleteGrokKey()
                key = ""
                error = nil
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Mate borra la clave del llavero y la cuenta de Grok.")
        }
    }

    private var parsedBudget: Double? {
        let text = budget.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if text.isEmpty { return 0 }
        guard let v = Double(text), v.isFinite, v >= 0 else { return nil }
        return v
    }

    private func save() {
        do {
            try backend.saveGrokKey(key, teamID: team)
            key = ""
            error = nil
        } catch {
            self.error = String(localized: "No se pudo guardar la clave en el llavero.")
            Log.error("grok: could not store the key: \(error)")
        }
    }

    private func saveBudget() {
        guard let v = parsedBudget else { return }
        backend.setGrokBudget(v)
        budget = v > 0 ? Self.format(v) : ""
    }

    private static func format(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}
