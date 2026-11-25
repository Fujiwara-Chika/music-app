import SwiftUI
import AppKit

/// The hairline between panes, widened to a 7pt grab area. Dragging it changes a
/// pane's width; the clamp lives in `AppearanceSettings`, so the panes can never
/// be dragged below their minimum.
struct PaneResizer: View {
    enum Edge { case trailing, leading }

    /// Which side of the *pane being resized* the handle sits on.
    let edge: Edge
    /// `true` for the right-hand panel: dragging left makes it wider.
    let width: Binding<Double>
    let range: ClosedRange<Double>
    let color: Color

    @State private var start: Double?
    @State private var draggingWindowBackdrop = false
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: hovering ? 3 : 1)
            .frame(width: 9)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let base = start ?? width.wrappedValue
                        if start == nil {
                            start = base
                            // The window itself drags from its background; while a
                            // pane is being resized that must not compete with us.
                            draggingWindowBackdrop = NSApp.keyWindow?.isMovableByWindowBackground ?? false
                            NSApp.keyWindow?.isMovableByWindowBackground = false
                        }
                        let delta = edge == .trailing ? value.translation.width : -value.translation.width
                        width.wrappedValue = min(range.upperBound,
                                                 max(range.lowerBound, base + delta))
                        NSCursor.resizeLeftRight.push()
                    }
                    .onEnded { _ in
                        start = nil
                        if draggingWindowBackdrop {
                            NSApp.keyWindow?.isMovableByWindowBackground = true
                            draggingWindowBackdrop = false
                        }
                        NSCursor.pop()
                    }
            )
            .help("拖动调整宽度")
    }
}
