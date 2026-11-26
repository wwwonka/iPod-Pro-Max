#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend
    import SwiftCrossUI

    /// The 1 pt black line between a list column (artists, podcast shows) and the content, as macOS
    /// draws its split view dividers. Dragging it resizes the column; the grab area is a few points
    /// wider than the line, like an NSSplitView's.
    struct ColumnResizeHandle: NSViewRepresentable {
        var width: Double
        var range: ClosedRange<Double>
        var onResize: (Double) -> Void
        var onResizeEnd: (Double) -> Void

        func makeNSView(context: Context) -> ColumnResizeLine { ColumnResizeLine(frame: .zero) }

        func updateNSView(_ view: ColumnResizeLine, context: Context) {
            view.grabber.width = width; view.grabber.range = range
            view.grabber.onResize = onResize; view.grabber.onResizeEnd = onResizeEnd
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: ColumnResizeLine, context: Context) -> ViewSize {
            ViewSize(1, proposal.height ?? 10)
        }
    }

    final class ColumnResizeLine: NSView {
        /// A sibling laid over the line, wider than it, so the edge is easy to grab.
        let grabber = ColumnResizeGrabber(frame: .zero)
        static let slop: CGFloat = 3

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            grabber.removeFromSuperview()
            superview?.addSubview(grabber, positioned: .above, relativeTo: nil)
            placeGrabber()
        }
        override func removeFromSuperview() { grabber.removeFromSuperview(); super.removeFromSuperview() }
        override var isHidden: Bool { didSet { grabber.isHidden = isHidden } }
        override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); placeGrabber() }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); placeGrabber() }
        private func placeGrabber() {
            grabber.frame = frame.insetBy(dx: -Self.slop, dy: 0)
            window?.invalidateCursorRects(for: grabber)
        }
    }

    final class ColumnResizeGrabber: NSView {
        var width = 250.0
        var range = 160.0...480.0
        var onResize: (Double) -> Void = { _ in }
        var onResizeEnd: (Double) -> Void = { _ in }
        private var start: (x: CGFloat, width: Double)?
        private var latest = 0.0

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

        override func mouseDown(with event: NSEvent) {
            start = (event.locationInWindow.x, width); latest = width
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            NSCursor.resizeLeftRight.set()
            let proposed = min(max(start.width + Double(event.locationInWindow.x - start.x), range.lowerBound), range.upperBound)
            let rounded = proposed.rounded()
            guard rounded != latest else { return }
            latest = rounded
            onResize(rounded)
        }
        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            onResizeEnd(latest)
        }
    }
#endif
