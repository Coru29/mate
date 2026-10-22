import AppKit

/// Content animations of the notch: explicit Core Animation on the views' layers. Model values never change, so
/// nothing keeps running once an animation ends.
enum NotchMotion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Opacity 0 → 1 and scale 0.97 → 1 around the view's top center, after `delay`.
    /// The view must not be flipped: its layer's anchor is the bottom-left corner, so the top center is (w/2, h).
    static func reveal(_ view: NSView, delay: CFTimeInterval, duration: CFTimeInterval = 0.24) {
        guard let layer = view.layer, !reduceMotion else { return }
        let w = view.bounds.width, h = view.bounds.height
        var scaled = CATransform3DMakeTranslation(w / 2, h, 0)
        scaled = CATransform3DScale(scaled, 0.97, 0.97, 1)
        scaled = CATransform3DTranslate(scaled, -w / 2, -h, 0)
        let begin = CACurrentMediaTime() + delay
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: scaled)
        scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        for a in [fade, scale] {
            a.beginTime = begin
            a.duration = duration
            a.timingFunction = timing
            a.fillMode = .backwards
        }
        layer.removeAnimation(forKey: "fadeOut")
        layer.add(fade, forKey: "revealFade")
        layer.add(scale, forKey: "revealScale")
    }

    /// Fades the view out and holds it invisible until `completion` (which usually removes it).
    static func fadeOut(_ view: NSView, duration: CFTimeInterval = 0.1, completion: (() -> Void)? = nil) {
        guard let layer = view.layer, !reduceMotion else { completion?(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.removeAnimation(forKey: "revealFade")
        layer.removeAnimation(forKey: "revealScale")
        layer.add(fade, forKey: "fadeOut")
        CATransaction.commit()
    }

    /// Back to fully visible (cancels a held fade-out).
    static func restore(_ view: NSView) {
        view.layer?.removeAnimation(forKey: "fadeOut")
    }
}

/// A plain, unflipped, layer-backed holder for the panel's hosting view, so `NotchMotion.reveal` can scale it
/// around its top center.
final class PanelContainerView: NSView {
    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }
}
