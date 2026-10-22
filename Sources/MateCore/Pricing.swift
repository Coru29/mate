import Foundation

public enum Pricing {
    /// ESTIMATES in USD per million tokens (input, output, cache write, cache read) from public list prices;
    /// they drift over time and ignore tiers, batch and long-context surcharges. Use for display only.
    private static let table: [(prefix: String, input: Double, output: Double, cacheWrite: Double, cacheRead: Double)] = [
        ("claude-opus-4", 15, 75, 18.75, 1.5),
        ("claude-opus-4-5", 5, 25, 6.25, 0.5),
        ("claude-opus-4-6", 5, 25, 6.25, 0.5),
        ("claude-opus-4-7", 5, 25, 6.25, 0.5),
        ("claude-opus-4-8", 5, 25, 6.25, 0.5),
        ("claude-opus-4-9", 5, 25, 6.25, 0.5),
        ("claude-opus-5", 5, 25, 6.25, 0.5),
        ("claude-sonnet", 3, 15, 3.75, 0.3),
        ("claude-haiku", 1, 5, 1.25, 0.1),
        ("gpt-5", 1.25, 10, 0, 0.125),
        ("gemini-2.5-pro", 1.25, 10, 0, 0.31),
        ("gemini-3-pro", 1.25, 10, 0, 0.31),
        ("gemini-2.5-flash", 0.3, 2.5, 0, 0.075),
    ]

    /// Estimated cost in USD. The longest matching prefix wins; an unknown model costs 0.
    public static func cost(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        let m = model.lowercased()
        guard let p = table.filter({ m.hasPrefix($0.prefix) }).max(by: { $0.prefix.count < $1.prefix.count }) else { return 0 }
        return (Double(input) * p.input + Double(output) * p.output
                + Double(cacheWrite) * p.cacheWrite + Double(cacheRead) * p.cacheRead) / 1_000_000
    }
}
