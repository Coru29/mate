import AppKit

/// `--snapshot-anim <dir>`: opens the panel 1.5 s after launch and closes it at 3.5 s, rendering what is on screen
/// (the layers' presentation, mid-animation) to PNGs at several moments of each. At 5 s it starts hiding the pill
/// and cancels the hide 40 ms later (pill-*.png: the pill must end visible). In-process, no screen recording.
extension NotchController {
    func scheduleAnimationSnapshots() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-anim"), i + 1 < args.count else { return }
        let dir = args[i + 1]
        let frames: [CFTimeInterval] = [0.03, 0.06, 0.1, 0.15, 0.22, 0.35, 0.8]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.openPanel()
            for t in frames {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { self?.renderPresentation(to: "\(dir)/open-\(Int(t * 1000))ms.png") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            self?.closePanel()
            for t in frames {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { self?.renderPresentation(to: "\(dir)/close-\(Int(t * 1000))ms.png") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.debugSetPillHidden(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { self?.debugSetPillHidden(false) }
            for t in [0.02, 0.1, 0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { self?.renderPresentation(to: "\(dir)/pill-\(Int(t * 1000))ms.png") }
            }
        }
    }

    /// Renders the window's presentation layer tree over a mid-gray backdrop, with a 1 px red line at the top of
    /// the window's current frame width so its size is visible too.
    private func renderPresentation(to path: String) {
        guard let layer = root.layer?.presentation() ?? root.layer else { return }
        let scale = root.window?.backingScaleFactor ?? 2
        let size = CGSize(width: root.bounds.width * scale, height: root.bounds.height * scale)
        guard size.width > 0, size.height > 0,
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let image = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
