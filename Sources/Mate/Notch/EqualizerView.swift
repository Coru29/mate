import AppKit
import SwiftUI

/// Three small equalizer bars. While playing they bounce with repeating Core Animation animations, which the
/// render server runs on its own (the app does no work per frame); paused they stand still at rest heights.
final class EqualizerView: NSView {
    static let barWidth: CGFloat = 2
    static let gap: CGFloat = 1.5
    private static let rest: [CGFloat] = [0.35, 0.7, 0.5]
    private static let durations: [CFTimeInterval] = [0.42, 0.55, 0.36]
    private static let lows: [CGFloat] = [0.25, 0.3, 0.2]

    private var bars: [CALayer] = []
    private(set) var isAnimating = false
    var color: NSColor = .white {
        didSet { for b in bars { b.backgroundColor = color.cgColor } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<3 {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.backgroundColor = color.cgColor
            bar.cornerRadius = Self.barWidth / 2
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let total = 3 * Self.barWidth + 2 * Self.gap
        let x0 = (bounds.width - total) / 2
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: bounds.height)
            bar.position = CGPoint(x: x0 + CGFloat(i) * (Self.barWidth + Self.gap) + Self.barWidth / 2, y: 0)
            bar.transform = CATransform3DMakeScale(1, Self.rest[i], 1)
        }
        CATransaction.commit()
    }

    /// Starts or stops the bounce (never with Reduce Motion).
    func setAnimating(_ on: Bool) {
        let on = on && !NotchMotion.reduceMotion
        guard on != isAnimating else { return }
        isAnimating = on
        for (i, bar) in bars.enumerated() {
            guard on else { bar.removeAnimation(forKey: "bounce"); continue }
            let a = CABasicAnimation(keyPath: "transform.scale.y")
            a.fromValue = Self.lows[i]
            a.toValue = 1
            a.duration = Self.durations[i]
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Out of step with each other from the first frame.
            a.timeOffset = Double(i) * 0.17
            bar.add(a, forKey: "bounce")
        }
    }

    /// Animations are dropped when the layer leaves a window; put them back when it returns.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard isAnimating else { return }
        isAnimating = false
        if window != nil { setAnimating(true) } else { for b in bars { b.removeAnimation(forKey: "bounce") } }
    }
}

/// The bars for the panel's card.
struct Equalizer: NSViewRepresentable {
    var playing: Bool
    var color: NSColor

    func makeNSView(context: Context) -> EqualizerView { EqualizerView() }

    func updateNSView(_ view: EqualizerView, context: Context) {
        view.color = color
        view.setAnimating(playing)
    }
}
