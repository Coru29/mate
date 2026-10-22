import Foundation
import Security
import MateCore

enum KeychainError: Error, CustomStringConvertible {
    case status(OSStatus)
    /// `/usr/bin/security` exit status.
    case tool(Int32)
    case timedOut

    /// The user denied (or could not be asked through) the access prompt.
    var isDenied: Bool {
        switch self {
        case .status(let s): s == errSecUserCanceled || s == errSecAuthFailed || s == errSecInteractionNotAllowed
        case .tool(let s): SecurityCommand.exit(s) == .denied
        case .timedOut: false
        }
    }

    var description: String {
        switch self {
        case .status(let s):
            let text = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
            return "keychain error \(s) (\(text))"
        case .tool(let s): return "security exited with \(s)"
        case .timedOut: return "security timed out"
        }
    }
}

/// Generic-password items of the login keychain. Never logs item data.
///
/// Item data is read and written through `/usr/bin/security` (see `SecurityCommand` for why): an access grant then
/// belongs to that Apple tool and survives every Mate rebuild and update. Attribute lookups stay in process; they
/// never prompt.
enum Keychain {
    /// Mate's own items never prompt through `security`, so a slow call is a stuck one.
    private static let ownTimeout: TimeInterval = 5
    /// Another app's item may wait on its access prompt while the user decides.
    private static let foreignTimeout: TimeInterval = 300
    /// Serializes operations on Mate's own items (a read may migrate, which writes).
    private static let lock = NSLock()

    // MARK: Another app's items (Claude Code's)

    /// The item's data, or nil when no such item exists. The first read may make macOS ask whether `security` may
    /// access the item; "Permitir siempre" lasts across Mate updates. A denied prompt throws. Call off the main
    /// thread: the call blocks while the prompt is up.
    static func readForeign(service: String, account: String?) throws -> Data? {
        let r = try SecurityTool.run(SecurityCommand.findArguments(service: service, account: account), timeout: foreignTimeout)
        switch SecurityCommand.exit(r.status) {
        case .ok: return SecurityCommand.decodeForeign(r.output)
        case .notFound: return nil
        case .denied, .failed: throw KeychainError.tool(r.status)
        }
    }

    // MARK: Mate's own items

    /// Mate's item, or nil when it does not exist. Items an earlier Mate wrote in process are read in process (macOS
    /// may ask one last time) and rewritten through `security`.
    static func read(service: String, account: String) throws -> Data? {
        try lock.withLock {
            switch try plan(service: service, account: account) {
            case .missing:
                return nil
            case .tool:
                let r = try SecurityTool.run(SecurityCommand.findArguments(service: service, account: account), timeout: ownTimeout)
                switch SecurityCommand.exit(r.status) {
                case .ok:
                    guard let data = SecurityCommand.decodeOwn(r.output) else { throw KeychainError.status(errSecDecode) }
                    return data
                case .notFound: return nil
                case .denied, .failed: throw KeychainError.tool(r.status)
                }
            case .legacy:
                guard let data = try legacyRead(service: service, account: account) else { return nil }
                if SecurityCommand.addLine(service: service, account: account, data: data) != nil {
                    do {
                        try writeUnlocked(service: service, account: account, data: data, current: .legacy)
                        Log.info("keychain: moved \(service) item to the security tool")
                    } catch {
                        Log.error("keychain: could not move \(service) item: \(error)")
                    }
                }
                return data
            }
        }
    }

    /// Creates or replaces Mate's own item.
    static func write(service: String, account: String, data: Data) throws {
        try lock.withLock {
            try writeUnlocked(service: service, account: account, data: data, current: try plan(service: service, account: account))
        }
    }

    /// Deletes Mate's own item; deleting a missing item is not an error.
    static func delete(service: String, account: String) throws {
        try lock.withLock {
            switch try plan(service: service, account: account) {
            case .missing: return
            case .tool: try toolDelete(service: service, account: account)
            case .legacy: try legacyDelete(service: service, account: account)
            }
        }
    }

    private static func writeUnlocked(service: String, account: String, data: Data, current: OwnKeychainItem) throws {
        guard let line = SecurityCommand.addLine(service: service, account: account, data: data) else {
            // Too long for one `security -i` line: kept in process, which asks again after an update.
            Log.error("keychain: \(service) item too long for the security tool; stored in process")
            if current == .tool { try toolDelete(service: service, account: account) }
            try legacyWrite(service: service, account: account, data: data)
            return
        }
        // `security` may not update an item Mate created in process (its partition is the old build's), and Mate
        // may delete it: replace it.
        if current == .legacy { try legacyDelete(service: service, account: account) }
        let r = try SecurityTool.run(["-i"], input: Data(line.utf8), timeout: ownTimeout)
        guard r.status == 0 else { throw KeychainError.tool(r.status) }
    }

    /// Mate cannot delete an item `security` created (errSecInvalidOwnerEdit); `security` can.
    private static func toolDelete(service: String, account: String) throws {
        let r = try SecurityTool.run(SecurityCommand.deleteArguments(service: service, account: account), timeout: ownTimeout)
        switch SecurityCommand.exit(r.status) {
        case .ok, .notFound: return
        case .denied, .failed: throw KeychainError.tool(r.status)
        }
    }

    private static func plan(service: String, account: String) throws -> OwnKeychainItem {
        var query = base(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        let comment = (out as? [String: Any])?[kSecAttrComment as String] as? String
        return OwnKeychainItem.plan(comment: comment, exists: true)
    }

    // MARK: In process (items written by earlier Mate builds)

    private static func legacyRead(service: String, account: String) throws -> Data? {
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return out as? Data
    }

    private static func legacyWrite(service: String, account: String, data: Data) throws {
        let query = base(service: service, account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.status(status) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.status(added) }
    }

    private static func legacyDelete(service: String, account: String) throws {
        let status = SecItemDelete(base(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    // MARK: Attributes only (no prompt)

    /// Whether an item exists, from its attributes only: no data is read, so no access prompt appears.
    static func exists(service: String, account: String? = nil) throws -> Bool {
        var query = base(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return true
    }

    /// The account attributes of every item of `service` (attributes only, no prompt).
    static func accountNames(service: String) -> [String] {
        var query = base(service: service, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    private static func base(service: String, account: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }
}

/// Mate's own copies of account credentials (the provider's native blob), keyed by account id.
protocol TokenVault: AnyObject {
    func read(_ provider: ProviderID, accountID: String) throws -> Data?
    func write(_ provider: ProviderID, accountID: String, data: Data) throws
    func delete(_ provider: ProviderID, accountID: String) throws
}

/// Service `io.github.coru29.Mate.<provider>`, account = Mate account id. Only Mate writes these items, so what it
/// read or wrote once is kept in memory: repeated reads (every fetch compares copies) do not run `security` again.
final class KeychainVault: TokenVault {
    static func service(_ p: ProviderID) -> String { "io.github.coru29.Mate.\(p.rawValue)" }

    private let lock = NSLock()
    private var cache: [String: Data] = [:]

    private func key(_ p: ProviderID, _ id: String) -> String { "\(p.rawValue)|\(id)" }

    func read(_ provider: ProviderID, accountID: String) throws -> Data? {
        if let hit = lock.withLock({ cache[key(provider, accountID)] }) { return hit }
        let data = try Keychain.read(service: Self.service(provider), account: accountID)
        if let data { lock.withLock { cache[key(provider, accountID)] = data } }
        return data
    }

    func write(_ provider: ProviderID, accountID: String, data: Data) throws {
        lock.withLock { cache[key(provider, accountID)] = nil }
        try Keychain.write(service: Self.service(provider), account: accountID, data: data)
        lock.withLock { cache[key(provider, accountID)] = data }
    }

    func delete(_ provider: ProviderID, accountID: String) throws {
        lock.withLock { cache[key(provider, accountID)] = nil }
        try Keychain.delete(service: Self.service(provider), account: accountID)
    }
}

/// In-memory vault for `--fake`: nothing reaches the keychain.
final class MemoryVault: TokenVault {
    private var items: [String: Data] = [:]

    func read(_ provider: ProviderID, accountID: String) throws -> Data? { items["\(provider.rawValue)|\(accountID)"] }
    func write(_ provider: ProviderID, accountID: String, data: Data) throws { items["\(provider.rawValue)|\(accountID)"] = data }
    func delete(_ provider: ProviderID, accountID: String) throws { items["\(provider.rawValue)|\(accountID)"] = nil }
}
