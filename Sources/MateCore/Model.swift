import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable {
    case claude, codex, cursor, gemini, copilot, grok

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .gemini: "Gemini"
        case .copilot: "Copilot"
        case .grok: "Grok"
        }
    }
}

public enum WindowKind: Codable, Hashable, Sendable {
    case session
    case weekly
    case weeklyModel(String)
    case billingCycle
    case monthlyBudget
    case dailyModel(String)
    case premiumRequests

    /// Stable string form, for dictionary keys and file storage.
    public var key: String {
        switch self {
        case .session: "session"
        case .weekly: "weekly"
        case .weeklyModel(let m): "weeklyModel:\(m)"
        case .billingCycle: "billingCycle"
        case .monthlyBudget: "monthlyBudget"
        case .dailyModel(let m): "dailyModel:\(m)"
        case .premiumRequests: "premiumRequests"
        }
    }
}

public struct LimitWindow: Codable, Hashable, Sendable {
    public var kind: WindowKind
    public var usedPercent: Double
    public var resetsAt: Date?
    public var duration: TimeInterval?
    /// Spend text such as "USD 12,40 de 20".
    public var detail: String?

    public init(kind: WindowKind, usedPercent: Double, resetsAt: Date? = nil,
                duration: TimeInterval? = nil, detail: String? = nil) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.duration = duration
        self.detail = detail
    }
}

public struct UsageSnapshot: Codable, Sendable {
    public var accountID: String
    public var windows: [LimitWindow]
    public var fetchedAt: Date

    public init(accountID: String, windows: [LimitWindow], fetchedAt: Date) {
        self.accountID = accountID
        self.windows = windows
        self.fetchedAt = fetchedAt
    }
}

public struct Sample: Codable, Sendable {
    public var at: Date
    public var percent: Double

    public init(at: Date, percent: Double) {
        self.at = at
        self.percent = percent
    }
}
