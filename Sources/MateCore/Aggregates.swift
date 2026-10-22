import Foundation

public struct LiveSession: Equatable, Sendable {
    public var project: String?
    public var startedAt: Date
    public var tokens: Int
}

/// Token usage rolled up per local calendar day, provider and model. Raw events (and their dedupe keys) are kept
/// only for the last 2 days (for `liveSession`), relative to the newest event seen. Dedupe is per day bucket,
/// so a duplicate of an old event is still rejected.
public struct UsageAggregates: Codable, Sendable {
    struct ModelTotals: Codable, Sendable { var tokens = 0; var cost = 0.0 }
    struct Bucket: Codable, Sendable {
        var day: Date
        var providers: [String: Int] = [:]
        var models: [String: ModelTotals] = [:]
        /// Per provider, then model (for the provider filter).
        var providerModels: [String: [String: ModelTotals]] = [:]
        /// Per account id, then model; only events whose account could be attributed (for the account filter).
        var accountModels: [String: [String: ModelTotals]] = [:]
        /// FNV-1a 64 hashes of the `dedupeKey`s counted into this day; lives and dies with the bucket.
        var keys: Set<UInt64> = []

        init(day: Date) { self.day = day }

        // Buckets persisted before the per-provider and per-account slices existed still decode.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = try c.decode(Date.self, forKey: .day)
            providers = try c.decode([String: Int].self, forKey: .providers)
            models = try c.decode([String: ModelTotals].self, forKey: .models)
            providerModels = try c.decodeIfPresent([String: [String: ModelTotals]].self, forKey: .providerModels) ?? [:]
            accountModels = try c.decodeIfPresent([String: [String: ModelTotals]].self, forKey: .accountModels) ?? [:]
            keys = try c.decode(Set<UInt64>.self, forKey: .keys)
        }
    }

    /// Stable across processes (unlike `Hasher`), so persisted dedupe survives relaunches.
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    static let rawRetention: TimeInterval = 2 * 86_400
    static let liveWindow: TimeInterval = 120
    static let bucketRetentionDays = 400

    /// Bump when the persisted shape gains data that only a re-index can fill.
    public static let schemaVersion = 2

    /// True when persisted aggregates (and their file cursors) must be dropped so the logs are indexed again.
    public static func needsRebuild(storedVersion: Int?) -> Bool { storedVersion != schemaVersion }

    public internal(set) var storedSchema: Int? = UsageAggregates.schemaVersion
    var buckets: [Bucket] = []
    var raw: [TokenEvent] = []
    var newest: Date?
    var compactedDay: Date?

    public init() {}

    public var rawEventCount: Int { raw.count }

    /// Returns false (and ignores the event) when its `dedupeKey` was already counted on the event's day.
    /// `accountID` (from `SwitchHistory`) also counts the event into the per-account slice.
    @discardableResult
    public mutating func add(_ e: TokenEvent, accountID: String? = nil, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: e.at)
        let i: Int
        if let found = buckets.firstIndex(where: { $0.day == day }) {
            i = found
        } else {
            buckets.append(Bucket(day: day))
            i = buckets.count - 1
        }
        let hash = e.dedupeKey.map(Self.fnv1a)
        if let hash, buckets[i].keys.contains(hash) { return false }
        if let hash { buckets[i].keys.insert(hash) }
        buckets[i].providers[e.provider.rawValue, default: 0] += e.totalTokens
        let cost = Pricing.cost(
            model: e.model, input: e.input, output: e.output, cacheRead: e.cacheRead, cacheWrite: e.cacheWrite)
        buckets[i].models[e.model, default: ModelTotals()].tokens += e.totalTokens
        buckets[i].models[e.model, default: ModelTotals()].cost += cost
        buckets[i].providerModels[e.provider.rawValue, default: [:]][e.model, default: ModelTotals()].tokens += e.totalTokens
        buckets[i].providerModels[e.provider.rawValue, default: [:]][e.model, default: ModelTotals()].cost += cost
        if let accountID {
            buckets[i].accountModels[accountID, default: [:]][e.model, default: ModelTotals()].tokens += e.totalTokens
            buckets[i].accountModels[accountID, default: [:]][e.model, default: ModelTotals()].cost += cost
        }

        newest = max(newest ?? e.at, e.at)
        if let newest, e.at >= newest.addingTimeInterval(-Self.rawRetention) { raw.append(e) }
        if let newest, compactedDay != calendar.startOfDay(for: newest) {
            compactedDay = calendar.startOfDay(for: newest)
            compact(calendar: calendar)
        }
        return true
    }

    private mutating func compact(calendar: Calendar) {
        guard let newest else { return }
        let cutoff = newest.addingTimeInterval(-Self.rawRetention)
        raw.removeAll { $0.at < cutoff }
        if let oldest = calendar.date(byAdding: .day, value: -Self.bucketRetentionDays, to: newest) {
            buckets.removeAll { $0.day < oldest }
        }
    }

    /// One entry per day, oldest first, ending with the day of `now`; days without usage have an empty dictionary.
    /// With `account`, only tokens attributed to that account, under its provider (ids are `"<provider>:<identity>"`).
    public func daily(last days: Int, now: Date, account: String? = nil,
                      calendar: Calendar = .current) -> [(day: Date, perProvider: [ProviderID: Int])] {
        let today = calendar.startOfDay(for: now)
        return (0..<max(0, days)).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            var per: [ProviderID: Int] = [:]
            if let b = buckets.first(where: { $0.day == day }) {
                if let account {
                    let total = b.accountModels[account]?.values.reduce(0) { $0 + $1.tokens } ?? 0
                    if total > 0, let p = Self.provider(ofAccount: account) { per[p] = total }
                } else {
                    for (k, v) in b.providers { if let p = ProviderID(rawValue: k) { per[p] = v } }
                }
            }
            return (day, per)
        }
    }

    static func provider(ofAccount id: String) -> ProviderID? {
        id.split(separator: ":", maxSplits: 1).first.flatMap { ProviderID(rawValue: String($0)) }
    }

    /// Models used in the last `days` days (today included), biggest first. `account` wins over `provider`.
    public func byModel(last days: Int, now: Date, provider: ProviderID? = nil, account: String? = nil,
                        calendar: Calendar = .current) -> [(model: String, tokens: Int, cost: Double)] {
        let today = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) else { return [] }
        var sums: [String: ModelTotals] = [:]
        for b in buckets where b.day >= from && b.day <= today {
            let models: [String: ModelTotals]
            if let account { models = b.accountModels[account] ?? [:] }
            else if let provider { models = b.providerModels[provider.rawValue] ?? [:] }
            else { models = b.models }
            for (m, t) in models {
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

    /// Project of the provider's latest raw event with a project (last 2 days), live or not.
    public func lastProject(provider: ProviderID, now: Date) -> String? {
        raw.filter { $0.provider == provider && $0.at <= now && $0.project != nil }
            .max(by: { $0.at < $1.at })?.project
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
