import Testing
import CoreGraphics
@testable import MateCore

/// Events given as the fingers' motion (negative: left), fed as a natural-scrolling trackpad reports them.
private func run(_ events: [(SwipeStepper.Phase, Bool, CGFloat)]) -> [Int] {
    var s = SwipeStepper(threshold: 40)
    return events.compactMap { s.feed(phase: $0.0, momentum: $0.1, deltaX: -$0.2, deltaY: 0, invertedFromDevice: true) }
}

@Test func swipeThenMomentumStepsOnce() {
    // A long swipe to the left, then the momentum flick (phase none, momentum set) carrying on.
    let swipe: [(SwipeStepper.Phase, Bool, CGFloat)] = [(.mayBegin, false, 0), (.began, false, -5)]
        + Array(repeating: (.changed, false, -15), count: 10) + [(.ended, false, 0)]
    let momentum: [(SwipeStepper.Phase, Bool, CGFloat)] = Array(repeating: (.none, true, -30), count: 20)
    #expect(run(swipe + momentum) == [1])
}

@Test func momentumAloneNeverSteps() {
    #expect(run(Array(repeating: (.none, true, -60), count: 10)) == [])
}

@Test func eachSwipeStepsOnceInItsDirection() {
    let left: [(SwipeStepper.Phase, Bool, CGFloat)] = [(.began, false, 0), (.changed, false, -50), (.changed, false, -50), (.ended, false, 0)]
    let right: [(SwipeStepper.Phase, Bool, CGFloat)] = [(.began, false, 0), (.changed, false, 30), (.changed, false, 30), (.ended, false, 0)]
    #expect(run(left + left + right) == [1, 1, -1])
}

@Test func shortSwipeAndVerticalScrollDoNotStep() {
    var s = SwipeStepper(threshold: 40)
    _ = s.feed(phase: .began, momentum: false, deltaX: 0, deltaY: 0, invertedFromDevice: false)
    #expect(s.feed(phase: .changed, momentum: false, deltaX: -30, deltaY: 0, invertedFromDevice: false) == nil)
    // Mostly vertical.
    #expect(s.feed(phase: .changed, momentum: false, deltaX: -30, deltaY: -80, invertedFromDevice: false) == nil)
    _ = s.feed(phase: .ended, momentum: false, deltaX: 0, deltaY: 0, invertedFromDevice: false)
    // A mouse wheel: no phase.
    #expect(s.feed(phase: .none, momentum: false, deltaX: -100, deltaY: 0, invertedFromDevice: false) == nil)
}

/// Content follows the fingers whatever the "natural scrolling" setting: fingers to the left is the next account.
@Test func fingersLeftIsNextWithAndWithoutNaturalScrolling() {
    for inverted in [true, false] {
        // The same physical swipe to the left, as each setting reports it.
        let deltaX: CGFloat = inverted ? 25 : -25
        var s = SwipeStepper(threshold: 40)
        _ = s.feed(phase: .began, momentum: false, deltaX: 0, deltaY: 0, invertedFromDevice: inverted)
        let steps = (0..<3).compactMap { _ in
            s.feed(phase: .changed, momentum: false, deltaX: deltaX, deltaY: 0, invertedFromDevice: inverted)
        }
        #expect(steps == [1], "invertedFromDevice: \(inverted)")
        #expect(SwipeStepper.fingerDX(scrollingDeltaX: deltaX, invertedFromDevice: inverted) < 0)
        // And to the right: the previous account.
        var r = SwipeStepper(threshold: 40)
        _ = r.feed(phase: .began, momentum: false, deltaX: 0, deltaY: 0, invertedFromDevice: inverted)
        let back = (0..<3).compactMap { _ in
            r.feed(phase: .changed, momentum: false, deltaX: -deltaX, deltaY: 0, invertedFromDevice: inverted)
        }
        #expect(back == [-1], "invertedFromDevice: \(inverted)")
    }
}
