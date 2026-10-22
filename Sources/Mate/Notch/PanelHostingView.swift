import AppKit
import SwiftUI

/// The panel's hosting view: takes the first click and passes right-clicks to the shape view for the menu.
final class PanelHostingView: NSHostingView<PanelView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
}
