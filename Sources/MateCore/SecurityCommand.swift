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

    /// A double-quoted `security -i` word, or nil when the text holds a quote, a backslash (escapes inside words
    /// are not relied on) or a line break (it would end the command).
    public static func quoted(_ s: String) -> String? {
        guard !s.contains(where: { "\"\\\n\r\0".contains($0) }) else { return nil }
        return "\"" + s + "\""
    }

    /// The stdin line that creates or replaces one item, or nil when it cannot be sent whole.
    public static func addLine(service: String, account: String, comment: String, data: Data) -> String? {
        guard let s = quoted(service), let a = quoted(account), let c = quoted(comment) else { return nil }
        let line = "add-generic-password -U -s \(s) -a \(a) -j \(c) -w \"\(data.base64EncodedString())\""
        return line.utf8.count <= maxLineLength ? line + "\n" : nil
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
    /// Only for JSON items (Claude Code's): JSON never starts with a hex digit pair, so the fallback cannot misfire;
    /// an arbitrary all-hex text would be decoded wrongly.
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
        return OwnItemLayout.head(comment: comment) == nil ? .legacy : .tool
    }
}

public struct OwnItemPart: Equatable {
    public let account: String
    public let comment: String
    public let data: Data

    public init(account: String, comment: String, data: Data) {
        self.account = account
        self.comment = comment
        self.data = data
    }
}

/// How one of Mate's values is laid out in `security`-written items. A value that fits one `security -i` line is a
/// single item (account = Mate account id). A longer one is split: chunks at `<id>#<generation>.<n>`, then the head
/// at `<id>` holding the first part, its comment naming the chunk count and generation. Writing the head last makes
/// the switch atomic: until the head changes, the previous value and its chunks stay whole.
public enum OwnItemLayout {
    public enum Head: Equatable {
        case single
        case chunked(count: Int, generation: String)
    }

    public static func head(comment: String?) -> Head? {
        guard let comment else { return nil }
        if comment == SecurityCommand.marker { return .single }
        let words = comment.split(separator: " ")
        guard words.count == 3, words[0] == SecurityCommand.marker,
              words[1].hasPrefix("chunks="), let count = Int(words[1].dropFirst(7)), count > 1,
              words[2].hasPrefix("gen="), words[2].count > 4 else { return nil }
        return .chunked(count: count, generation: String(words[2].dropFirst(4)))
    }

    static func comment(_ head: Head) -> String {
        switch head {
        case .single: SecurityCommand.marker
        case .chunked(let count, let generation): "\(SecurityCommand.marker) chunks=\(count) gen=\(generation)"
        }
    }

    public static func chunkAccount(_ account: String, generation: String, index: Int) -> String {
        "\(account)#\(generation).\(index)"
    }

    /// The chunk items after the head, in order.
    public static func chunkAccounts(_ head: Head, of account: String) -> [String] {
        guard case .chunked(let count, let generation) = head else { return [] }
        return (1..<count).map { chunkAccount(account, generation: generation, index: $0) }
    }

    public static func isChunk(_ name: String, of account: String) -> Bool {
        name.hasPrefix(account + "#")
    }

    /// The items to write, head last; nil when the names cannot be sent to `security`.
    public static func parts(service: String, account: String, data: Data, generation: String) -> [OwnItemPart]? {
        if SecurityCommand.addLine(service: service, account: account, comment: SecurityCommand.marker, data: data) != nil {
            return [OwnItemPart(account: account, comment: SecurityCommand.marker, data: data)]
        }
        // Budget each part for the longest name and comment it could carry.
        let worstAccount = chunkAccount(account, generation: generation, index: 99_999)
        let worstComment = comment(.chunked(count: 99_999, generation: generation))
        guard let empty = SecurityCommand.addLine(service: service, account: worstAccount, comment: worstComment, data: Data())
        else { return nil }
        let partSize = (SecurityCommand.maxLineLength + 1 - empty.utf8.count) / 4 * 3
        guard partSize > 0 else { return nil }
        let pieces = stride(from: 0, to: data.count, by: partSize).map { data.subdata(in: $0..<min($0 + partSize, data.count)) }
        let head = Head.chunked(count: pieces.count, generation: generation)
        let names = chunkAccounts(head, of: account)
        return zip(names, pieces.dropFirst()).map { OwnItemPart(account: $0, comment: SecurityCommand.marker, data: $1) }
            + [OwnItemPart(account: account, comment: comment(head), data: pieces[0])]
    }

    public static func join(head: Data, chunks: [Data]) -> Data {
        chunks.reduce(into: head) { $0.append($1) }
    }
}
