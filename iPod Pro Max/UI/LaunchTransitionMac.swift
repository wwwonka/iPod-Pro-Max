#if canImport(AppKitBackend)
    import AppKit
    import CoreGraphics
    import Foundation
    import QuartzCore

    /// The launch, played by the main window itself, in four beats:
    /// 1. the window shows as a small square of glass at the center of its final frame, fading in;
    /// 2. the iPod's icon fades in inside it, once the glass is there;
    /// 3. when everything is loaded, the window grows to its frame while the icon travels to its
    ///    place in the iPod page's header;
    /// 4. the rest of the interface is revealed as the veil of glass lifts.
    /// One window, no stand-in: the window is what scales.
    ///
    /// Nothing here runs at rest: it exists for the launch and ends with one Core Animation.
    @MainActor
    final class MacLaunchTransition {
        static let shared = MacLaunchTransition()

        private static let side: CGFloat = 260
        private static let iconSide: CGFloat = 128
        private static let panelFade: TimeInterval = 0.3
        private static let iconFade: TimeInterval = 0.4
        /// A beat between the icon being there and the window starting to grow.
        private static let pause: TimeInterval = 0.15
        /// `IPPM_LAUNCH_SLOWMO=4` plays the growth four times slower; `IPPM_LAUNCH_HOLD=3` keeps the
        /// square for 3 more seconds. Both are for looking at the transition.
        private static let duration: TimeInterval = 0.62
            * (ProcessInfo.processInfo.environment["IPPM_LAUNCH_SLOWMO"].flatMap(Double.init) ?? 1)
        private static let hold: TimeInterval =
            ProcessInfo.processInfo.environment["IPPM_LAUNCH_HOLD"].flatMap(Double.init) ?? 0

        private var finalFrame: NSRect?
        /// SwiftCrossUI sets the window's minimum size after each layout, which would keep it from
        /// shrinking to the square: the minimum is held at zero during the launch, and the last one
        /// it asked for is restored at the end.
        private var minSizeObservation: NSKeyValueObservation?
        private var requestedContentMinSize: NSSize = .zero
        private var squareFrame: NSRect?
        /// A veil of the window's own glass over everything it draws, so the small window shows only
        /// glass. (Hiding the views one by one does not hold: SwiftCrossUI replaces and resets them.)
        private var veil: NSVisualEffectView?
        /// The icon, over the veil: it fades in at the center, then travels to the header.
        private var iconView: NSImageView?
        private var hasPendingIcon = false
        private var pendingIcon: CGImage?
        /// Times (`systemUptime`) at which the glass and the icon are fully faded in.
        private var panelFadeEnd: TimeInterval = 0
        private var iconFadeEnd: TimeInterval?

        private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

        /// Right after the window is created, before its first display: shrinks it to the square,
        /// veils what it draws, and fades the glass in.
        func prepare(_ window: NSWindow) {
            guard finalFrame == nil else { return }
            let final = window.frame
            finalFrame = final
            requestedContentMinSize = window.contentMinSize
            window.minSize = .zero
            window.contentMinSize = .zero
            minSizeObservation = window.observe(\.contentMinSize, options: [.new]) { [weak self] window, _ in
                MainActor.assumeIsolated {
                    guard let self, window.contentMinSize != .zero else { return }
                    self.requestedContentMinSize = window.contentMinSize
                    window.contentMinSize = .zero
                    // Setting a minimum larger than the window had already grown it: back to the square.
                    if let square = self.squareFrame, window.frame != square { window.setFrame(square, display: false) }
                }
            }
            let frameView = window.contentView?.superview
            if let frameView {
                let veil = NSVisualEffectView(frame: frameView.bounds)
                veil.material = .underWindowBackground
                veil.blendingMode = .behindWindow
                veil.state = .active
                veil.autoresizingMask = [.width, .height]
                frameView.addSubview(veil)
                self.veil = veil
            }
            let square = NSRect(x: final.midX - Self.side / 2, y: final.midY - Self.side / 2,
                                width: Self.side, height: Self.side)
            squareFrame = square
            window.setFrame(square, display: false)
            if let frameView {
                let icon = NSImageView(frame: NSRect(x: (Self.side - Self.iconSide) / 2, y: (Self.side - Self.iconSide) / 2,
                                                     width: Self.iconSide, height: Self.iconSide))
                icon.imageScaling = .scaleProportionallyUpOrDown
                icon.imageAlignment = .alignCenter
                icon.alphaValue = 0
                frameView.addSubview(icon)
                iconView = icon
            }
            // Beat 1: the glass fades in.
            window.alphaValue = 0
            panelFadeEnd = Self.now + Self.panelFade
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.panelFade
                window.animator().alphaValue = 1
            }
            if hasPendingIcon { setIcon(pendingIcon) }
        }

        /// The iPod's own icon, or the generic iPod symbol when it has none. Beat 2: fades in once
        /// the glass is fully there.
        func setIcon(_ image: CGImage?) {
            guard let iconView else { hasPendingIcon = true; pendingIcon = image; return }
            hasPendingIcon = false
            if let image {
                let nsImage = NSImage(cgImage: image, size: NSSize(width: 80, height: 80))
                nsImage.isTemplate = false
                iconView.contentTintColor = nil
                iconView.image = nsImage
            } else if #available(macOS 11, *) {
                iconView.image = NSImage(systemSymbolName: "ipod", accessibilityDescription: "iPod")
                iconView.symbolConfiguration = .init(pointSize: 48, weight: .regular)
                iconView.contentTintColor = .controlAccentColor
            }
            let wait = max(0, panelFadeEnd - Self.now)
            iconFadeEnd = Self.now + wait + Self.iconFade
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.iconFade
                    iconView.animator().alphaValue = 1
                }
            }
        }

        /// The launch is ready: the window grows (once the glass and the icon have faded in).
        func expand(_ window: NSWindow) {
            var delay = Self.hold
            if let end = iconFadeEnd { delay = max(delay, end + Self.pause - Self.now) }
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.grow(window) }
            } else {
                grow(window)
            }
        }

        /// Beat 3: the window grows to its frame while the icon travels to the header.
        private func grow(_ window: NSWindow) {
            guard let final = finalFrame else {
                window.alphaValue = 1
                window.makeKeyAndOrderFront(nil)
                return
            }
            squareFrame = nil  // from here the window may grow
            window.makeKeyAndOrderFront(nil)
            startFlight(in: window)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.duration
                context.timingFunction = Self.timing
                window.animator().setFrame(final, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    window.setFrame(final, display: true)
                    self.minSizeObservation = nil
                    window.contentMinSize = self.requestedContentMinSize
                    self.finalFrame = nil
                    Self.layoutForCurrentSize(window)
                    // One turn later, so the laid-out content is what shows when the veil lifts.
                    DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.liftVeil() } }
                }
            })
        }

        private static let timing = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.1, 1)
        private var flightTimer: Timer?

        /// The traveling icon follows the page's real icon, wherever SwiftCrossUI's layout has put it
        /// so far: it leaves the center of the square and, by the end of the growth, is exactly on the
        /// real one, and keeps tracking it until the veil lifts (the layout settles in steps, so the
        /// final position cannot be read ahead of time). Without such an icon (Music's page, say), it
        /// just fades out.
        private func startFlight(in window: NSWindow) {
            guard let icon = iconView, let frameView = window.contentView?.superview else { return }
            guard let real = Self.findIcon(in: window.contentView) else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.duration * 0.5
                    icon.animator().alphaValue = 0
                }
                return
            }
            // It looks exactly like the real one, which waits under the veil.
            icon.image = real.image
            if #available(macOS 11, *) { icon.symbolConfiguration = real.symbolConfiguration }
            icon.contentTintColor = real.contentTintColor
            let from = icon.frame
            let begin = Self.now
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak icon, weak real, weak frameView] _ in
                MainActor.assumeIsolated {
                    guard let icon, let real, let frameView, real.bounds.width > 0 else { return }
                    let to = frameView.convert(real.convert(real.bounds, to: nil), from: nil)
                    let p = Self.ease(min(1, (Self.now - begin) / Self.duration))
                    icon.frame = NSRect(x: from.minX + (to.minX - from.minX) * p,
                                        y: from.minY + (to.minY - from.minY) * p,
                                        width: from.width + (to.width - from.width) * p,
                                        height: from.height + (to.height - from.height) * p)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            flightTimer = timer
        }

        /// The growth's timing curve (cubic Bézier 0.5, 0, 0.1, 1), so the icon and the window move together.
        private static func ease(_ t: Double) -> Double {
            let (x1, y1, x2, y2) = (0.5, 0.0, 0.1, 1.0)
            func coordinate(_ s: Double, _ a: Double, _ b: Double) -> Double {
                3 * (1 - s) * (1 - s) * s * a + 3 * (1 - s) * s * s * b + s * s * s
            }
            var low = 0.0, high = 1.0
            for _ in 0..<24 {
                let mid = (low + high) / 2
                if coordinate(mid, x1, x2) < t { low = mid } else { high = mid }
            }
            return coordinate((low + high) / 2, y1, y2)
        }

        /// SwiftCrossUI lays out for a programmatic resize only in a short window that its delegate
        /// opens in `windowWillResize` (1.5 s), so a slow or late animation leaves the content laid out
        /// for the square. Asking the delegate for both calls makes it lay out for the final size.
        private static func layoutForCurrentSize(_ window: NSWindow) {
            guard let delegate = window.delegate else { return }
            _ = delegate.windowWillResize?(window, to: window.frame.size)
            delegate.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))
        }

        /// Beat 4: the window has its final size and the content has been laid out for it: only now
        /// does the veil lift (lifting it earlier would show the content cut off while it catches up).
        /// The traveling icon is exactly over the real one, and leaves once it is uncovered.
        private func liftVeil() {
            guard let veil else { return }
            let icon = iconView
            let timer = flightTimer
            self.veil = nil
            iconView = nil
            flightTimer = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                veil.animator().alphaValue = 0
            }, completionHandler: {
                timer?.invalidate()
                veil.removeFromSuperview()
                icon?.removeFromSuperview()
            })
        }

        private static func findIcon(in view: NSView?) -> MacVolumeIconImageView? {
            guard let view else { return nil }
            if let icon = view as? MacVolumeIconImageView { return icon }
            for sub in view.subviews { if let found = findIcon(in: sub) { return found } }
            return nil
        }
    }
#endif
