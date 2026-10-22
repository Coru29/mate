import Foundation

/// Stateful parser for Codex rollout JSONL: `turn_context` lines set the model and cwd that later `token_count`
/// lines belong to, so feed lines in file order.
public struct CodexLogParser: Sendable {
    private var model = "unknown"
    private var project: String?

    public init() {}

    /// `token_count` events yield the `last_token_usage` delta (cached input is split out of `input_tokens`;
    /// `output_tokens` already includes reasoning) and the `rate_limits` windows. A null `info` yields no event.
    public mutating func parse(_ line: Data, sessionID: String) -> (TokenEvent?, rateLimits: [LimitWindow]?) {
        guard let root = try? J.object(line), let type = (try? J.string(root, "type")) ?? nil,
              let payload = (try? J.dict(root, "payload")) ?? nil else { return (nil, nil) }
        let at = ((try? J.string(root, "timestamp")) ?? nil).flatMap(J.date)

        if type == "turn_context" {
            if let m = (try? J.string(payload, "model")) ?? nil { model = m }
            if let cwd = (try? J.string(payload, "cwd")) ?? nil { project = ClaudeLog.projectName(cwd) }
            return (nil, nil)
        }
        guard type == "event_msg", (try? J.string(payload, "type")) == "token_count", let at else { return (nil, nil) }

        var limits: [LimitWindow]?
        if let rl = (try? J.dict(payload, "rate_limits")) ?? nil, let data = try? JSONSerialization.data(withJSONObject: rl) {
            limits = try? CodexUsage.windows(fromLogRateLimits: data, now: at)
        }
        var event: TokenEvent?
        if let info = (try? J.dict(payload, "info")) ?? nil, let last = (try? J.dict(info, "last_token_usage")) ?? nil {
            func n(_ k: String) -> Int { ((try? J.double(last, k)) ?? nil).flatMap { Int(exactly: $0) } ?? 0 }
            let cached = n("cached_input_tokens")
            event = TokenEvent(provider: .codex, at: at, model: model, input: max(0, n("input_tokens") - cached),
                               output: n("output_tokens"), cacheRead: cached, cacheWrite: 0,
                               project: project, sessionID: sessionID, dedupeKey: nil)
        }
        return (event, limits)
    }
}
