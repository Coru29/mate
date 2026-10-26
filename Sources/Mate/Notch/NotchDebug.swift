import AppKit

/// `--snapshot-anim <dir>`: opens the panel 1.5 s after launch, swipes to the next account at 2.6 s and closes it
/// at 4 s, rendering what is on screen (the layers' presentation, mid-animation) to PNGs: the open at a few moments,
/// the slide every 32 ms, the close every 16 ms. At 5.5 s it starts hiding the pill and cancels the hide 40 ms later
/// (pill-*.png: the pill must end visible). At 7 s the mate takes a sip (sip-*.png, through the whole animation).
/// At 10 s the pill is hidden for good, leaving the mate's ear alone if the Mac is kept awake (solo-*.png); the panel
/// opens from that state at 11.5 s and closes at 12.5 s (solo-open-*.png, solo-close-*.png), and the pill comes back
/// at 14 s (back-*.png).
/// `--trace-anim <dir>`: the same open and close without PNGs; a display link (only while each animation runs)
/// writes one line per frame to open-trace.txt / close-trace.txt: time since start, gap since the previous frame,
/// the window frame and the body's on-screen bounds. In-process, no screen recording.
extension NotchController {
    func scheduleAnimationSnapshots() {
        let args = CommandLine.arguments
        // These checks render the layer tree in-process, so the window itself stays invisible and lets every click
        // through: nothing shows on the user's screen while they run.
        if args.contains("--snapshot-anim") || args.contains("--trace-anim") {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
        if let i = args.firstIndex(of: "--trace-anim"), i + 1 < args.count {
            let dir = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                FrameTrace.start(self, to: "\(dir)/open-trace.txt")
                self.openPanel()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self else { return }
                FrameTrace.start(self, to: "\(dir)/close-trace.txt")
                self.closePanel()
            }
            return
        }
        guard let i = args.firstIndex(of: "--snapshot-anim"), i + 1 < args.count else { return }
        let dir = args[i + 1]
        let openFrames: [CFTimeInterval] = [0.03, 0.06, 0.1, 0.15, 0.22, 0.35, 0.8]
        let closeFrames: [CFTimeInterval] = (0...20).map { Double($0) * 0.016 } + [0.5]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.openPanel()
            for t in openFrames {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { self?.renderPresentation(to: "\(dir)/open-\(Int(t * 1000))ms.png") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            self?.debugSwipe(step: 1)
            for t in (0...15).map({ Double($0) * 0.032 }) + [0.8] {
                let name = String(format: "slide-%03dms.png", Int((t * 1000).rounded()))
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { self?.renderPresentation(to: "\(dir)/\(name)") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.closePanel()
            for t in closeFrames {
                let name = String(format: "close-%03dms.png", Int((t * 1000).rounded()))
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { self?.renderPresentation(to: "\(dir)/\(name)") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
            self?.debugSetPillHidden(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { self?.debugSetPillHidden(false) }
            for t in [0.02, 0.1, 0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { self?.renderPresentation(to: "\(dir)/pill-\(Int(t * 1000))ms.png") }
            }
        }
        func frames(_ at: TimeInterval, _ prefix: String, _ times: [Double], _ action: @escaping (NotchController) -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self else { return }
                action(self)
                for t in times {
                    let name = String(format: "\(prefix)-%04dms.png", Int((t * 1000).rounded()))
                    DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.renderPresentation(to: "\(dir)/\(name)") }
                }
            }
        }
        let morph = [0.03, 0.08, 0.15, 0.3, 1.0]
        frames(10, "solo", morph) { $0.debugSetPillHidden(true) }
        frames(11.5, "solo-open", [0.05, 0.15, 0.8]) { $0.openPanel() }
        frames(12.5, "solo-close", [0.05, 0.12, 0.5]) { $0.closePanel() }
        frames(14, "back", morph) { $0.debugSetPillHidden(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            self?.debugSip()
            for t in [0.0, 0.4, 0.9, 1.3, 1.6, 1.9, 2.2, 2.5, 3.0] {
                let name = String(format: "sip-%04dms.png", Int((t * 1000).rounded()))
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { self?.renderPresentation(to: "\(dir)/\(name)") }
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

/// `--trace-anim`: logs every display frame for 0.7 s after an animation starts, then removes its display link.
@MainActor
private final class FrameTrace: NSObject {
    private static var current: FrameTrace?
    private weak var controller: NotchController?
    private var link: CADisplayLink?
    private let path: String
    private let start = CACurrentMediaTime()
    private var last: CFTimeInterval
    private var lines: [String] = []

    private init(_ controller: NotchController, path: String) {
        self.controller = controller
        self.path = path
        last = start
    }

    static func start(_ controller: NotchController, to path: String) {
        let trace = FrameTrace(controller, path: path)
        current = trace
        trace.link = controller.root.displayLink(target: trace, selector: #selector(frame(_:)))
        trace.link?.add(to: .main, forMode: .common)
        // Written on a timer, not from the link: the link may stop firing once nothing on screen changes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { trace.finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        if FrameTrace.current === self { FrameTrace.current = nil }
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let w = controller?.root.window?.frame ?? .zero
        let body = controller?.root.presentedPath(.body)?.boundingBox ?? .zero
        lines.append(String(format: "t=%6.1f ms  gap=%5.1f ms  window=%.0fx%.0f@%.0f,%.0f  body=%.1fx%.1f",
                            (now - start) * 1000, (now - last) * 1000, w.width, w.height, w.minX, w.minY,
                            body.width, body.height))
        last = now
    }
}
