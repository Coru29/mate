import CoreGraphics

/// Turns a trackpad's scroll events into account steps: one physical swipe is exactly one step.
/// Only phase-driven events count (a gesture's `began` / `changed` / `ended`); momentum events and events with no
/// phase (mouse wheels) are ignored entirely, so the flick that follows a swipe never steps again.
public struct SwipeStepper: Sendable {
    public enum Phase: Sendable { case none, mayBegin, began, changed, ended, cancelled }

    /// Horizontal finger travel, in points, before the swipe steps.
    public let threshold: CGFloat
    private var accumulated: CGFloat = 0
    private var stepped = false

    public init(threshold: CGFloat) {
        self.threshold = threshold
    }

    /// The fingers' own horizontal motion (negative: to the left) from an event's `scrollingDeltaX`, whatever the
    /// "natural scrolling" setting: `isDirectionInvertedFromDevice` flips the deltas, so it flips them back. The
    /// sign was set by hand on the user's trackpad (the theory-first guess had swipes backwards).
    public static func fingerDX(scrollingDeltaX: CGFloat, invertedFromDevice: Bool) -> CGFloat {
        invertedFromDevice ? -scrollingDeltaX : scrollingDeltaX
    }

    /// Feeds one event (`scrollingDeltaX`, `scrollingDeltaY`, `isDirectionInvertedFromDevice` as the event has
    /// them). Returns -1 (fingers to the left: the pages slide to the right and the previous account comes in from
    /// the left, as the user asked) or +1 (fingers to the right: the next one, from the right), once per swipe.
    public mutating func feed(phase: Phase, momentum: Bool, deltaX: CGFloat, deltaY: CGFloat,
                              invertedFromDevice: Bool) -> Int? {
        let fingerDX = Self.fingerDX(scrollingDeltaX: deltaX, invertedFromDevice: invertedFromDevice)
        guard !momentum else { return nil }
        switch phase {
        case .none:
            return nil
        case .mayBegin, .began:
            reset()
            return nil
        case .ended, .cancelled:
            reset()
            return nil
        case .changed:
            break
        }
        guard !stepped, abs(fingerDX) > abs(deltaY) else { return nil }
        accumulated += fingerDX
        guard abs(accumulated) >= threshold else { return nil }
        stepped = true
        return accumulated < 0 ? -1 : 1
    }

    public mutating func reset() {
        accumulated = 0
        stepped = false
    }
}
