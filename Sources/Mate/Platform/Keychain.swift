import Foundation
import Security
import MateCore

enum KeychainError: Error, CustomStringConvertible {
    case status(OSStatus)

    /// The user denied (or could not be asked through) the access prompt.
    var isDenied: Bool {
        switch self {
        case .status(let s): s == errSecUserCanceled || s == errSecAuthFailed || s == errSecInteractionNotAllowed
        }
    }

    var description: String {
        switch self {
        case .status(let s):
            let text = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
            return "keychain error \(s) (\(text))"
        }
    }
}

/// Generic-password items of the login keychain. Never logs item data.
enum Keychain {
    /// The item's data, or nil when no such item exists. Reading another app's item (Claude Code's) makes macOS show
    /// its access prompt; a denied prompt throws. Call off the main thread: the call blocks while the prompt is up.
    static func read(service: String, account: String?) throws -> Data? {
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return out as? Data
    }

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

    /// Creates or replaces Mate's own item.
    static func write(service: String, account: String, data: Data) throws {
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

    /// Deletes an item; deleting a missing item is not an error.
    static func delete(service: String, account: String) throws {
        let status = SecItemDelete(base(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    /// The account attribute of the first item of `service` (attributes only, no prompt).
    static func accountName(service: String) -> String? {
        var query = base(service: service, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let attrs = out as? [String: Any] else { return nil }
        return attrs[kSecAttrAccount as String] as? String
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

/// Service `io.github.coru29.Mate.<provider>`, account = Mate account id.
final class KeychainVault: TokenVault {
    static func service(_ p: ProviderID) -> String { "io.github.coru29.Mate.\(p.rawValue)" }

    func read(_ provider: ProviderID, accountID: String) throws -> Data? {
        try Keychain.read(service: Self.service(provider), account: accountID)
    }

    func write(_ provider: ProviderID, accountID: String, data: Data) throws {
        try Keychain.write(service: Self.service(provider), account: accountID, data: data)
    }

    func delete(_ provider: ProviderID, accountID: String) throws {
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
