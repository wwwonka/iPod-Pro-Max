#if canImport(AppKitBackend)
import AppKit

/// Custom toolbar views do not inherit NSToolbarItem's automatic inactive tint.
/// Follow window activation notifications, keeping the glass independent of control tint.
@MainActor class ToolbarPlaybackButton: NSButton {
    private var activationObservers: [NSObjectProtocol] = []
    private let hoverLayer: CALayer = { let layer = CALayer(); layer.opacity = 0; return layer }()
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    private var pointerInside = false
    private var hoverWork: DispatchWorkItem?
    var isLatched = false { didSet { updateInteraction() } }
    private var pressed = false
    private var currentSymbol = ""
    private lazy var transportSymbol = TransportSymbolView()
    var matchesDisabledTint = false { didSet { if oldValue != matchesDisabledTint { updateInteraction() } } }
    var textOnlyHover = false
    var glyphOnlyHover = false { didSet { if oldValue != glyphOnlyHover { updateInteraction(animated: false) } } }
    var customTrackingRect: NSRect? {
        didSet {
            if oldValue != customTrackingRect {
                updateTrackingAreas()
            }
        }
    }
    func refreshTextTint() { updateInteraction() }
    var usesElevation = false { didSet { if usesElevation { (cell as? NSButtonCell)?.highlightsBy = [] } } }
    var usesAccentTint = false { didSet { updateInteraction() } }
    var usesLightGlyph = false
    var animatesPress = false
    var symbolTransition: TransportSymbolView.Transition = .system { didSet { transportSymbol.transition = symbolTransition } }
    private(set) var animatedSymbolChanges = 0
    var symbolName: String { currentSymbol }
    var drawsSymbolTransition = false {
        didSet {
            guard drawsSymbolTransition else { return }
            addSubview(transportSymbol); transportSymbol.frame = bounds
            transportSymbol.setSymbol(currentSymbol, image: image, animated: false)
            image = nil
        }
    }
    func setSymbol(_ name: String, size: Double, animated: Bool = true) {
        guard name != currentSymbol else { return }
        let replacing = !currentSymbol.isEmpty
        if replacing && animated { animatedSymbolChanges += 1 }
        currentSymbol = name
        title = ""; imagePosition = .imageOnly
        let symbolImage = systemSymbol(name, pointSize: size)
        if drawsSymbolTransition {
            transportSymbol.setSymbol(name, image: symbolImage, animated: replacing && animated)
            image = nil
        } else { image = symbolImage }
        if animated, replacing, !drawsSymbolTransition, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition(); fade.type = .fade; fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(fade, forKey: "symbolReplace")
        }
    }
    func setSpeakerSymbols(from oldLevel: Int, to newLevel: Int, size: Double, animated: Bool) {
        let finalName = newLevel == 0 ? "speaker.slash.fill" : "speaker.wave.\(newLevel).fill"
        guard oldLevel >= 0, oldLevel != newLevel else {
            setSymbol(finalName, size: size, animated: animated)
            return
        }
        currentSymbol = finalName
        title = ""; imagePosition = .imageOnly
        image = nil
        transportSymbol.setSpeakerCascade(from: oldLevel, to: newLevel, pointSize: size, animated: animated)
    }
    override func layout() {
        super.layout()
        if hoverLayer.superlayer == nil { wantsLayer = true; layer?.insertSublayer(hoverLayer, at: 0) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if drawsSymbolTransition { transportSymbol.frame = bounds }
        hoverLayer.frame = bounds; hoverLayer.cornerRadius = 6
        hoverLayer.backgroundColor = RailButton.overlay(1).cgColor
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let customTrackingRect {
            let local = convert(point, from: superview)
            return customTrackingRect.contains(local) ? self : nil
        }
        return super.hitTest(point)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area: NSTrackingArea
        if let customTrackingRect {
            area = NSTrackingArea(rect: customTrackingRect, options: [.mouseEnteredAndExited, .activeInKeyWindow, .enabledDuringMouseDrag], owner: self)
        } else {
            area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        }
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        guard isEnabled, playerControlWindow(for: self)?.isKeyWindow == true else { return }
        hoverWork?.cancel()
        pointerInside = true
        if glyphOnlyHover {
            hovered = true
            updateInteraction(animated: true)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pointerInside, self.isEnabled, playerControlWindow(for: self)?.isKeyWindow == true else { return }
            self.hovered = true; self.updateInteraction(animated: true)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + RailButton.hoverDelay, execute: work)
    }
    override func mouseExited(with event: NSEvent) {
        hoverWork?.cancel(); pointerInside = false; hovered = false; updateInteraction(animated: true)
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            superview?.mouseDown(with: event)
            return
        }
        if glyphOnlyHover, let window {
            hoverWork?.cancel()
            pointerInside = true
            hovered = true
            pressed = true
            updateInteraction(animated: false)
            var didReleaseInside = false
            window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .greatestFiniteMagnitude, mode: .eventTracking) { [weak self] ev, stop in
                guard let self, let ev else { stop.pointee = true; return }
                let local = self.convert(ev.locationInWindow, from: nil)
                let inside = (self.customTrackingRect ?? self.bounds).contains(local)
                if ev.type == .leftMouseDragged {
                    if self.hovered != inside || self.pressed != inside {
                        self.pointerInside = inside
                        self.hovered = inside
                        self.pressed = inside
                        self.updateInteraction(animated: true)
                    }
                } else {
                    didReleaseInside = inside
                    self.pointerInside = inside
                    self.hovered = inside
                    self.pressed = false
                    self.updateInteraction(animated: true)
                    stop.pointee = true
                }
            }
            if didReleaseInside {
                sendAction(action, to: target)
            }
            return
        }
        pressed = true; updateInteraction(animated: false)
        defer { pressed = false; updateInteraction(animated: false) }
        super.mouseDown(with: event)
    }
    static func checkHoverFeedback() async -> Bool {
        let previous = NSApp.keyWindow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Synthetic enter/exit events must not race AppKit's tracking of the
        // real pointer, which remains untouched during this check.
        final class FeedbackProbe: ToolbarPlaybackButton {
            override func updateTrackingAreas() {}
        }
        let button = FeedbackProbe(frame: NSRect(x: 20, y: 20, width: 28, height: 28))
        button.isBordered = false; button.setSymbol("play.fill", size: 19)
        window.contentView?.addSubview(button)
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 {
            if window.isKeyWindow { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        var focusLost = false
        let focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in focusLost = true }
        defer {
            NotificationCenter.default.removeObserver(focusObserver)
            window.orderOut(nil); previous?.makeKeyAndOrderFront(nil)
        }
        func hasStableFocus() -> Bool {
            guard window.isKeyWindow, !focusLost else {
                log("UNAVAILABLE: hover check lost window focus; no appearance assertion was evaluated for the inactive state")
                return false
            }
            return true
        }
        button.layoutSubtreeIfNeeded()
        // Let AppKit finish its initial tracking-area/key-window notifications
        // before injecting the synthetic hover (without moving the user's pointer).
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard hasStableFocus() else { return false }
        let event = NSEvent(cgEvent: CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left)!)!
        button.mouseEntered(with: event)
        guard hasStableFocus() else { return false }
        precondition(button.hoverLayer.opacity == 0)
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard hasStableFocus() else { return false }
        precondition(button.hoverLayer.opacity == 0, "No immediate hover plate")
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard hasStableFocus() else { return false }
        precondition(abs(button.hoverLayer.opacity - 0.065) < 0.001, "Delayed native hover plate")
        button.mouseExited(with: event)
        guard hasStableFocus() else { return false }
        precondition(button.hoverLayer.opacity == 0)
        button.mouseEntered(with: event); button.mouseExited(with: event)
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard hasStableFocus() else { return false }
        precondition(button.hoverLayer.opacity == 0, "Leaving cancels delayed highlight")
        guard hasStableFocus() else { return false }
        button.usesElevation = true; button.updateInteraction()
        guard hasStableFocus() else { return false }
        precondition(button.hoverLayer.opacity == 0 && abs((button.layer?.shadowOpacity ?? 0) - 0.4) < 0.001, "Elevation base: key=\(window.isKeyWindow), enabled=\(button.isEnabled), shadow=\(button.layer?.shadowOpacity ?? -1), plate=\(button.hoverLayer.opacity)")
        button.mouseEntered(with: event)
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard hasStableFocus() else { return false }
        precondition(button.hoverLayer.opacity == 0 && abs((button.layer?.shadowOpacity ?? 0) - 0.78) < 0.001)
        button.animatesPress = true; button.drawsSymbolTransition = true
        button.pressed = true; button.updateInteraction()
        precondition(button.contentTintColor != NSColor.white && (button.cell as? NSButtonCell)?.highlightsBy == [], "Press keeps the transport tint and disables native white highlighting")
        precondition((button.layer?.shadowOpacity ?? 1) < 0.02, "Press flattens the elevated symbol")
        precondition(abs((button.layer?.transform.m11 ?? 0) - 0.86) < 0.001, "Transport shrinks while held")
        button.pressed = false; button.updateInteraction()
        precondition(abs((button.layer?.transform.m11 ?? 0) - 1) < 0.001, "Transport restores on release")
        button.setSymbol("pause.fill", size: 19)
        button.setSymbol("play.fill", size: 19)
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard hasStableFocus() else { return false }
        precondition(button.transportSymbol.symbol == "play.fill" && button.transportSymbol.hasImage, "Rapid Play/Pause changes must settle on the latest symbol")
        log("PASS: transport uses delayed elevation without a hover plate, flattens on press, and settles on the latest symbol")
        let route = ToolbarRoutePicker(frame: NSRect(x: 55, y: 20, width: 24, height: 24))
        window.contentView?.addSubview(route)

        let glyphMute = FeedbackProbe(frame: NSRect(x: 5, y: 20, width: 28, height: 32))
        glyphMute.isBordered = false; glyphMute.symbolTransition = .crossfade; glyphMute.drawsSymbolTransition = true
        glyphMute.glyphOnlyHover = true; glyphMute.setSymbol("speaker.wave.2.fill", size: 10, animated: false)
        window.contentView?.addSubview(glyphMute)
        glyphMute.layoutSubtreeIfNeeded()
        glyphMute.mouseEntered(with: event)
        guard hasStableFocus() else { return false }
        let expectedHoverTint: NSColor = glyphMute.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
        precondition(glyphMute.hoverLayer.opacity == 0 && glyphMute.hovered && glyphMute.contentTintColor == expectedHoverTint, "Glyph-only hover highlights immediately without a plate")
        glyphMute.mouseExited(with: event)
        precondition(!glyphMute.hovered && glyphMute.hoverLayer.opacity == 0 && glyphMute.contentTintColor == .secondaryLabelColor, "Glyph-only hover restores secondary gray on exit")

        window.resignKey(); precondition(button.hoverLayer.opacity == 0)
        precondition(abs(route.alphaValue - 0.3) < 0.001, "AirPlay must dim with the inactive window")
        log("PASS: native AirPlay picker dims to the same inactive gray")
        log("PASS: toolbar hover waits 400 ms, uses 6.5% neutral plate, cancels on leave and dims when inactive")
        return true
    }
    private func updateInteraction(animated: Bool = true) {
        let active = isEnabled && MacWindowLifecycle.shared.isWindowVisuallyActive(playerControlWindow(for: self))
        let lit = active && (hovered || pressed || isLatched)
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : lit ? RailButton.hoverFadeIn : RailButton.hoverFadeOut
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin(); CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        hoverLayer.backgroundColor = (dark ? NSColor.white : NSColor.black).cgColor
        hoverLayer.opacity = usesElevation || textOnlyHover || glyphOnlyHover ? 0 : lit ? (pressed ? 0.13 : 0.065) : 0
        CATransaction.commit()
        let baseTint: NSColor
        if !isEnabled || matchesDisabledTint {
            baseTint = .disabledControlTextColor
        } else if !active {
            baseTint = NSColor.labelColor.withAlphaComponent(0.3)
        } else if glyphOnlyHover {
            baseTint = (hovered || pressed) ? (dark ? .white : .black) : .secondaryLabelColor
        } else {
            baseTint = (pressed || isLatched) && !usesElevation ? .white : .secondaryLabelColor
        }
        contentTintColor = baseTint
        if textOnlyHover {
            let color: NSColor = !active ? NSColor.labelColor.withAlphaComponent(0.3) : hovered ? .controlAccentColor : .secondaryLabelColor
            let text = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 9), .foregroundColor: color])
            if !attributedTitle.isEqual(to: text) { attributedTitle = text }
        }
        if usesAccentTint && active { contentTintColor = .controlAccentColor }
        if usesLightGlyph && active { contentTintColor = .white }
        if drawsSymbolTransition {
            let glyphFade: TimeInterval = (glyphOnlyHover && animated) ? duration : 0
            transportSymbol.setTint(contentTintColor, fadeDuration: glyphFade)
        }
        if usesElevation, let layer {
            // Shadow follows the symbol alpha, never a rounded hover plate.
            layer.masksToBounds = false
            let nextOpacity: Float = !active ? 0.12 : pressed ? 0.015 : hovered ? 0.78 : 0.4
            let nextRadius: CGFloat = pressed ? 0.2 : hovered ? 3.6 : 1.7
            let nextOffset = CGSize(width: 0, height: pressed ? 0 : hovered ? -2.5 : -1)
            let oldOpacity = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
            let oldRadius = layer.presentation()?.shadowRadius ?? layer.shadowRadius
            let oldOffset = layer.presentation()?.shadowOffset ?? layer.shadowOffset
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = nextOpacity; layer.shadowRadius = nextRadius; layer.shadowOffset = nextOffset
            CATransaction.commit()
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for (key, from, to) in [("shadowOpacity", NSNumber(value: oldOpacity), NSNumber(value: nextOpacity)),
                                        ("shadowRadius", NSNumber(value: Double(oldRadius)), NSNumber(value: Double(nextRadius)))] {
                    let animation = CABasicAnimation(keyPath: key); animation.fromValue = from; animation.toValue = to
                    animation.duration = pressed ? 0.06 : 0.12; animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.add(animation, forKey: key)
                }
                let offset = CABasicAnimation(keyPath: "shadowOffset")
                offset.fromValue = NSValue(size: oldOffset); offset.toValue = NSValue(size: nextOffset)
                offset.duration = pressed ? 0.06 : 0.12; layer.add(offset, forKey: "shadowOffset")
            }
        }
        if animatesPress, let layer {
            let scale: CGFloat = active && pressed ? 0.86 : 1
            let pivot = CGPoint(x: bounds.midX - bounds.width * layer.anchorPoint.x, y: bounds.midY - bounds.height * layer.anchorPoint.y)
            let target = CATransform3DMakeAffineTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: pivot.x * (1 - scale), ty: pivot.y * (1 - scale)))
            if !CATransform3DEqualToTransform(layer.transform, target) {
                let old = layer.presentation()?.transform ?? layer.transform
                CATransaction.begin(); CATransaction.setDisableActions(true); layer.transform = target; CATransaction.commit()
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let animation = CABasicAnimation(keyPath: "transform")
                    animation.fromValue = NSValue(caTransform3D: old); animation.toValue = NSValue(caTransform3D: target)
                    animation.duration = pressed ? 0.06 : 0.10
                    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    layer.add(animation, forKey: "transportPress")
                }
            }
        }
    }
    override var isEnabled: Bool { didSet { if isEnabled != oldValue { updateTint() } } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activationObservers.forEach(NotificationCenter.default.removeObserver)
        activationObservers.removeAll()
        if window != nil {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, MacWindowLifecycle.visualActivationDidChange] {
                activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateTint() }
                })
            }
        }
        updateTint()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateTint() }
    private func updateTint() {
        if !isEnabled || playerControlWindow(for: self)?.isKeyWindow != true {
            hoverWork?.cancel(); pointerInside = false; hovered = false; pressed = false
        }
        updateInteraction(animated: false)
    }
    deinit { hoverWork?.cancel(); activationObservers.forEach(NotificationCenter.default.removeObserver) }
}

/// A wait exists only during a mouse press. Releasing outside or deactivating cancels it.
@MainActor final class HoldTransportButton: ToolbarPlaybackButton {
    var onSeek: (() -> Void)?
    private var held = false
    private var cancelled = false
    private var holdDelay: Timer?
    private var repeatTimer: Timer?
    private func cancelHold() {
        cancelled = true
        holdDelay?.invalidate(); repeatTimer?.invalidate()
        holdDelay = nil; repeatTimer = nil
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        held = false; cancelled = false
        let activation = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelHold() }
        }
        defer { cancelHold(); NotificationCenter.default.removeObserver(activation) }
        holdDelay = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.cancelled else { return }
                guard playerControlWindow(for: self)?.isKeyWindow == true else { self.cancelHold(); return }
                self.held = true; self.onSeek?()
                self.repeatTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        guard playerControlWindow(for: self)?.isKeyWindow == true else { self.cancelHold(); return }
                        self.onSeek?()
                    }
                }
                if let repeatTimer = self.repeatTimer { RunLoop.main.add(repeatTimer, forMode: .eventTracking) }
            }
        }
        if let holdDelay { RunLoop.main.add(holdDelay, forMode: .eventTracking) }
        let savedAction = action
        action = nil
        super.mouseDown(with: event)
        holdDelay?.invalidate(); repeatTimer?.invalidate(); action = savedAction
        if !held, !cancelled, playerControlWindow(for: self)?.isKeyWindow == true,
           bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) {
            sendAction(action, to: target)
        }
    }
    deinit { holdDelay?.invalidate(); repeatTimer?.invalidate() }
}
#endif
