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

/// The window closest to trouble: highest `usedPercent / max(expectedPercent, 1)`.
/// Windows without duration or reset date rank by `usedPercent` alone.
public func tightestWindow(_ windows: [LimitWindow], now: Date) -> LimitWindow? {
    func score(_ w: LimitWindow) -> Double {
        guard let expected = expectedPercent(w, now: now) else { return w.usedPercent }
        return w.usedPercent / max(expected, 1)
    }
    return windows.max { score($0) < score($1) }
}
