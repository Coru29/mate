import Foundation

/// The pure parts of keychain access through `/usr/bin/security`.
///
/// Why the tool: on the login keychain, an item's partition list ties it to its creator's code. Mate has no Team ID,
/// so that partition is the binary's cdhash, and every rebuild or update would ask for access again even though the
/// ACL's designated requirement still matches (measured: same certificate, new cdhash → errSecAuthFailed without UI).
/// Items written and read by Apple's `security` belong to its stable `apple-tool:` partition instead, and
/// "Permitir siempre" given to `security` for Claude Code's item survives every Mate update.
///
/// Secrets never go in argv: writes send one `security -i` command line on stdin; reads use `-w` and a pipe.
public enum SecurityCommand {
    public static let path = "/usr/bin/security"
    /// Comment (`icmt`) of the items Mate writes through `security`; their data is the base64 of Mate's bytes.
    public static let marker = "mate-security-v1"
    /// `security -i` splits command lines longer than 4096 characters (measured), which would store a truncated
    /// secret; longer lines are refused instead.
    public static let maxLineLength = 4000

    public enum Exit: Equatable {
        case ok, notFound, denied
        case failed(Int32)
    }

    /// `security` exits with the low byte of the failing OSStatus.
    public static func exit(_ status: Int32) -> Exit {
        switch status {
        case 0: .ok
        case 44: .notFound // errSecItemNotFound
        case 128, 51, 36: .denied // errSecUserCanceled ("Denegar"), errSecAuthFailed, errSecInteractionNotAllowed
        default: .failed(status)
        }
    }

    /// A double-quoted `security -i` word, or nil when the text cannot be one (a line break would end the command).
    public static func quoted(_ s: String) -> String? {
        guard !s.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { return nil }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The stdin line that creates or replaces Mate's item, or nil when it cannot be sent safely.
    public static func addLine(service: String, account: String, data: Data) -> String? {
        guard let s = quoted(service), let a = quoted(account) else { return nil }
        let line = "add-generic-password -U -s \(s) -a \(a) -j \"\(marker)\" -w \"\(data.base64EncodedString())\""
        return line.count <= maxLineLength ? line + "\n" : nil
    }

    public static func findArguments(service: String, account: String?) -> [String] {
        ["find-generic-password", "-s", service] + (account.map { ["-a", $0] } ?? []) + ["-w"]
    }

    public static func deleteArguments(service: String, account: String) -> [String] {
        ["delete-generic-password", "-s", service, "-a", account]
    }

    /// Mate's own item as printed by `-w`.
    public static func decodeOwn(_ output: Data) -> Data? {
        Data(base64Encoded: String(decoding: trimmingNewline(output), as: UTF8.self))
    }

    /// Another app's item as printed by `-w`: the text, or its hex form when `security` could not print it as text.
    public static func decodeForeign(_ output: Data) -> Data {
        let text = trimmingNewline(output)
        return hexDecoded(text) ?? text
    }

    private static func trimmingNewline(_ d: Data) -> Data {
        d.last == UInt8(ascii: "\n") ? d.dropLast() : d
    }

    private static func hexDecoded(_ d: Data) -> Data? {
        guard !d.isEmpty, d.count % 2 == 0 else { return nil }
        var out = Data(capacity: d.count / 2)
        var high: UInt8?
        for c in d {
            let v: UInt8
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): v = c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): v = c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): v = c - UInt8(ascii: "A") + 10
            default: return nil
            }
            if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
        }
        return out
    }
}

/// How to read one of Mate's own items, from its attributes (reading attributes never prompts).
public enum OwnKeychainItem: Equatable {
    case missing
    /// Written through `security`: read through it, silently, from any Mate build.
    case tool
    /// Written in process by an earlier Mate: read in process (one last prompt), then rewritten through `security`.
    case legacy

    public static func plan(comment: String?, exists: Bool) -> OwnKeychainItem {
        guard exists else { return .missing }
        return comment == SecurityCommand.marker ? .tool : .legacy
    }
}
