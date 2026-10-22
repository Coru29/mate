import Foundation

/// Thrown by every credential and response parser on input it cannot use.
public enum ParseError: Error, Equatable {
    case malformed(String)
}

/// Tolerant JSON accessors: an absent or `null` key is `nil`, a key of the wrong type throws.
enum J {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any] else {
            throw ParseError.malformed("root is not a JSON object")
        }
        return o
    }

    private static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func double(_ d: [String: Any], _ k: String) throws -> Double? {
        guard let v = d[k], !(v is NSNull) else { return nil }
        if isBool(v) { throw ParseError.malformed("\(k) is a boolean") }
        if let n = v as? NSNumber { return n.doubleValue }
        throw ParseError.malformed("\(k) is not a number")
    }

    static func string(_ d: [String: Any], _ k: String) throws -> String? {
        guard let v = d[k], !(v is NSNull) else { return nil }
        guard let s = v as? String else { throw ParseError.malformed("\(k) is not a string") }
        return s
    }

    static func bool(_ d: [String: Any], _ k: String) throws -> Bool? {
        guard let v = d[k], !(v is NSNull) else { return nil }
        guard isBool(v), let n = v as? NSNumber else { throw ParseError.malformed("\(k) is not a boolean") }
        return n.boolValue
    }

    static func dict(_ d: [String: Any], _ k: String) throws -> [String: Any]? {
        guard let v = d[k], !(v is NSNull) else { return nil }
        guard let o = v as? [String: Any] else { throw ParseError.malformed("\(k) is not an object") }
        return o
    }

    static func array(_ d: [String: Any], _ k: String) throws -> [Any]? {
        guard let v = d[k], !(v is NSNull) else { return nil }
        guard let a = v as? [Any] else { throw ParseError.malformed("\(k) is not an array") }
        return a
    }

    /// ISO-8601 with or without fractional seconds and with `Z` or an offset; also bare `yyyy-MM-dd` (UTC).
    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }

    /// Like `string` + `date`, but an unparseable string is an error.
    static func dateValue(_ d: [String: Any], _ k: String) throws -> Date? {
        guard let s = try string(d, k) else { return nil }
        guard let date = date(s) else { throw ParseError.malformed("\(k) is not a date") }
        return date
    }

    /// "12,40" style amount with comma decimals; whole numbers drop the fraction when `trim` is set.
    static func amount(_ v: Double, trim: Bool = false) -> String {
        if trim, v == v.rounded(), let i = Int(exactly: v) { return String(i) }
        return String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",")
    }
}
