import Foundation

public enum PaceState: Equatable, Sendable {
    case onTrack
    case ahead
    case runsOut(at: Date)
    case limitReached(resetsAt: Date?)
}

/// Percent of the window's time already elapsed (0...100), or nil without duration or reset date.
private func expectedPercent(_ window: LimitWindow, now: Date) -> Double? {
    guard let duration = window.duration, duration > 0, let resetsAt = window.resetsAt else { return nil }
    let elapsed = duration - resetsAt.timeIntervalSince(now)
    return min(max(elapsed / duration * 100, 0), 100)
}

public func pace(for window: LimitWindow, samples: [Sample], now: Date) -> PaceState? {
    if window.usedPercent >= 100 { return .limitReached(resetsAt: window.resetsAt) }
    guard let duration = window.duration, duration > 0, let resetsAt = window.resetsAt,
          let expected = expectedPercent(window, now: now) else { return nil }
    let used = window.usedPercent
    if used <= expected + 5 { return .onTrack }

    // Rate in points per second: first-to-last sample over the last hour, else the whole window.
    let recent = samples.filter { $0.at >= now.addingTimeInterval(-3600) && $0.at <= now }
        .sorted { $0.at < $1.at }
    var rate: Double
    if let first = recent.first, let last = recent.last, last.at > first.at {
        rate = (last.percent - first.percent) / last.at.timeIntervalSince(first.at)
    } else {
        rate = used / (expected / 100 * duration)
    }
    if !rate.isFinite { rate = 0 }
    guard rate > 0 else { return .ahead }
    let exhaustion = now.addingTimeInterval((100 - used) / rate)
    return exhaustion < resetsAt ? .runsOut(at: exhaustion) : .ahead
}

/// The window closest to trouble.
/// 1. Any window at 100 % or more wins (ties: earliest reset, no reset last).
/// 2. Otherwise timed windows score `usedPercent / max(expectedPercent, 1)` and
///    untimed ones `usedPercent / 100`, so both sit on a comparable scale.
public func tightestWindow(_ windows: [LimitWindow], now: Date) -> LimitWindow? {
    let reached = windows.filter { $0.usedPercent >= 100 }
    if !reached.isEmpty {
        return reached.min {
            ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture)
        }
    }
    func score(_ w: LimitWindow) -> Double {
        guard let expected = expectedPercent(w, now: now) else { return w.usedPercent / 100 }
        return w.usedPercent / max(expected, 1)
    }
    return windows.max { score($0) < score($1) }
}

/// The window the pill shows. Nobody watches the week until it is running out, so the session is the default.
/// 1. Any window at 100 % or more (earliest reset).
/// 2. Else the highest weekly window (all models or one model) at 80 % or more.
/// 3. Else the session.
/// 4. Else (providers without a session) the tightest window.
public func pillWindow(_ windows: [LimitWindow], now: Date) -> LimitWindow? {
    if windows.contains(where: { $0.usedPercent >= 100 }) { return tightestWindow(windows, now: now) }
    let weekly = windows.filter {
        switch $0.kind {
        case .weekly, .weeklyModel: $0.usedPercent >= 80
        default: false
        }
    }
    if let high = weekly.max(by: { $0.usedPercent < $1.usedPercent }) { return high }
    return windows.first { $0.kind == .session } ?? tightestWindow(windows, now: now)
}
