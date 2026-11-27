#if canImport(AppKitBackend)
    import AppKit

    /// How a list placed at `view` meets the toolbar: `extend` is how far its scroll view must grow
    /// upward to reach the window's top, `inset` the content inset that keeps its first row below the
    /// bar at rest. Both zero for a list that starts lower than the bar (under a header).
    @MainActor func toolbarReach(of view: NSView) -> (extend: CGFloat, inset: CGFloat) {
        guard let content = view.window?.contentView, !view.bounds.isEmpty else { return (0, 0) }
        let top = view.convert(view.bounds, to: nil).maxY
        let windowTop = content.convert(content.bounds, to: nil).maxY
        let barBottom = windowTop - CGFloat(titleBarHeight)
        guard top >= barBottom - 1 else { return (0, 0) }
        return (max(0, windowTop - top), CGFloat(titleBarHeight))
    }

    /// Runs `action` after each window resize (and leaving full screen): a view's distance to the
    /// toolbar changes then even when its own frame doesn't. Replaces the previous observation.
    @MainActor func watchWindowGeometry(of view: NSView, _ action: @escaping @MainActor () -> Void) -> NSObjectProtocol? {
        guard let window = view.window else { return nil }
        return NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { DispatchQueue.main.async { action() } }
        }
    }

    /// Holds a list's scroll view and, when the list starts right under the toolbar, lets it reach up
    /// behind the bar with a matching content inset: at rest nothing moves, and rows scrolled (or
    /// stretched by the rubber band) past the top slide beneath the toolbar's blur, as in Safari.
    /// Lists that start lower (under a header) stay as they are.
    final class UnderToolbarHost: NSView {
        let scroll: NSScrollView
        private var extra: CGFloat = -1

        init(_ scroll: NSScrollView) {
            self.scroll = scroll
            super.init(frame: .zero)
            clipsToBounds = false
            scroll.automaticallyAdjustsContentInsets = false
            BackdropBlurView.register(scroll)
            addSubview(scroll)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() { super.layout(); place() }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); place() }
        override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); place() }
        private var resizeObserver: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resizeObserver = watchWindowGeometry(of: self) { [weak self] in self?.place() }
            place()
        }
        /// Placed lower or higher by its ancestors (a header appearing above it) without being resized.
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); needsLayout = true }

        /// Called on each update: the list may have moved (a header shown above it) without resizing.
        func refresh() { DispatchQueue.main.async { [weak self] in self?.place() } }

        private func place() {
            let reach = toolbarReach(of: self)
            if reach.extend > 0 {
                // SwiftCrossUI's cornerRadius(0) still clips. Let a toolbar-adjacent list
                // overflow those square wrappers, retaining rounded and explicit masks.
                var ancestor = superview
                while let view = ancestor, let content = window?.contentView, view !== content {
                    if view.clipsToBounds, view.layer?.cornerRadius == 0, view.layer?.mask == nil {
                        view.clipsToBounds = false
                    }
                    if view.convert(view.bounds, to: nil).maxY >= content.convert(content.bounds, to: nil).maxY { break }
                    ancestor = view.superview
                }
            }
            let frame = NSRect(x: 0, y: isFlipped ? -reach.extend : 0, width: bounds.width, height: bounds.height + reach.extend)
            if scroll.frame != frame { scroll.frame = frame }
            defer { BackdropBlurView.refreshToolbarMask() }
            guard reach.inset != extra else { return }
            extra = reach.inset
            let wasAtTop = scroll.contentView.bounds.minY <= -scroll.contentInsets.top + 0.5
            scroll.contentInsets = NSEdgeInsets(top: reach.inset, left: 0, bottom: 0, right: 0)
            scroll.scrollerInsets = NSEdgeInsets(top: reach.inset, left: 0, bottom: 0, right: 0)
            // Keep a list that was at its top at its top, now below the bar.
            if wasAtTop, scroll.documentView?.isFlipped ?? true {
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: -reach.inset))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }
#endif
