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

    public init(provider: ProviderID, at: Date, model: String, input: Int, output: Int, cacheRead: Int,
                cacheWrite: Int, project: String?, sessionID: String, dedupeKey: String?) {
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
    }

    /// Input + output + cache read + cache write.
    public var totalTokens: Int { input + output + cacheRead + cacheWrite }
}
