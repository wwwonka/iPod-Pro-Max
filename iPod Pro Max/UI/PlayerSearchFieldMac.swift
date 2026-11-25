#if canImport(AppKitBackend)
import AppKit

private final class PlayerSearchFieldCell: NSSearchFieldCell {
    private func alignedTextRect(forBounds rect: NSRect) -> NSRect {
        let cancelX = cancelButtonRect(forBounds: rect).minX
        let x = rect.minX + 26
        let textHeight: CGFloat = 16
        return NSRect(x: x, y: floor((rect.height - textHeight) / 2), width: max(0, cancelX - x + 4.5), height: textHeight)
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect { alignedTextRect(forBounds: rect) }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { alignedTextRect(forBounds: rect) }
    override func titleRect(forBounds rect: NSRect) -> NSRect { alignedTextRect(forBounds: rect) }

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        let r = super.searchButtonRect(forBounds: rect)
        let width = max(r.width, 22)
        // Center the 12.5 pt loupe glyph at 7.0 pt from left and +1 pt vertically to counter SF Symbol top-bias.
        let x = rect.minX + 7.0 - (width - 12.5) / 2.0
        return NSRect(x: x, y: floor((rect.height - r.height) / 2) + 1.0, width: width, height: r.height)
    }

    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        let r = super.cancelButtonRect(forBounds: rect)
        // Position 13 pt cancel circle at 7.0 pt from right bezel edge.
        return NSRect(x: rect.maxX - 24.5, y: floor((rect.height - r.height) / 2), width: r.width, height: r.height)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: rect, in: controlView, editor: textObj, delegate: delegate, event: event)
        alignFieldEditor(textObj, forCellBounds: rect)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: rect, in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
        alignFieldEditor(textObj, forCellBounds: rect)
    }

    private func alignFieldEditor(_ textObj: NSText, forCellBounds rect: NSRect) {
        let target = alignedTextRect(forBounds: rect)
        if let clip = textObj.superview as? NSClipView, clip.frame != target {
            clip.frame = target
            clip.bounds = NSRect(origin: target.origin, size: target.size)
        }
        if textObj.frame.origin != target.origin || textObj.frame.height != target.height || textObj.frame.width < target.width {
            textObj.frame = NSRect(origin: target.origin, size: NSSize(width: max(target.width, textObj.frame.width), height: target.height))
        }
        textObj.minSize = target.size
    }

    override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect {
        cellFrame
    }

    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSBezierPath(roundedRect: cellFrame, xRadius: 5.5, yRadius: 5.5).fill()
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        searchButtonCell?.draw(withFrame: searchButtonRect(forBounds: cellFrame), in: controlView)
        if !stringValue.isEmpty {
            cancelButtonCell?.draw(withFrame: cancelButtonRect(forBounds: cellFrame), in: controlView)
        }
        guard (controlView as? NSTextField)?.currentEditor() == nil else { return }
        let rect = alignedTextRect(forBounds: cellFrame).insetBy(dx: 2, dy: 0)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        if stringValue.isEmpty, let placeholder = placeholderAttributedString {
            placeholder.draw(in: rect)
        } else if !stringValue.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: textColor ?? NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            (stringValue as NSString).draw(
                in: NSRect(x: rect.minX, y: rect.minY, width: 10000, height: rect.height),
                withAttributes: attrs
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Translucent macOS rounded-rect search field matching native Sequoia geometry, centering, and NSFocusRing.
@MainActor final class PlayerSearchField: NSSearchField {
    private struct AppearanceKey: Equatable {
        var active: Bool
        var dark: Bool
        var focused: Bool
        var prompt: String
    }

    private(set) var editing = false
    var willDeactivateWindow: (() -> Void)?
    private var activationObservers: [NSObjectProtocol] = []
    private var promptText = "Search"
    private var lastAppearanceKey: AppearanceKey?
    private var lastTextKey: (active: Bool, dark: Bool, prompt: String)?
    private var lastIconKey: (active: Bool, dark: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let customCell = PlayerSearchFieldCell(textCell: "")
        customCell.controlSize = .regular
        customCell.font = .systemFont(ofSize: 13)
        customCell.usesSingleLineMode = true
        customCell.isScrollable = true
        customCell.wraps = false
        customCell.lineBreakMode = .byClipping
        customCell.isBezeled = false
        customCell.isBordered = false
        customCell.drawsBackground = false
        customCell.focusRingType = .exterior
        customCell.isEditable = true
        customCell.isSelectable = true
        customCell.cancelButtonCell?.highlightsBy = .contentsCellMask
        cell = customCell

        wantsLayer = true
        layer?.masksToBounds = false
        if #available(macOS 14.0, *) { clipsToBounds = false }
        focusRingType = .exterior
        isBezeled = false
        isBordered = false
        drawsBackground = false

        applyScale()
        updateAppearance(force: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { false }
    override var focusRingMaskBounds: NSRect { isVisuallyActive() ? bounds : .zero }

    override func drawFocusRingMask() {
        guard isVisuallyActive() else { return }
        NSBezierPath(roundedRect: bounds, xRadius: 5.5, yRadius: 5.5).fill()
    }

    private func syncFocusRingType(active: Bool) {
        let target: NSFocusRingType = active ? .exterior : .none
        if focusRingType != target {
            focusRingType = target
            (cell as? NSSearchFieldCell)?.focusRingType = target
            noteFocusRingMaskChanged()
        }
    }

    func prepareForReactivationFocus() {
        syncFocusRingType(active: true)
    }

    private func applyScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if layer?.contentsScale != scale {
            layer?.contentsScale = scale
        }
    }

    func setPrompt(_ prompt: String) {
        guard promptText != prompt else { return }
        promptText = prompt
        updateAppearance(force: true)
    }

    override func layout() {
        super.layout()
        applyScale()
        updateAppearance()
    }

    override func becomeFirstResponder() -> Bool {
        guard isVisuallyActive() else {
            setEditing(false)
            return false
        }
        let accepted = super.becomeFirstResponder()
        if accepted || currentEditor() != nil {
            configureFieldEditor()
            editing = true
            needsDisplay = true
        }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        if !event.modifierFlags.contains(.command), let window, !isVisuallyActive() {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        }
        guard isVisuallyActive() else {
            syncFocusRingType(active: false)
            if currentEditor() != nil { window?.endEditing(for: nil) }
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            setEditing(false)
            updateAppearance(force: true)
            displayIfNeeded()
            return
        }
        if let searchCell = cell as? NSSearchFieldCell {
            let local = convert(event.locationInWindow, from: nil)
            if searchCell.searchButtonRect(forBounds: bounds).contains(local) {
                if currentEditor() == nil {
                    window?.makeFirstResponder(self)
                    selectText(nil)
                }
                configureFieldEditor()
                setEditing(currentEditor() != nil || window?.firstResponder === self)
                return
            }
        }
        super.mouseDown(with: event)
        guard isVisuallyActive() else {
            syncFocusRingType(active: false)
            if currentEditor() != nil { window?.endEditing(for: nil) }
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            setEditing(false)
            updateAppearance(force: true)
            displayIfNeeded()
            return
        }
        configureFieldEditor()
        setEditing(currentEditor() != nil)
    }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        configureFieldEditor()
        setEditing(true)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        setEditing(false)
        needsDisplay = true
    }

    func setEditing(_ value: Bool) {
        guard editing != value else { return }
        editing = value
        if value {
            configureFieldEditor()
            revealCaret()
        }
        updateAppearance(force: true)
    }

    private func isVisuallyActive() -> Bool {
        MacWindowLifecycle.shared.isWindowVisuallyActive(window)
    }

    private func configureFieldEditor() {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.drawsBackground = false
        (editor.superview as? NSClipView)?.drawsBackground = false
        editor.enclosingScrollView?.drawsBackground = false
        editor.textColor = textColor
        editor.insertionPointColor = .controlAccentColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = isVisuallyActive()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let focused = (editing || currentEditor() != nil) && active
        let saved = NSAppearance.current
        NSAppearance.current = effectiveAppearance
        defer { NSAppearance.current = saved }

        let alpha: CGFloat = dark ? 0.08 : 0.043
        let tone = dark ? NSColor.white : NSColor.black
        if focused || !active {
            tone.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5.5, yRadius: 5.5).fill()
        } else {
            let strokeRect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: strokeRect, xRadius: 5.0, yRadius: 5.0)
            path.lineWidth = 1.0
            tone.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
        super.draw(dirtyRect)
    }

    @available(macOS 11.0, *)
    private func tintedSymbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)) else { return nil }
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            resolved.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    func updateAppearance(force: Bool = false) {
        let active = isVisuallyActive()
        syncFocusRingType(active: active)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let focused = (editing || currentEditor() != nil) && active
        let key = AppearanceKey(active: active, dark: dark, focused: focused, prompt: promptText)
        guard force || key != lastAppearanceKey else { return }
        lastAppearanceKey = key

        let saved = NSAppearance.current
        NSAppearance.current = effectiveAppearance
        defer { NSAppearance.current = saved }

        if lastTextKey?.active != active || lastTextKey?.dark != dark || lastTextKey?.prompt != promptText {
            lastTextKey = (active, dark, promptText)
            textColor = active
                ? .labelColor
                : NSColor.labelColor.withAlphaComponent(dark ? 0.5 : 0.45)
            let placeholderColor = active
                ? NSColor.placeholderTextColor
                : (dark
                    ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.295)
                    : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
            let fieldFont = font ?? .systemFont(ofSize: 13)
            placeholderAttributedString = NSAttributedString(
                string: promptText,
                attributes: [.font: fieldFont, .foregroundColor: placeholderColor]
            )
        }

        if lastIconKey?.active != active || lastIconKey?.dark != dark,
           #available(macOS 11.0, *), let searchCell = cell as? NSSearchFieldCell {
            lastIconKey = (active, dark)
            let iconColor: NSColor = if dark {
                NSColor(srgbRed: 1, green: 1, blue: 1, alpha: active ? 0.55 : 0.295)
            } else {
                NSColor(srgbRed: 0, green: 0, blue: 0, alpha: active ? 0.55 : 0.28)
            }
            searchCell.searchButtonCell?.image = tintedSymbol("magnifyingglass", pointSize: 12.5, color: iconColor)

            let cancelNormal = tintedSymbol("xmark.circle.fill", pointSize: 13, color: iconColor)
            searchCell.cancelButtonCell?.highlightsBy = .contentsCellMask
            searchCell.cancelButtonCell?.image = cancelNormal
            if active {
                let pressedColor = dark
                    ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.94)
                    : NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1.0)
                searchCell.cancelButtonCell?.alternateImage = tintedSymbol("xmark.circle.fill", pointSize: 13, color: pressedColor)
            } else {
                searchCell.cancelButtonCell?.alternateImage = cancelNormal
            }
        }

        configureFieldEditor()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lastIconKey = nil
        lastTextKey = nil
        updateAppearance(force: true)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
        updateAppearance(force: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScale()
        activationObservers.forEach(NotificationCenter.default.removeObserver)
        activationObservers.removeAll()
        if let window {
            let events: [(Notification.Name, Any?)] = [
                (NSWindow.didBecomeKeyNotification, window),
                (NSWindow.didResignKeyNotification, window),
                (MacWindowLifecycle.visualActivationDidChange, nil),
                (NSApplication.didBecomeActiveNotification, nil),
                (NSApplication.didResignActiveNotification, nil)
            ]
            for (name, targetObject) in events {
                activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: targetObject, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let active = self.isVisuallyActive()
                        self.syncFocusRingType(active: active)
                        if !active {
                            self.willDeactivateWindow?()
                            if self.currentEditor() != nil { self.window?.endEditing(for: nil) }
                            if self.window?.firstResponder === self { self.window?.makeFirstResponder(nil) }
                            self.setEditing(false)
                            self.noteFocusRingMaskChanged()
                            self.updateAppearance(force: true)
                            self.displayIfNeeded()
                        } else {
                            self.updateAppearance(force: true)
                        }
                    }
                })
            }
        }
        updateAppearance(force: true)
    }

    deinit { activationObservers.forEach(NotificationCenter.default.removeObserver) }

    func revealCaret() {
        guard let editor = currentEditor() as? NSTextView else { return }
        if !stringValue.isEmpty, let container = editor.textContainer, let manager = editor.layoutManager {
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            let clipWidth = editor.superview?.bounds.width ?? bounds.width
            let glyphEnd = ceil(used.maxX + editor.textContainerInset.width + container.lineFragmentPadding)
            let targetWidth = max(clipWidth, glyphEnd)
            if abs(editor.frame.width - targetWidth) > 0.5 {
                editor.setFrameSize(NSSize(width: targetWidth, height: editor.frame.height))
            }
        }
        editor.scrollRangeToVisible(editor.selectedRange())
    }
}
#endif
