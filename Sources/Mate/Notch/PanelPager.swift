import AppKit
import SwiftUI
import MateCore

/// The open panel's content: the now-playing card on top (it stays put while the pages slide), the current
/// account's page and, with more than one account, the dots below it.
/// Switching accounts slides the pages like paging on iOS: the current one moves out (fading, scaled to 0.98) while
/// the next comes in from the other side, on the page spring. Pages are pinned to the top; when the panel's height
/// changes the dots follow the bottom on the same spring as the black shape. Unflipped and layer-backed, so
/// `NotchMotion.reveal` can scale it around its top center. Explicit Core Animation only: nothing runs when idle.
@MainActor
final class PanelPager: NSView {
    private let store: UsageStore
    /// `cardSpace`: room the page leaves at its top for the card.
    private let makePage: (_ accountID: String?, _ hasDots: Bool, _ cardSpace: CGFloat) -> PanelView
    /// Height of the notch strip above the content.
    private let topInset: CGFloat
    private(set) var accountID: String?
    private var page: PanelHostingView
    /// Pages sliding out; removed when their slide ends, or at once when another slide starts.
    private var outgoing: [NSView] = []
    private var dots: DotsHostingView?
    private var card: CardHostingView?
    /// Space between the card and the page below it (the page's own row spacing).
    private static let cardGap: CGFloat = 14

    init(store: UsageStore, accountID: String?, topInset: CGFloat,
         makePage: @escaping (String?, Bool, CGFloat) -> PanelView) {
        self.store = store
        self.makePage = makePage
        self.topInset = topInset
        self.accountID = accountID
        let hasDots = store.notchAccounts.count > 1
        page = PanelHostingView(rootView: makePage(accountID, false, 0))
        super.init(frame: .zero)
        wantsLayer = true
        setCard(Self.cardWanted)
        page.rootView = makePage(accountID, hasDots, cardSpace)
        addPage(page)
        setDots(hasDots)
    }

    private static var cardWanted: Bool {
        let center = NowPlayingCenter.shared
        return NowPlayingUI.showsCard(enabled: center.enabled, nowPlaying: center.current)
    }

    /// What the page leaves free at its top for the card.
    private var cardSpace: CGFloat {
        guard let card else { return 0 }
        return card.fittingSize.height + Self.cardGap
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    /// The panel's content height for the current page.
    var fittingHeight: CGFloat {
        page.fittingSize.height + (dots == nil ? 0 : PanelDots.height)
    }

    /// The store changed without a new account: redraw the page (and add or drop the dots).
    func refresh() {
        let hasDots = store.notchAccounts.count > 1
        setDots(hasDots)
        setCard(Self.cardWanted)
        page.rootView = makePage(accountID, hasDots, cardSpace)
        place(page)
        if let card { place(card) }
    }

    /// Slides to `id`: forward (the next account) moves the pages to the left.
    func slide(to id: String?, forward: Bool) {
        for view in outgoing { view.removeFromSuperview() }
        outgoing.removeAll()
        let hasDots = store.notchAccounts.count > 1
        setDots(hasDots)
        let old = page
        accountID = id
        page = PanelHostingView(rootView: makePage(id, hasDots, cardSpace))
        addPage(page)
        outgoing.append(old)

        guard let oldLayer = old.layer, let newLayer = page.layer else { return }
        let w = bounds.width
        let dx = forward ? -w : w
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak old] in
            guard let self, let old, let i = self.outgoing.firstIndex(of: old) else { return }
            old.removeFromSuperview()
            self.outgoing.remove(at: i)
        }
        // The outgoing page leaves from wherever it is (it may have been sliding in).
        let oldFrom = oldLayer.presentation()?.transform ?? CATransform3DIdentity
        if NotchMotion.reduceMotion {
            Self.fade(oldLayer, from: 1, to: 0, duration: 0.2, hold: true)
            Self.fade(newLayer, from: 0, to: 1, duration: 0.2, hold: false)
        } else {
            let out = NotchShapeView.Spring.page.animation(keyPath: "transform")
            out.fromValue = NSValue(caTransform3D: oldFrom)
            out.toValue = NSValue(caTransform3D: Self.transform(dx: dx, scale: 0.98, size: old.bounds.size))
            out.fillMode = .forwards
            out.isRemovedOnCompletion = false
            oldLayer.add(out, forKey: "slide")
            Self.fade(oldLayer, from: oldLayer.presentation()?.opacity ?? 1, to: 0, duration: 0.22, hold: true)

            let into = NotchShapeView.Spring.page.animation(keyPath: "transform")
            into.fromValue = NSValue(caTransform3D: Self.transform(dx: -dx, scale: 1, size: page.bounds.size))
            into.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            newLayer.add(into, forKey: "slide")
            Self.fade(newLayer, from: 0, to: 1, duration: 0.26, hold: false)
        }
        CATransaction.commit()
    }

    /// Top pinned: when the height changes, the dots would jump to the new bottom while the black shape springs
    /// there. They follow it on the same spring instead (an additive offset that settles at zero).
    override func setFrameSize(_ newSize: NSSize) {
        let delta = newSize.height - frame.height
        let animate = frame.height > 0 && abs(delta) > 0.5 && !NotchMotion.reduceMotion
        super.setFrameSize(newSize)
        guard animate, let layer = dots?.layer else { return }
        let follow = NotchShapeView.Spring.page.animation(keyPath: "position.y")
        follow.fromValue = delta
        follow.toValue = 0
        follow.isAdditive = true
        layer.add(follow, forKey: "follow")
    }

    // MARK: Layout

    private func addPage(_ view: PanelHostingView) {
        view.wantsLayer = true
        view.autoresizingMask = [.width, .minYMargin]
        // Below everything: the card and the dots stay on top of the sliding pages.
        addSubview(view, positioned: .below, relativeTo: nil)
        place(view)
    }

    /// A page keeps its own height, pinned to the top (unflipped: the top is maxY); the card sits below the notch
    /// strip, where the page's top padding starts.
    private func place(_ view: NSView) {
        let h = view.fittingSize.height
        let top: CGFloat = view === card ? topInset + 10 : 0
        view.frame = CGRect(x: 0, y: bounds.height - top - h, width: bounds.width, height: h)
    }

    private func setCard(_ shown: Bool) {
        if shown, card == nil {
            let center = NowPlayingCenter.shared
            let view = CardHostingView(rootView: NowPlayingCard(center: center, clock: center.clock))
            view.wantsLayer = true
            view.autoresizingMask = [.width, .minYMargin]
            addSubview(view)
            card = view
            place(view)
        } else if !shown, let view = card {
            view.removeFromSuperview()
            card = nil
        }
    }

    private func setDots(_ shown: Bool) {
        if shown, dots == nil {
            let view = DotsHostingView(rootView: PanelDots(store: store))
            view.wantsLayer = true
            view.autoresizingMask = [.width, .maxYMargin]
            view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PanelDots.height)
            addSubview(view)
            dots = view
        } else if !shown, let view = dots {
            view.removeFromSuperview()
            dots = nil
        }
    }

    /// Moves by `dx` and scales around the center (a layer-backed view's anchor is its bottom-left corner).
    private static func transform(dx: CGFloat, scale: CGFloat, size: CGSize) -> CATransform3D {
        var t = CATransform3DMakeTranslation(dx + size.width / 2, size.height / 2, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -size.width / 2, -size.height / 2, 0)
    }

    private static func fade(_ layer: CALayer, from: Float, to: Float, duration: CFTimeInterval, hold: Bool) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if hold {
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
        }
        layer.add(a, forKey: "pageFade")
    }
}
