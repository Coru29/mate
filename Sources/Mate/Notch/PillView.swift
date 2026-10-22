import AppKit

/// The pill right of the notch: a ring (2.5 pt stroke) and the percent of the tightest window. Plain layers, no
/// SwiftUI, nothing redrawn unless the value changes.
final class PillView: NSView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let label = CATextLayer()
    private var shown: (text: String, fraction: CGFloat, tone: Tone)?

    static let ringDiameter: CGFloat = 13
    static let lineWidth: CGFloat = 2.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, fill] {
            l.fillColor = nil
            l.lineWidth = Self.lineWidth
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.fontSize = 11
        label.alignmentMode = .left
        label.truncationMode = .none
        layer?.addSublayer(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        label.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let d = Self.ringDiameter
        let ring = CGRect(x: 7, y: (bounds.height - d) / 2, width: d, height: d)
        // Starts at 12 o'clock and runs clockwise.
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: ring.midX, y: ring.midY), radius: d / 2, startAngle: .pi / 2,
                    endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        track.path = path
        fill.path = path
        let textHeight: CGFloat = 14
        label.frame = CGRect(x: ring.maxX + 5, y: (bounds.height - textHeight) / 2 - 1,
                             width: bounds.width - ring.maxX - 5, height: textHeight)
        CATransaction.commit()
    }

    /// `percent` nil shows a dash and an empty ring.
    func update(percent: Double?, tone: Tone) {
        let text = percent.map(NotchText.percent) ?? "–"
        let fraction = CGFloat(min(max(percent ?? 0, 0), 100) / 100)
        if let s = shown, s.text == text, s.fraction == fraction, s.tone == tone { return }
        shown = (text, fraction, tone)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.strokeColor = tone.nsColor.cgColor
        fill.strokeEnd = fraction
        label.foregroundColor = tone.nsColor.cgColor
        label.string = text
        CATransaction.commit()
    }
}
