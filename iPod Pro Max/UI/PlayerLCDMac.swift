#if canImport(AppKitBackend)
import AppKit

@MainActor final class PlayerLCD: NSVisualEffectView {
    private let content = PlayerLCDContent()
    private let innerShade = CAGradientLayer()
    private let leftShade = CAGradientLayer()
    private let rightShade = CAGradientLayer()
    private let lowerGlow = CAGradientLayer()
    private let rim = CAShapeLayer()
    private let bottomLight = CAShapeLayer()
    // Toolbar viewers normally impose an 8 pt vertical inset on custom views.
    // This glass insert fills its viewer, while the other toolbar controls keep that inset.
    override var frame: NSRect {
        get { super.frame }
        set {
            var fitted = newValue
            if let parent = superview, parent.bounds.height > 0 {
                fitted.origin.y = 3
                fitted.size.height = max(0, parent.bounds.height - 3)
            }
            super.frame = fitted
        }
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .underWindowBackground; blendingMode = .behindWindow; state = .active
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.masksToBounds = true
        // Shade falls inside the glass; no outer shadow or bright upper bevel.
        innerShade.colors = [NSColor.black.withAlphaComponent(0.035).cgColor,
                             NSColor.black.withAlphaComponent(0.07).cgColor,
                             NSColor.black.withAlphaComponent(0.22).cgColor]
        innerShade.locations = [0, 0.85, 1]
        innerShade.startPoint = CGPoint(x: 0.5, y: 0)
        innerShade.endPoint = CGPoint(x: 0.5, y: 1)
        for shade in [leftShade, rightShade] {
            shade.colors = [NSColor.black.withAlphaComponent(0.14).cgColor, NSColor.clear.cgColor]
            shade.startPoint = CGPoint(x: 0, y: 0.5); shade.endPoint = CGPoint(x: 1, y: 0.5)
        }
        rightShade.startPoint = CGPoint(x: 1, y: 0.5); rightShade.endPoint = CGPoint(x: 0, y: 0.5)
        lowerGlow.colors = [NSColor.white.withAlphaComponent(0.075).cgColor, NSColor.clear.cgColor]
        lowerGlow.startPoint = CGPoint(x: 0.5, y: 0); lowerGlow.endPoint = CGPoint(x: 0.5, y: 1)
        rim.fillColor = nil; rim.strokeColor = NSColor.black.withAlphaComponent(0.16).cgColor
        rim.lineWidth = 0.5
        bottomLight.fillColor = nil
        bottomLight.strokeColor = NSColor.white.withAlphaComponent(0.15).cgColor
        bottomLight.lineWidth = 0.5
        for decoration in [innerShade, leftShade, rightShade, lowerGlow, rim, bottomLight] { layer?.addSublayer(decoration) }
        addSubview(content)
    }
    var isSpectrumAnimating: Bool { content.isSpectrumAnimating }
    func checkComposition() { content.checkComposition() }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        innerShade.frame = bounds
        leftShade.frame = CGRect(x: 0, y: 0, width: 8, height: bounds.height)
        rightShade.frame = CGRect(x: bounds.width - 8, y: 0, width: 8, height: bounds.height)
        lowerGlow.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 6)
        rim.frame = bounds; bottomLight.frame = bounds
        let edges = CGMutablePath()
        edges.move(to: CGPoint(x: 0.25, y: bounds.height))
        edges.addLine(to: CGPoint(x: 0.25, y: 3))
        edges.move(to: CGPoint(x: bounds.width - 0.25, y: bounds.height))
        edges.addLine(to: CGPoint(x: bounds.width - 0.25, y: 3))
        rim.path = edges
        let light = CGMutablePath()
        light.move(to: CGPoint(x: 3, y: 0.25))
        light.addLine(to: CGPoint(x: bounds.width - 3, y: 0.25))
        bottomLight.path = light
        CATransaction.commit()
        content.frame = bounds
        content.needsLayout = true

    }
}

#endif
