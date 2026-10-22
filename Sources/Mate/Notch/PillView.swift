import AppKit
import MateCore

/// The pill right of the notch: a ring (2.5 pt stroke) and the percent of the window `pillWindow` picks (the
/// session unless the week is running out), with a dim tag when it is not the session. Plain layers, no SwiftUI,
/// nothing redrawn unless the value changes.
final class PillView: NSView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let label = CATextLayer()
    private let weekLabel = CATextLayer()
    private var shown: (text: String, fraction: CGFloat, tone: Tone, tag: String?)?

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
        weekLabel.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        weekLabel.fontSize = 9
        weekLabel.alignmentMode = .left
        weekLabel.foregroundColor = NSColor.white.withAlphaComponent(0.45).cgColor
        layer?.addSublayer(weekLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Clicks go to the shape view, which routes them by rect (and takes the first click).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        label.contentsScale = window?.backingScaleFactor ?? 2
        weekLabel.contentsScale = label.contentsScale
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
        let textY = (bounds.height - textHeight) / 2 - 1
        let textWidth = ceil(label.preferredFrameSize().width)
        label.frame = CGRect(x: ring.maxX + 5, y: textY, width: textWidth, height: textHeight)
        // Same baseline as the percent: 9 pt text sits about 1.5 pt lower in its box than 11 pt.
        weekLabel.frame = CGRect(x: label.frame.maxX + 3, y: textY - 1,
                                 width: ceil(weekLabel.preferredFrameSize().width), height: 12)
        CATransaction.commit()
    }

    /// `percent` nil shows a dash and an empty ring; `tag` names the window when it is not the session.
    func update(percent: Double?, tone: Tone, tag tagText: String? = nil) {
        let text = percent.map(NotchText.percent) ?? "–"
        let fraction = CGFloat(min(max(percent ?? 0, 0), 100) / 100)
        if let s = shown, s.text == text, s.fraction == fraction, s.tone == tone, s.tag == tagText { return }
        shown = (text, fraction, tone, tagText)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.strokeColor = tone.nsColor.cgColor
        fill.strokeEnd = fraction
        label.foregroundColor = tone.nsColor.cgColor
        label.string = text
        weekLabel.string = tagText ?? ""
        weekLabel.isHidden = tagText == nil
        CATransaction.commit()
        needsLayout = true
    }
}
