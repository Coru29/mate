import AppKit

/// The mate left of the notch: frame 0 of `mate-sprite.png` (Noto's animated 🧉, see scripts/make-mate-sprite.swift)
/// at rest, and a small green dot while the Mac is kept awake. Plain layers, no SwiftUI. A sip is one discrete
/// `CAKeyframeAnimation` on `contentsRect` over the sprite sheet, played once by the render server; the model value
/// stays on frame 0, so nothing runs once it ends.
final class MateIconView: NSView {
    static let frameCount = 44
    /// The GIF's own timing without its first frame's hold (printed by scripts/make-mate-sprite.swift).
    static let duration: CFTimeInterval = 2.67
    static let dotDiameter: CGFloat = 4

    /// The sprite sheet, nil when the app runs outside its bundle (`swift run`): the ear then stays empty.
    static let sprite: CGImage? = {
        guard let url = Bundle.main.url(forResource: "mate-sprite", withExtension: "png"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }()

    /// Frame 0 alone, for the panel's keep-awake row.
    static let glyph: NSImage? = {
        guard let sprite, let cell = sprite.cropping(to: CGRect(x: 0, y: 0, width: sprite.height, height: sprite.height))
        else { return nil }
        return NSImage(cgImage: cell, size: NSSize(width: 24, height: 24))
    }()

    private let icon = CALayer()
    private let dot = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.contents = Self.sprite
        icon.contentsGravity = .resizeAspect
        icon.contentsRect = Self.cell(0)
        icon.magnificationFilter = .trilinear
        icon.minificationFilter = .trilinear
        layer?.addSublayer(icon)
        dot.backgroundColor = Tone.ok.nsColor.cgColor
        dot.borderColor = NSColor.black.cgColor
        dot.borderWidth = 1
        dot.isHidden = true
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Clicks go to the shape view, which routes them by rect (and takes the first click).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        icon.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.frame = bounds
        // At the gourd's bottom right (the gourd fills about the middle 18 pt of the 24 pt cell).
        let d = Self.dotDiameter + 2 * dot.borderWidth
        dot.frame = CGRect(x: bounds.maxX - 4 - d, y: 3, width: d, height: d)
        dot.cornerRadius = d / 2
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

    var isPlaying: Bool { icon.animation(forKey: "sip") != nil }

    /// One sip (the yerba goes down, the thermos pours), then back to frame 0.
    func play() {
        guard Self.sprite != nil, !isPlaying else { return }
        let n = Self.frameCount
        let a = CAKeyframeAnimation(keyPath: "contentsRect")
        a.values = (0..<n).map { NSValue(rect: Self.cell($0)) }
        // Discrete: one more key time than values, evenly spaced.
        a.keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        a.calculationMode = .discrete
        a.duration = Self.duration
        icon.add(a, forKey: "sip")
    }

    /// Stops a sip at once (on frame 0).
    func stop() { icon.removeAnimation(forKey: "sip") }

    private static func cell(_ i: Int) -> CGRect {
        CGRect(x: CGFloat(i) / CGFloat(frameCount), y: 0, width: 1 / CGFloat(frameCount), height: 1)
    }
}
