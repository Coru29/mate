import Foundation

public enum ClaudeLog {
    /// An `assistant` entry of a Claude Code JSONL transcript that carries `message.usage`; anything else is nil.
    public static func events(from line: Data, sessionID: String) -> TokenEvent? {
        guard let root = try? J.object(line),
              (try? J.string(root, "type")) == "assistant",
              let message = try? J.dict(root, "message"),
              let usage = try? J.dict(message, "usage"),
              let stamp = (try? J.string(root, "timestamp")) ?? nil,
              let at = J.date(stamp) else { return nil }
        func n(_ k: String) -> Int { ((try? J.double(usage, k)) ?? nil).flatMap { Int(exactly: $0) } ?? 0 }
        let msgID = (try? J.string(message, "id")) ?? nil
        let requestID = (try? J.string(root, "requestId")) ?? nil
        let cwd = (try? J.string(root, "cwd")) ?? nil
        return TokenEvent(
            provider: .claude, at: at,
            model: ((try? J.string(message, "model")) ?? nil) ?? "unknown",
            input: n("input_tokens"), output: n("output_tokens"),
            cacheRead: n("cache_read_input_tokens"), cacheWrite: n("cache_creation_input_tokens"),
            project: cwd.flatMap(projectName),
            sessionID: ((try? J.string(root, "sessionId")) ?? nil) ?? sessionID,
            dedupeKey: msgID.map { $0 + ":" + (requestID ?? "") })
    }

    static func projectName(_ cwd: String) -> String? {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
