import AppKit
import MateCore

/// The left ear while music plays: the album art (18 pt, 4 pt corners) and the equalizer bars to its right, with the
/// keep-awake dot on the art. Plain layers; the bars run only while the ear is on screen (`setPlaying`).
final class MusicEarView: NSView {
    private let art = CALayer()
    private let note = CATextLayer()
    private let bars = EqualizerView()
    private let dot = CALayer()
    private var image: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        art.cornerRadius = 4
        art.masksToBounds = true
        art.contentsGravity = .resizeAspectFill
        art.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        art.minificationFilter = .trilinear
        layer?.addSublayer(art)
        // Placeholder until (or without) artwork.
        note.string = "♪"
        note.fontSize = 12
        note.alignmentMode = .center
        note.foregroundColor = NSColor(white: 1, alpha: 0.55).cgColor
        art.addSublayer(note)
        bars.color = NSColor(white: 0.92, alpha: 1)
        addSubview(bars)
        dot.backgroundColor = Tone.ok.nsColor.cgColor
        dot.borderColor = NSColor.black.cgColor
        dot.borderWidth = 1
        dot.isHidden = true
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Clicks go to the shape view, which routes them by rect.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        art.contentsScale = scale
        note.contentsScale = scale
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Same geometry as NotchLayout.musicArtRect / musicBarsRect, relative to the ear.
        let s = NotchLayout.musicArtSize
        let artRect = CGRect(x: 7, y: (bounds.height - s) / 2, width: s, height: s)
        art.frame = artRect
        note.frame = CGRect(x: 0, y: (s - 15) / 2, width: s, height: 15)
        let b = NotchLayout.musicBarsSize
        bars.frame = CGRect(x: artRect.maxX + 6, y: (bounds.height - b.height) / 2, width: b.width, height: b.height)
        let d = MateIconView.dotDiameter + 2 * dot.borderWidth
        dot.frame = CGRect(x: artRect.maxX - d + 2, y: artRect.minY - 2, width: d, height: d)
        dot.cornerRadius = d / 2
        CATransaction.commit()
    }

    func setArtwork(_ image: CGImage?) {
        guard self.image !== image else { return }
        self.image = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.contents = image
        note.isHidden = image != nil
        CATransaction.commit()
    }

    var showsDot: Bool {
        get { !dot.isHidden }
        set {
            guard newValue == dot.isHidden else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.isHidden = !newValue
            CATransaction.commit()
        }
    }

    /// The bars bounce only while the ear is shown and music plays.
    func setPlaying(_ on: Bool) { bars.setAnimating(on) }
    var isPlaying: Bool { bars.isAnimating }
}
