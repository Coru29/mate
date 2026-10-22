import Foundation
import Security
import MateCore

enum KeychainError: Error, CustomStringConvertible {
    case status(OSStatus)
    /// `/usr/bin/security` exit status.
    case tool(Int32)
    case timedOut
    /// A name `security -i` cannot take verbatim (quote, backslash, line break).
    case unsupportedName
    /// What `security` stored did not read back equal, or a chunk is missing.
    case mismatch

    /// The user denied (or could not be asked through) the access prompt.
    var isDenied: Bool {
        switch self {
        case .status(let s): s == errSecUserCanceled || s == errSecAuthFailed || s == errSecInteractionNotAllowed
        case .tool(let s): SecurityCommand.exit(s) == .denied
        case .timedOut, .unsupportedName, .mismatch: false
        }
    }

    var description: String {
        switch self {
        case .status(let s):
            let text = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
            return "keychain error \(s) (\(text))"
        case .tool(let s): return "security exited with \(s)"
        case .timedOut: return "security timed out"
        case .unsupportedName: return "name not accepted by security"
        case .mismatch: return "keychain value incomplete or not read back equal"
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

    /// Mate's value, or nil when it does not exist. Items an earlier Mate wrote in process are read in process (macOS
    /// may ask one last time) and moved to `security`-written items.
    static func read(service: String, account: String) throws -> Data? {
        try lock.withLock {
            switch try state(service: service, account: account) {
            case .missing:
                return nil
            case .tool(let head):
                return try toolRead(service: service, account: account, head: head)
            case .legacy:
                guard let data = try legacyRead(service: service, account: account) else { return nil }
                do {
                    try replaceLegacy(service: service, account: account, data: data, old: data)
                    Log.info("keychain: moved \(service) item to the security tool")
                } catch {
                    Log.error("keychain: could not move \(service) item, kept as it was: \(error)")
                }
                return data
            }
        }
    }

    /// Creates or replaces Mate's value. The previous value is removed only after the new one reads back equal; on
    /// any failure the previous value is kept (or put back) and the error is rethrown.
    static func write(service: String, account: String, data: Data) throws {
        try lock.withLock {
            switch try state(service: service, account: account) {
            case .missing, .tool:
                try toolWrite(service: service, account: account, data: data)
            case .legacy:
                // Read so it can be put back if the move fails (macOS may ask; it is the item's last in-process read).
                let old = try? legacyRead(service: service, account: account)
                try replaceLegacy(service: service, account: account, data: data, old: old)
            }
        }
    }

    /// Deletes Mate's value and all its chunks; deleting a missing value is not an error.
    static func delete(service: String, account: String) throws {
        try lock.withLock {
            if case .legacy = try state(service: service, account: account) {
                try legacyDelete(service: service, account: account)
            }
            try toolDeleteAll(service: service, account: account)
        }
    }

    private enum State {
        case missing, legacy
        case tool(OwnItemLayout.Head)
    }

    /// From the head item's attributes (never prompts).
    private static func state(service: String, account: String) throws -> State {
        var query = base(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        let comment = (out as? [String: Any])?[kSecAttrComment as String] as? String
        return OwnItemLayout.head(comment: comment).map(State.tool) ?? .legacy
    }

    /// A security-tool item cannot share its name with the in-process one, so the old item goes first; if the new
    /// value does not land whole, the partial items are removed and the old item is put back.
    private static func replaceLegacy(service: String, account: String, data: Data, old: Data?) throws {
        guard OwnItemLayout.parts(service: service, account: account, data: data, generation: "check") != nil else {
            throw KeychainError.unsupportedName
        }
        try legacyDelete(service: service, account: account)
        do {
            try toolWrite(service: service, account: account, data: data)
        } catch {
            try? toolDeleteAll(service: service, account: account)
            if let old {
                do { try legacyWrite(service: service, account: account, data: old) } catch {
                    Log.error("keychain: could not put back the \(service) item: \(error)")
                }
            }
            throw error
        }
    }

    /// Chunks first, each read back; then the head, the atomic switch; then the previous value's chunks are dropped.
    private static func toolWrite(service: String, account: String, data: Data) throws {
        let generation = String(UInt32.random(in: .min ... .max), radix: 36)
        guard let parts = OwnItemLayout.parts(service: service, account: account, data: data, generation: generation),
              let head = parts.last else { throw KeychainError.unsupportedName }
        let chunks = parts.dropLast()
        do {
            for part in chunks { try toolAddVerified(service: service, part) }
        } catch {
            // The head still names the previous chunks: the previous value is untouched.
            for part in chunks { try? toolDelete(service: service, account: part.account) }
            throw error
        }
        // A failed or timed-out head write may still have landed, so both generations' chunks stay: whichever head
        // is stored reads whole. A later successful write drops the stale ones.
        try toolAddVerified(service: service, head)
        let current = Set(chunks.map(\.account))
        for name in (try? accountNames(service: service)) ?? [] where OwnItemLayout.isChunk(name, of: account) && !current.contains(name) {
            do { try toolDelete(service: service, account: name) } catch {
                Log.error("keychain: could not drop a stale \(service) chunk: \(error)")
            }
        }
    }

    private static func toolAddVerified(service: String, _ part: OwnItemPart) throws {
        guard let line = SecurityCommand.addLine(service: service, account: part.account, comment: part.comment, data: part.data)
        else { throw KeychainError.unsupportedName }
        let r = try SecurityTool.run(["-i"], input: Data(line.utf8), timeout: ownTimeout)
        guard r.status == 0 else { throw KeychainError.tool(r.status) }
        guard try toolReadOne(service: service, account: part.account) == part.data else { throw KeychainError.mismatch }
    }

    private static func toolRead(service: String, account: String, head: OwnItemLayout.Head) throws -> Data? {
        guard let first = try toolReadOne(service: service, account: account) else { return nil }
        let chunks = try OwnItemLayout.chunkAccounts(head, of: account).map { name -> Data in
            guard let chunk = try toolReadOne(service: service, account: name) else { throw KeychainError.mismatch }
            return chunk
        }
        return OwnItemLayout.join(head: first, chunks: chunks)
    }

    private static func toolReadOne(service: String, account: String) throws -> Data? {
        let r = try SecurityTool.run(SecurityCommand.findArguments(service: service, account: account), timeout: ownTimeout)
        switch SecurityCommand.exit(r.status) {
        case .ok:
            guard let data = SecurityCommand.decodeOwn(r.output) else { throw KeychainError.status(errSecDecode) }
            return data
        case .notFound: return nil
        case .denied, .failed: throw KeychainError.tool(r.status)
        }
    }

    /// The head and every chunk of `account`.
    private static func toolDeleteAll(service: String, account: String) throws {
        for name in (try? accountNames(service: service)) ?? [] where OwnItemLayout.isChunk(name, of: account) {
            try toolDelete(service: service, account: name)
        }
        if case .tool = try state(service: service, account: account) { try toolDelete(service: service, account: account) }
    }

    /// Mate cannot delete an item `security` created (errSecInvalidOwnerEdit); `security` can.
    private static func toolDelete(service: String, account: String) throws {
        let r = try SecurityTool.run(SecurityCommand.deleteArguments(service: service, account: account), timeout: ownTimeout)
        switch SecurityCommand.exit(r.status) {
        case .ok, .notFound: return
        case .denied, .failed: throw KeychainError.tool(r.status)
        }
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

    /// The account attributes of every item of `service` (attributes only, no prompt). Throws on any status but
    /// success and "not found" (a locked or missing keychain is not an empty one).
    static func accountNames(service: String) throws -> [String] {
        var query = base(service: service, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let items = out as? [[String: Any]] else { throw KeychainError.status(errSecDecode) }
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
    /// One instance, so every reader (the store, Grok's key) shares the cache.
    static let shared = KeychainVault()

    private init() {}

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
