import AppKit
import SwiftUI

/// The panel's hosting view: takes the first click and passes right-clicks to the shape view for the menu.
final class PanelHostingView: NSHostingView<PanelView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
}

/// The dots' hosting view, with the same first-click and right-click behavior.
final class DotsHostingView: NSHostingView<PanelDots> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
}

/// The now-playing card's hosting view, with the same first-click and right-click behavior.
final class CardHostingView: NSHostingView<NowPlayingCard> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
}
