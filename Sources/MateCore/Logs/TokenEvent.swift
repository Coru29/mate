import Foundation

/// One request's token usage as read from a local agent log.
public struct TokenEvent: Codable, Hashable, Sendable {
    public var provider: ProviderID
    public var at: Date
    public var model: String
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var project: String?
    public var sessionID: String
    public var dedupeKey: String?
    /// Config dir of the log file the event came from ("~/.claude"); set by the log indexer, used for account attribution.
    public var logDir: String?

    public init(provider: ProviderID, at: Date, model: String, input: Int, output: Int, cacheRead: Int,
                cacheWrite: Int, project: String?, sessionID: String, dedupeKey: String?, logDir: String? = nil) {
        self.provider = provider
        self.at = at
        self.model = model
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.project = project
        self.sessionID = sessionID
        self.dedupeKey = dedupeKey
        self.logDir = logDir
    }

    /// Input + output + cache read + cache write.
    public var totalTokens: Int { input + output + cacheRead + cacheWrite }
}
