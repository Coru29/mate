import Foundation

/// Which account owned each agent config dir over time, so token events (which only know their log's config dir)
/// can be attributed to the account that was active at the event's time. Recorded by `UsageStore` on every
/// reconcile; an entry is appended only when the account of a dir changes.
public struct SwitchHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var configDir: String
        public var accountID: String
        public var from: Date
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func record(configDir: String, accountID: String, at: Date) {
        if let last = entries.filter({ $0.configDir == configDir }).max(by: { $0.from < $1.from }),
           last.accountID == accountID { return }
        entries.append(Entry(configDir: configDir, accountID: accountID, from: at))
    }

    public mutating func renameAccount(from old: String, to new: String) {
        for i in entries.indices where entries[i].accountID == old { entries[i].accountID = new }
    }

    /// The account that owned `configDir` at `at`. Before the first record of the dir, the first recorded account
    /// (the best guess for history older than Mate's own bookkeeping). Nil when the dir was never recorded.
    public func account(forConfigDir dir: String, at: Date) -> String? {
        let mine = entries.filter { $0.configDir == dir }.sorted { $0.from < $1.from }
        return (mine.last { $0.from <= at } ?? mine.first)?.accountID
    }
}
