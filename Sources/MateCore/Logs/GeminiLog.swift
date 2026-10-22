import Foundation

public enum GeminiLog {
    /// UNVERIFIED: Gemini CLI's local logs (`~/.gemini/tmp/<hash>/logs.json`) hold the user's prompts, not token
    /// counts, so there is nothing to aggregate. Kept as an empty stub so callers have a uniform shape.
    public static func events(from line: Data, sessionID: String) -> [TokenEvent] { [] }
}
