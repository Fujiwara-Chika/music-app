import AppKit
import SwiftUI

/// The one place the window can be dragged from: the empty middle of the top bar.
///
/// `isMovableByWindowBackground` used to make *every* empty pixel of the window a
/// drag handle — clicking the table's gaps, the sidebar's background or a column
/// header could move the window instead of doing what the click meant. It is off
/// now, and this view is the handle.
///
/// It is a real `NSView` on purpose: `mouseDown` forwards to
/// `NSWindow.performDrag(with:)`, so the drag keeps the system behaviour
/// (window snapping/tiling, dragging to another Space, double-click to zoom)
/// instead of re-implementing it by moving frames.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Handle() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Handle: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        /// An empty strip has no content to hit-test; make the whole frame it is
        /// given draggable.
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(convert(point, from: superview)) ? self : nil
        }
    }
}
