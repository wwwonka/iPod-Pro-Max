#if canImport(AppKitBackend)
import AppKit

/// Keep the native field editor and bezel; draw a close-fitting focus edge over it.
@MainActor final class PlayerSearchField: NSSearchField {
    private let focusEdge = CAShapeLayer()
    private(set) var editing = false
    private weak var configuredEditor: NSTextView?
    private var activationObserver: NSObjectProtocol?
    private var editorSettings: (horizontal: Bool, vertical: Bool, tracksWidth: Bool, size: NSSize, min: NSSize, max: NSSize, drawsBackground: Bool)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = false; focusRingType = .none
        cell?.focusRingType = .none
        backgroundColor = .textBackgroundColor
        focusEdge.fillColor = NSColor.clear.cgColor; focusEdge.opacity = 0; focusEdge.lineWidth = 1.5
        layer?.addSublayer(focusEdge)
        if let textCell = cell as? NSTextFieldCell {
            textCell.usesSingleLineMode = true; textCell.isScrollable = true; textCell.wraps = false
            textCell.lineBreakMode = .byClipping
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        focusEdge.frame = bounds
        focusEdge.path = CGPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 2.5), cornerWidth: 5, cornerHeight: 5, transform: nil)
        focusEdge.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        CATransaction.commit()
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted || currentEditor() != nil { setEditing(true) }
        return accepted
    }
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event); setEditing(currentEditor() != nil) }
    func setEditing(_ value: Bool) {
        guard editing != value else { if value { revealCaret() }; return }
        editing = value
        if !value, let editor = configuredEditor, let saved = editorSettings {
            editor.isHorizontallyResizable = saved.horizontal; editor.isVerticallyResizable = saved.vertical
            editor.textContainer?.widthTracksTextView = saved.tracksWidth; editor.textContainer?.containerSize = saved.size
            editor.minSize = saved.min; editor.maxSize = saved.max
            editor.drawsBackground = saved.drawsBackground
            configuredEditor = nil; editorSettings = nil
        }
        if value { revealCaret() }
        let scale: CGFloat = value ? 1.025 : 1
        let old = layer?.presentation()?.transform ?? layer?.transform ?? CATransform3DIdentity
        let oldOpacity = focusEdge.presentation()?.opacity ?? focusEdge.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let anchor = layer?.anchorPoint ?? .zero
        let pivot = CGPoint(x: bounds.midX - bounds.width * anchor.x, y: bounds.midY - bounds.height * anchor.y)
        layer?.transform = CATransform3DMakeAffineTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: pivot.x * (1 - scale), ty: pivot.y * (1 - scale)))
        focusEdge.opacity = value ? 1 : 0
        CATransaction.commit()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: old); animation.toValue = NSValue(caTransform3D: layer?.transform ?? CATransform3DIdentity)
            animation.duration = 0.12; animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(animation, forKey: "searchFocus")
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = oldOpacity; fade.toValue = value ? 1 : 0
            fade.duration = 0.1; focusEdge.add(fade, forKey: "searchFocus")
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        if let window {
            activationObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.editing else { return }
                    self.window?.makeFirstResponder(nil); self.setEditing(false)
                }
            }
        }
    }
    deinit { if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }
    func revealCaret() {
        guard let editor = currentEditor() as? NSTextView else { return }
        guard let container = editor.textContainer, let manager = editor.layoutManager else { return }
        if configuredEditor !== editor {
            configuredEditor = editor
            editorSettings = (editor.isHorizontallyResizable, editor.isVerticallyResizable, container.widthTracksTextView, container.containerSize, editor.minSize, editor.maxSize, editor.drawsBackground)
        }
        editor.drawsBackground = false
        let height = editor.frame.height
        let width = editor.enclosingScrollView?.contentSize.width ?? bounds.width
        editor.isHorizontallyResizable = true; editor.isVerticallyResizable = false
        editor.minSize = NSSize(width: width, height: height); editor.maxSize = NSSize(width: 1_000_000, height: height)
        container.widthTracksTextView = false
        container.containerSize = NSSize(width: 1_000_000, height: max(1, height))
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).width + editor.textContainerInset.width * 2 + container.lineFragmentPadding * 2 + 4
        editor.setFrameSize(NSSize(width: max(width, ceil(used)), height: height))
        editor.scrollRangeToVisible(editor.selectedRange())
    }
}
#endif
