import Foundation

public struct LiveSession: Equatable, Sendable {
    public var project: String?
    public var startedAt: Date
    public var tokens: Int
}

/// Token usage rolled up per local calendar day, provider and model. Raw events (and their dedupe keys) are kept
/// only for the last 2 days, relative to the newest event seen; older raw events are dropped on `add` because
/// their totals already live in the day buckets.
public struct UsageAggregates: Codable, Sendable {
    struct ModelTotals: Codable, Sendable { var tokens = 0; var cost = 0.0 }
    struct Bucket: Codable, Sendable {
        var day: Date
        var providers: [String: Int] = [:]
        var models: [String: ModelTotals] = [:]
    }

    static let rawRetention: TimeInterval = 2 * 86_400
    static let liveWindow: TimeInterval = 120
    static let bucketRetentionDays = 400

    var buckets: [Bucket] = []
    var raw: [TokenEvent] = []
    var seenKeys: Set<String> = []
    var newest: Date?

    public init() {}

    public var rawEventCount: Int { raw.count }
    public var seenKeyCount: Int { seenKeys.count }

    /// Returns false (and ignores the event) when its `dedupeKey` was already counted among the raw events.
    /// Events older than the raw window when added skip deduplication.
    @discardableResult
    public mutating func add(_ e: TokenEvent, calendar: Calendar = .current) -> Bool {
        if let k = e.dedupeKey, seenKeys.contains(k) { return false }
        let day = calendar.startOfDay(for: e.at)
        let i: Int
        if let found = buckets.firstIndex(where: { $0.day == day }) {
            i = found
        } else {
            buckets.append(Bucket(day: day))
            i = buckets.count - 1
        }
        buckets[i].providers[e.provider.rawValue, default: 0] += e.totalTokens
        buckets[i].models[e.model, default: ModelTotals()].tokens += e.totalTokens
        buckets[i].models[e.model, default: ModelTotals()].cost += Pricing.cost(
            model: e.model, input: e.input, output: e.output, cacheRead: e.cacheRead, cacheWrite: e.cacheWrite)

        raw.append(e)
        if let k = e.dedupeKey { seenKeys.insert(k) }
        newest = max(newest ?? e.at, e.at)
        compact(calendar: calendar)
        return true
    }

    private mutating func compact(calendar: Calendar) {
        guard let newest else { return }
        let cutoff = newest.addingTimeInterval(-Self.rawRetention)
        for e in raw where e.at < cutoff {
            if let k = e.dedupeKey { seenKeys.remove(k) }
        }
        raw.removeAll { $0.at < cutoff }
        if let oldest = calendar.date(byAdding: .day, value: -Self.bucketRetentionDays, to: newest) {
            buckets.removeAll { $0.day < oldest }
        }
    }

    /// One entry per day, oldest first, ending with the day of `now`; days without usage have an empty dictionary.
    public func daily(last days: Int, now: Date, calendar: Calendar = .current) -> [(day: Date, perProvider: [ProviderID: Int])] {
        let today = calendar.startOfDay(for: now)
        return (0..<max(0, days)).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            var per: [ProviderID: Int] = [:]
            if let b = buckets.first(where: { $0.day == day }) {
                for (k, v) in b.providers { if let p = ProviderID(rawValue: k) { per[p] = v } }
            }
            return (day, per)
        }
    }

    /// Models used in the last `days` days (today included), biggest first.
    public func byModel(last days: Int, now: Date, calendar: Calendar = .current) -> [(model: String, tokens: Int, cost: Double)] {
        let today = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) else { return [] }
        var sums: [String: ModelTotals] = [:]
        for b in buckets where b.day >= from && b.day <= today {
            for (m, t) in b.models {
                sums[m, default: ModelTotals()].tokens += t.tokens
                sums[m, default: ModelTotals()].cost += t.cost
            }
        }
        return sums.map { (model: $0.key, tokens: $0.value.tokens, cost: $0.value.cost) }
            .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.model < $1.model }
    }

    public func today(now: Date, calendar: Calendar = .current) -> [ProviderID: Int] {
        daily(last: 1, now: now, calendar: calendar).first?.perProvider ?? [:]
    }

    /// The session of the provider's latest raw event, if that event is at most 2 minutes old.
    public func liveSession(provider: ProviderID, now: Date) -> LiveSession? {
        let mine = raw.filter { $0.provider == provider && $0.at <= now }
        guard let last = mine.max(by: { $0.at < $1.at }), now.timeIntervalSince(last.at) <= Self.liveWindow else { return nil }
        let session = mine.filter { $0.sessionID == last.sessionID }
        return LiveSession(project: last.project, startedAt: session.map(\.at).min() ?? last.at,
                           tokens: session.reduce(0) { $0 + $1.totalTokens })
    }
}
