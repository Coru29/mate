import SwiftUI
import Charts
import MateCore

/// Last 7 days of tokens (stacked by provider), today's totals and the 30-day breakdown by model, from the local
/// agent logs only. Filter by provider and, when the log tells the account, by account.
struct UsageView: View {
    @ObservedObject var store: UsageStore
    @State private var provider: ProviderID?
    @State private var accountID: String?

    private static let providerColors: [ProviderID: Color] = [
        .claude: Color(red: 0xd9 / 255, green: 0x77 / 255, blue: 0x57 / 255),
        .codex: Color(red: 0x3c / 255, green: 0xcf / 255, blue: 0x7a / 255),
        .gemini: Color(red: 0x7a / 255, green: 0xa7 / 255, blue: 0xff / 255),
        .cursor: Color.gray, .copilot: Color.purple, .grok: Color.teal,
    ]

    private var now: Date { Date() }

    /// Providers with log data in the last 30 days.
    private var providersWithData: [ProviderID] {
        let days = store.aggregates.daily(last: 30, now: now)
        return ProviderID.allCases.filter { p in days.contains { ($0.perProvider[p] ?? 0) > 0 } }
    }

    private var accountsOfProvider: [Account] {
        guard let provider else { return [] }
        return store.accounts.filter { $0.provider == provider && !$0.hidden }
    }

    private struct Bar: Identifiable {
        let day: Date, provider: ProviderID, tokens: Int
        var id: String { "\(day.timeIntervalSince1970)-\(provider.rawValue)" }
    }

    private var bars: [Bar] {
        store.aggregates.daily(last: 7, now: now, account: accountID).flatMap { d in
            d.perProvider.compactMap { p, n in
                (provider == nil || provider == p) ? Bar(day: d.day, provider: p, tokens: n) : nil
            }
        }
    }

    /// Providers in the chart, in a stable order (legend and color scale).
    private var shown: [ProviderID] { ProviderID.allCases.filter { p in bars.contains { $0.provider == p } } }

    private var todayTotals: [(ProviderID, Int)] {
        store.aggregates.daily(last: 1, now: now, account: accountID).first?.perProvider
            .filter { provider == nil || $0.key == provider && $0.value > 0 }
            .sorted { $0.key.rawValue < $1.key.rawValue } ?? []
    }

    private var models: [(model: String, tokens: Int, cost: Double)] {
        store.aggregates.byModel(last: 30, now: now, provider: provider, account: accountID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            filters
            todayRow
            chartSection
            Divider()
            modelTable
        }
        .padding(20)
        .frame(width: UsageWindowController.size.width, height: UsageWindowController.size.height, alignment: .topLeading)
    }

    // MARK: Pieces

    private var filters: some View {
        HStack(spacing: 12) {
            Picker(selection: $provider) {
                Text("Todos").tag(ProviderID?.none)
                ForEach(providersWithData, id: \.self) { Text($0.displayName).tag(ProviderID?.some($0)) }
            } label: { EmptyView() }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: provider) { accountID = nil }
            if accountsOfProvider.count > 1 {
                Picker("Cuenta", selection: $accountID) {
                    Text("Todas las cuentas").tag(String?.none)
                    ForEach(accountsOfProvider) { Text($0.name).tag(String?.some($0.id)) }
                }
                .fixedSize()
            }
            Spacer()
        }
    }

    private var todayRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text("Hoy").font(.headline)
            if todayTotals.isEmpty {
                Text("Sin uso registrado").foregroundStyle(.secondary)
            }
            ForEach(todayTotals, id: \.0) { p, n in
                HStack(spacing: 6) {
                    Circle().fill(Self.providerColors[p] ?? .gray).frame(width: 8, height: 8)
                    Text(p.displayName)
                    Text(NotchText.tokens(n)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Últimos 7 días").font(.headline)
            Chart(bars) { b in
                BarMark(x: .value("Día", b.day, unit: .day), y: .value("Tokens", b.tokens))
                    .foregroundStyle(by: .value("Proveedor", b.provider.displayName))
            }
            .chartForegroundStyleScale(
                domain: shown.map(\.displayName), range: shown.map { Self.providerColors[$0] ?? .gray })
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let n = value.as(Int.self) { Text(NotchText.tokensShort(n)) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: true)
                }
            }
            .frame(height: 170)
        }
    }

    private var modelTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Últimos 30 días por modelo").font(.headline)
            ScrollView {
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Modelo").gridColumnAlignment(.leading)
                        Text("Tokens")
                        Text("Costo estimado (precio de API)")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(models, id: \.model) { m in
                        GridRow {
                            Text(m.model).gridColumnAlignment(.leading).lineLimit(1)
                            Text(NotchText.tokensShort(m.tokens)).monospacedDigit()
                            Text(NotchText.usd(m.cost)).monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Text("Estimado con el precio de lista de la API; no es lo que cobra tu plan. Solo cuentan los logs locales.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
