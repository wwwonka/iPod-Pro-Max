#if canImport(AppKitBackend)
import AppKit
import Symbols

/// AppKit owns the symbol transition and its interruption; no custom drawing masks.
@MainActor final class TransportSymbolView: NSView {
    /// `system` lets AppKit animate symbol images; `crossfade` pins the speaker mouth;
    /// `pinned` pins the glyph's ink centre, for glyphs whose boxes differ (play/pause).
    enum Transition { case system, crossfade, pinned }
    var transition: Transition = .system
    private let current = NSImageView(), outgoing = NSImageView()
    private let waveViews = [NSImageView(), NSImageView(), NSImageView()]
    private let slashShape = CAShapeLayer()
    private(set) var symbol = ""
    private var currentAnchor = NSPoint.zero, outgoingAnchor = NSPoint.zero
    private var speakerLevelActive = -1
    private var activeWaveVisibility = [false, false, false]
    private var slashShown = false
    private struct Glyph { let image: NSImage; let anchor: NSPoint }
    private static var glyphs: [String: Glyph] = [:]

    private struct SpeakerParts {
        let body: NSImage
        let bodySlashed: NSImage
        let waves: [NSImage]
        let anchor: NSPoint
        let slashStart: CGPoint
        let slashEnd: CGPoint
    }
    private static var speakerPartsCache: [String: SpeakerParts] = [:]

    private static func speakerParts(pointSize: Double, canvas: NSSize) -> SpeakerParts? {
        let key = "\(pointSize)|\(canvas.width)x\(canvas.height)"
        if let cached = speakerPartsCache[key] { return cached }
        guard let img0 = systemSymbol("speaker.fill", pointSize: pointSize),
              let img1 = systemSymbol("speaker.wave.1.fill", pointSize: pointSize),
              let img2 = systemSymbol("speaker.wave.2.fill", pointSize: pointSize),
              let img3 = systemSymbol("speaker.wave.3.fill", pointSize: pointSize) else { return nil }

        let targetX = (canvas.width - 20) / 2
        let targetY = canvas.height / 2
        let scale: CGFloat = 4
        let pw = Int(ceil(canvas.width * scale))
        let ph = Int(ceil(canvas.height * scale))
        guard pw > 0, ph > 0 else { return nil }

        func rasterize(_ image: NSImage, drawOrigin: NSPoint) -> NSBitmapImageRep? {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.cgContext.clear(CGRect(x: 0, y: 0, width: pw, height: ph))
            ctx.cgContext.scaleBy(x: scale, y: scale)
            image.draw(in: NSRect(origin: drawOrigin, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }

        // Measure `speaker.fill` cone exact horizontal bar X and vertical ink midpoint so
        // the trompette stays pixel-locked and centered vertically with Play (`targetY`).
        guard let probe = rasterize(img0, drawOrigin: .zero) else { return nil }
        var barX: Int?
        var coneMinY = ph, coneMaxY = -1
        for x in 0..<pw {
            var hasInk = false
            for y in 0..<ph where (probe.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 {
                hasInk = true
                coneMinY = min(coneMinY, y)
                coneMaxY = max(coneMaxY, y)
            }
            if hasInk && barX == nil { barX = x }
        }
        let anchorX = CGFloat(barX ?? 0) / scale
        let bodyCenterYFromBottom = coneMaxY >= coneMinY
            ? canvas.height - CGFloat(coneMinY + coneMaxY + 1) / (2 * scale)
            : img0.size.height / 2
        let baseOrigin = NSPoint(x: targetX - anchorX, y: targetY - bodyCenterYFromBottom)

        // Snap `wave3` cone vertically to the exact same `speaker.fill` cone Y (`coneMinY..coneMaxY` on canvas).
        guard let probe3 = rasterize(img3, drawOrigin: .zero) else { return nil }
        var w3MinY = ph, w3MaxY = -1
        let coneCheckLimitX = Int(ceil((anchorX + 5.8) * scale))
        for x in 0..<min(pw, coneCheckLimitX) {
            for y in 0..<ph where (probe3.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 {
                w3MinY = min(w3MinY, y); w3MaxY = max(w3MaxY, y)
            }
        }
        let w3CenterYFromBottom = w3MaxY >= w3MinY
            ? canvas.height - CGFloat(w3MinY + w3MaxY + 1) / (2 * scale)
            : img3.size.height / 2
        let w3Origin = NSPoint(x: targetX - anchorX, y: targetY - w3CenterYFromBottom)

        guard let rep0 = rasterize(img0, drawOrigin: baseOrigin),
              let rep1 = rasterize(img1, drawOrigin: baseOrigin),
              let rep2 = rasterize(img2, drawOrigin: baseOrigin),
              let rep3 = rasterize(img3, drawOrigin: w3Origin) else { return nil }

        func makeTemplateFromBitmap(_ rep: NSBitmapImageRep) -> NSImage {
            rep.size = canvas
            let out = NSImage(size: canvas)
            out.addRepresentation(rep)
            out.isTemplate = true
            return out
        }

        func makeDiffWave(from src: NSBitmapImageRep, subtracting sub: NSBitmapImageRep, minXPt: CGFloat) -> NSImage {
            let outRep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            let minPx = Int(floor(minXPt * scale))
            let zero = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0)
            for y in 0..<ph {
                for x in 0..<pw {
                    guard x >= minPx else {
                        outRep.setColor(zero, atX: x, y: y)
                        continue
                    }
                    let aSrc = src.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    let aSub = sub.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    let diff = max(0, aSrc - aSub)
                    if diff > 0.02 {
                        outRep.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: diff), atX: x, y: y)
                    } else {
                        outRep.setColor(zero, atX: x, y: y)
                    }
                }
            }
            return makeTemplateFromBitmap(outRep)
        }

        let slashStart = CGPoint(x: targetX - 0.7, y: targetY + 4.2)
        let slashEnd = CGPoint(x: targetX + 7.7, y: targetY - 4.2)

        let bodyImage = makeTemplateFromBitmap(rep0)
        let bodySlashedImage = NSImage(size: canvas, flipped: false) { _ in
            bodyImage.draw(in: NSRect(origin: .zero, size: canvas), from: .zero, operation: .sourceOver, fraction: 1)
            if let cg = NSGraphicsContext.current?.cgContext {
                cg.setBlendMode(.clear)
                cg.setLineCap(.round)
                cg.setLineWidth(2.45)
                cg.move(to: slashStart)
                cg.addLine(to: slashEnd)
                cg.strokePath()
            }
            return true
        }
        bodySlashedImage.isTemplate = true

        let w1 = makeDiffWave(from: rep1, subtracting: rep0, minXPt: targetX + 6.2)
        let w2 = makeDiffWave(from: rep2, subtracting: rep1, minXPt: targetX + 8.3)
        let w3 = makeDiffWave(from: rep3, subtracting: rep2, minXPt: targetX + 10.4)

        let parts = SpeakerParts(
            body: bodyImage,
            bodySlashed: bodySlashedImage,
            waves: [w1, w2, w3],
            anchor: NSPoint(x: targetX, y: targetY),
            slashStart: slashStart,
            slashEnd: slashEnd
        )
        speakerPartsCache[key] = parts
        return parts
    }
    /// Register the glyph's ink rather than its padded image box: play.fill and pause.fill
    /// otherwise sit 0.9 pt apart when AppKit centres their different image widths. The
    /// speaker instead keeps its rectangular mouth, so its waves grow to the right.
    /// This tiny raster measurement is cached once per symbol.
    private static func glyph(_ name: String, image: NSImage) -> Glyph {
        let cacheKey = "\(name)|\(image.size.width)|\(image.size.height)"
        if let cached = glyphs[cacheKey] { return cached }
        let scale: CGFloat = 8
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(image.size.width * scale)), pixelsHigh: Int(ceil(image.size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        context.cgContext.scaleBy(x: scale, y: scale)
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var anchor = name.hasPrefix("speaker")
            ? NSPoint(x: image.alignmentRect.minX, y: image.alignmentRect.midY)
            : NSPoint(x: image.alignmentRect.midX, y: image.alignmentRect.midY)
        if name.hasPrefix("speaker") {
            outer: for x in 0..<min(bitmap.pixelsWide, 32) {
                // Find the longest contiguous vertical run in this column so the thin diagonal
                // slash in `speaker.slash.fill` is skipped and every speaker glyph locks onto
                // the left edge of the speaker body.
                var runStart: Int?
                var bestStart = 0, bestEnd = -1
                for y in 0..<bitmap.pixelsHigh {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                        if runStart == nil { runStart = y }
                        if let s = runStart, y - s > bestEnd - bestStart { bestStart = s; bestEnd = y }
                    } else { runStart = nil }
                }
                if bestEnd - bestStart >= 16 {
                    anchor = NSPoint(x: CGFloat(x) / scale, y: image.size.height - CGFloat(bestStart + bestEnd + 1) / (2 * scale))
                    break outer
                }
            }
        } else {
            var minX = bitmap.pixelsWide, maxX = -1, minY = bitmap.pixelsHigh, maxY = -1
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            if maxX >= minX, maxY >= minY {
                anchor = NSPoint(x: CGFloat(minX + maxX + 1) / (2 * scale),
                                 y: image.size.height - CGFloat(minY + maxY + 1) / (2 * scale))
            }
        }
        let copy = image.copy() as! NSImage
        copy.alignmentRect = NSRect(origin: .zero, size: image.size)
        let glyph = Glyph(image: copy, anchor: anchor)
        glyphs[cacheKey] = glyph; return glyph
    }
    private static var alignedImages: [String: NSImage] = [:]
    private func alignedCanvasImage(name: String, raw: NSImage, anchor: NSPoint, target: NSPoint, canvas: NSSize) -> NSImage {
        let key = "\(name)|\(raw.size.width)x\(raw.size.height)|\(canvas.width)x\(canvas.height)|\(target.x)x\(target.y)|\(anchor.x)x\(anchor.y)"
        if let cached = Self.alignedImages[key] { return cached }
        let drawn = NSImage(size: canvas, flipped: false) { _ in
            raw.draw(in: NSRect(x: target.x - anchor.x, y: target.y - anchor.y, width: raw.size.width, height: raw.size.height),
                     from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        drawn.isTemplate = true
        Self.alignedImages[key] = drawn
        return drawn
    }
    static func checkSpeakerAlignment() {
        let view = TransportSymbolView(frame: NSRect(x: 0, y: 0, width: 28, height: 32))
        view.transition = .crossfade
        view.tint = .white
        for name in ["speaker.slash.fill", "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"] {
            view.setSymbol(name, image: systemSymbol(name, pointSize: 10), animated: false); view.layoutSubtreeIfNeeded()
            let mouth = NSPoint(x: view.current.frame.minX + view.currentAnchor.x, y: view.current.frame.minY + view.currentAnchor.y)
            precondition(abs(mouth.x - 4) < 0.01 && abs(mouth.y - 16) < 0.01, "Speaker mouth keeps an exact fixed anchor")
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let pxScale = max(1, rep.pixelsWide / 28)
                var hasBodyInk = false
                for x in (4 * pxScale)..<min(9 * pxScale, rep.pixelsWide) {
                    for y in (12 * pxScale)..<min(20 * pxScale, rep.pixelsHigh) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                        hasBodyInk = true
                    }
                }
                precondition(hasBodyInk, "Speaker body must render visible pixels for \(name)")
            }
        }
    }
    static func checkTransportAlignment() {
        let view = TransportSymbolView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        view.transition = .pinned
        var anchors: [String: NSPoint] = [:]
        for name in ["play.fill", "pause.fill", "stop.fill"] {
            view.setSymbol(name, image: systemSymbol(name, pointSize: 20), animated: false); view.layoutSubtreeIfNeeded()
            let center = NSPoint(x: view.current.frame.minX + view.currentAnchor.x, y: view.current.frame.minY + view.currentAnchor.y)
            precondition(abs(center.x - 14) < 0.01 && abs(center.y - 14) < 0.01, "Transport ink stays on the button centre")
            anchors[name] = view.currentAnchor
        }
        precondition(abs((anchors["play.fill"]?.x ?? 0) - (anchors["pause.fill"]?.x ?? 0)) > 0.5, "Play and Pause need different optical anchors")
        log("PASS: Play/Pause/Stop share one ink centre; raw anchors \(String(format: "%.2f/%.2f", anchors["play.fill"]?.x ?? 0, anchors["pause.fill"]?.x ?? 0)) pt")
    }
    var hasImage: Bool { current.image != nil }
    private var storedTint: NSColor?
    var tint: NSColor? {
        get { storedTint }
        set { setTint(newValue, fadeDuration: 0) }
    }
    func setTint(_ color: NSColor?, fadeDuration: TimeInterval) {
        let changed = storedTint != color
        storedTint = color
        applyTint(fadeDuration: changed ? fadeDuration : 0)
    }
    private func applyTint(fadeDuration: TimeInterval = 0) {
        let saved = NSAppearance.current; NSAppearance.current = effectiveAppearance
        defer { NSAppearance.current = saved }
        let nextTint = storedTint?.withAlphaComponent(1)
        let nextAlpha = storedTint?.alphaComponent ?? 1
        let resolvedCGColor = (storedTint ?? .secondaryLabelColor).cgColor
        if fadeDuration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = fadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            current.layer?.add(fade, forKey: "glyphHoverTint")
            outgoing.layer?.add(fade, forKey: "glyphHoverTint")
            for w in waveViews { w.layer?.add(fade, forKey: "glyphHoverTint") }
            let strokeAnim = CABasicAnimation(keyPath: "strokeColor")
            strokeAnim.fromValue = slashShape.presentation()?.strokeColor ?? slashShape.strokeColor
            strokeAnim.toValue = resolvedCGColor
            strokeAnim.duration = fadeDuration
            strokeAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            slashShape.add(strokeAnim, forKey: "glyphHoverTint")
        } else {
            current.layer?.removeAnimation(forKey: "glyphHoverTint")
            outgoing.layer?.removeAnimation(forKey: "glyphHoverTint")
            for w in waveViews { w.layer?.removeAnimation(forKey: "glyphHoverTint") }
            slashShape.removeAnimation(forKey: "glyphHoverTint")
        }
        current.contentTintColor = nextTint
        outgoing.contentTintColor = nextTint
        let wipeActive = current.layer?.mask != nil || outgoing.layer?.mask != nil
        if wipeActive {
            current.alphaValue = nextAlpha
            outgoing.alphaValue = nextAlpha
        } else if speakerLevelActive >= 0 {
            current.alphaValue = slashShown ? 0 : nextAlpha
            outgoing.alphaValue = slashShown ? nextAlpha : 0
        } else {
            current.alphaValue = nextAlpha
        }
        for (idx, w) in waveViews.enumerated() {
            w.contentTintColor = nextTint
            if speakerLevelActive >= 0 {
                w.alphaValue = activeWaveVisibility[idx] ? nextAlpha : 0
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        slashShape.strokeColor = resolvedCGColor
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTint(fadeDuration: 0) }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        current.imageScaling = .scaleNone; current.imageAlignment = .alignCenter
        current.wantsLayer = true; current.setAccessibilityElement(false)
        outgoing.imageScaling = .scaleNone; outgoing.imageAlignment = .alignCenter
        outgoing.wantsLayer = true; outgoing.setAccessibilityElement(false)
        addSubview(outgoing); addSubview(current)
        for w in waveViews {
            w.imageScaling = .scaleNone; w.imageAlignment = .alignCenter
            w.wantsLayer = true; w.alphaValue = 0; w.setAccessibilityElement(false)
            addSubview(w)
        }
        slashShape.fillColor = nil
        slashShape.lineCap = .round
        slashShape.lineWidth = 1.15
        slashShape.opacity = 0
        slashShape.strokeEnd = 0
        layer?.addSublayer(slashShape)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { cascadeWorkItems.forEach { $0.cancel() } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var rawCurrent: (name: String, image: NSImage, anchor: NSPoint)?
    private var rawOutgoing: (name: String, image: NSImage, anchor: NSPoint)?
    private var cascadeToken: UInt64 = 0
    private var cascadeWorkItems: [DispatchWorkItem] = []

    private func cancelCascade() {
        cascadeToken &+= 1
        for item in cascadeWorkItems { item.cancel() }
        cascadeWorkItems.removeAll()
        current.layer?.mask = nil
        outgoing.layer?.mask = nil
    }

    func setSpeakerCascade(from oldLevel: Int, to newLevel: Int, pointSize: Double, animated: Bool) {
        cancelCascade()
        let finalName = newLevel == 0 ? "speaker.slash.fill" : "speaker.wave.\(newLevel).fill"
        symbol = finalName
        speakerLevelActive = newLevel

        let canvas = bounds.size.width > 0 && bounds.size.height > 0 ? bounds.size : NSSize(width: 28, height: 32)
        guard let parts = Self.speakerParts(pointSize: pointSize, canvas: canvas) else {
            setSymbol(finalName, image: systemSymbol(finalName, pointSize: pointSize), animated: false)
            return
        }

        ensureSpeakerLayers(parts: parts, canvas: canvas)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let runAnimated = animated && oldLevel != newLevel && !reduced

        guard runAnimated else {
            applySpeakerInstant(level: newLevel, parts: parts)
            return
        }

        let token = cascadeToken
        let stepInterval: TimeInterval = 0.068
        let waveFadeDuration: TimeInterval = 0.115
        let slashDuration: TimeInterval = 0.165
        var delay: TimeInterval = 0

        func schedule(_ offset: TimeInterval, _ action: @escaping @MainActor () -> Void) {
            if offset <= 0 {
                action()
                return
            }
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.cascadeToken == token else { return }
                    action()
                }
            }
            cascadeWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + offset, execute: item)
        }

        if newLevel == 0 {
            var lv = oldLevel
            while lv >= 1 {
                let waveIdx = lv - 1
                schedule(delay) { [weak self] in
                    self?.fadeWave(index: waveIdx, visible: false, duration: waveFadeDuration)
                }
                delay += stepInterval
                lv -= 1
            }
            schedule(delay + 0.02) { [weak self] in
                self?.animateStaticBodySlash(appearing: true, parts: parts, duration: slashDuration, token: token)
            }
        } else if oldLevel == 0 {
            schedule(0) { [weak self] in
                self?.animateStaticBodySlash(appearing: false, parts: parts, duration: slashDuration, token: token)
            }
            delay = slashDuration * 0.72
            for lv in 1...newLevel {
                let waveIdx = lv - 1
                schedule(delay) { [weak self] in
                    self?.fadeWave(index: waveIdx, visible: true, duration: waveFadeDuration)
                }
                delay += stepInterval
            }
        } else {
            if newLevel > oldLevel {
                for lv in (oldLevel + 1)...newLevel {
                    let waveIdx = lv - 1
                    schedule(delay) { [weak self] in
                        self?.fadeWave(index: waveIdx, visible: true, duration: waveFadeDuration)
                    }
                    delay += stepInterval
                }
            } else {
                var lv = oldLevel
                while lv > newLevel {
                    let waveIdx = lv - 1
                    schedule(delay) { [weak self] in
                        self?.fadeWave(index: waveIdx, visible: false, duration: waveFadeDuration)
                    }
                    delay += stepInterval
                    lv -= 1
                }
            }
        }
    }

    private func ensureSpeakerLayers(parts: SpeakerParts, canvas: NSSize) {
        let frame = NSRect(origin: .zero, size: canvas)
        rawCurrent = ("speaker.fill", parts.body, parts.anchor)
        rawOutgoing = ("speaker.slash.fill", parts.bodySlashed, parts.anchor)
        currentAnchor = parts.anchor
        outgoingAnchor = parts.anchor
        if current.image !== parts.body { current.image = parts.body }
        if outgoing.image !== parts.bodySlashed { outgoing.image = parts.bodySlashed }
        current.frame = frame; current.imageAlignment = .alignCenter
        outgoing.frame = frame; outgoing.imageAlignment = .alignCenter
        for (i, w) in waveViews.enumerated() {
            if w.image !== parts.waves[i] { w.image = parts.waves[i] }
            w.frame = frame; w.imageAlignment = .alignCenter
        }
        let path = CGMutablePath()
        path.move(to: parts.slashStart)
        path.addLine(to: parts.slashEnd)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        slashShape.frame = frame
        slashShape.path = path
        CATransaction.commit()
    }

    private func applySpeakerInstant(level: Int, parts: SpeakerParts) {
        let tintAlpha = storedTint?.alphaComponent ?? 1
        current.layer?.mask = nil
        outgoing.layer?.mask = nil
        current.layer?.removeAllAnimations()
        outgoing.layer?.removeAllAnimations()
        for w in waveViews { w.layer?.removeAllAnimations() }
        slashShape.removeAllAnimations()

        let muted = (level == 0)
        slashShown = muted
        activeWaveVisibility = [level >= 1, level >= 2, level >= 3]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        current.alphaValue = muted ? 0 : tintAlpha
        outgoing.alphaValue = muted ? tintAlpha : 0
        slashShape.strokeEnd = muted ? 1 : 0
        slashShape.opacity = muted ? 1 : 0
        for (i, w) in waveViews.enumerated() {
            w.alphaValue = activeWaveVisibility[i] ? tintAlpha : 0
        }
        CATransaction.commit()
        applyTint(fadeDuration: 0)
    }

    private func fadeWave(index: Int, visible: Bool, duration: TimeInterval) {
        guard waveViews.indices.contains(index) else { return }
        activeWaveVisibility[index] = visible
        let view = waveViews[index]
        let tintAlpha = storedTint?.alphaComponent ?? 1
        let targetAlpha: CGFloat = visible ? tintAlpha : 0
        let currentAlpha = CGFloat(view.layer?.presentation()?.opacity ?? Float(view.alphaValue))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.alphaValue = targetAlpha
        CATransaction.commit()
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = currentAlpha
        anim.toValue = targetAlpha
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer?.add(anim, forKey: "waveFade")
    }

    private func animateStaticBodySlash(appearing: Bool, parts: SpeakerParts, duration: TimeInterval, token: UInt64) {
        slashShown = appearing
        let tintAlpha = storedTint?.alphaComponent ?? 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        current.alphaValue = tintAlpha
        outgoing.alphaValue = tintAlpha
        CATransaction.commit()

        let midPoint = CGPoint(
            x: (parts.slashStart.x + parts.slashEnd.x) / 2,
            y: (parts.slashStart.y + parts.slashEnd.y) / 2
        )
        let span: CGFloat = 14

        // Top-left half-plane reveals the pre-cutout body (`outgoing`); bottom-right half-plane keeps intact body (`current`).
        let topLeftMask = CAShapeLayer()
        topLeftMask.bounds = CGRect(x: -40, y: -40, width: 80, height: 80)
        topLeftMask.fillColor = NSColor.black.cgColor
        let topLeftPath = CGMutablePath()
        topLeftPath.move(to: CGPoint(x: -40, y: 40))
        topLeftPath.addLine(to: CGPoint(x: 40, y: 40))
        topLeftPath.addLine(to: CGPoint(x: -40, y: -40))
        topLeftPath.closeSubpath()
        topLeftMask.path = topLeftPath

        let bottomRightMask = CAShapeLayer()
        bottomRightMask.bounds = CGRect(x: -40, y: -40, width: 80, height: 80)
        bottomRightMask.fillColor = NSColor.black.cgColor
        let bottomRightPath = CGMutablePath()
        bottomRightPath.move(to: CGPoint(x: 40, y: 40))
        bottomRightPath.addLine(to: CGPoint(x: 40, y: -40))
        bottomRightPath.addLine(to: CGPoint(x: -40, y: -40))
        bottomRightPath.closeSubpath()
        bottomRightMask.path = bottomRightPath

        let startPos = appearing
            ? CGPoint(x: midPoint.x - span * 0.55, y: midPoint.y + span * 0.55)
            : CGPoint(x: midPoint.x + span * 0.55, y: midPoint.y - span * 0.55)
        let endPos = appearing
            ? CGPoint(x: midPoint.x + span * 0.55, y: midPoint.y - span * 0.55)
            : CGPoint(x: midPoint.x - span * 0.55, y: midPoint.y + span * 0.55)

        outgoing.layer?.mask = topLeftMask
        current.layer?.mask = bottomRightMask

        let timing = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        topLeftMask.position = endPos
        bottomRightMask.position = endPos
        slashShape.opacity = 1
        slashShape.strokeEnd = appearing ? 1 : 0
        CATransaction.commit()

        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: startPos)
        move.toValue = NSValue(point: endPos)
        move.duration = duration
        move.timingFunction = timing
        topLeftMask.add(move, forKey: "slashWipe")
        bottomRightMask.add(move, forKey: "slashWipe")

        let strokeAnim = CABasicAnimation(keyPath: "strokeEnd")
        strokeAnim.fromValue = appearing ? 0.0 : 1.0
        strokeAnim.toValue = appearing ? 1.0 : 0.0
        strokeAnim.duration = duration
        strokeAnim.timingFunction = timing
        slashShape.add(strokeAnim, forKey: "slashStroke")

        let cleanup = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.cascadeToken == token else { return }
                self.current.layer?.mask = nil
                self.outgoing.layer?.mask = nil
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.current.alphaValue = appearing ? 0 : (self.storedTint?.alphaComponent ?? 1)
                self.outgoing.alphaValue = appearing ? (self.storedTint?.alphaComponent ?? 1) : 0
                self.slashShape.opacity = appearing ? 1 : 0
                CATransaction.commit()
            }
        }
        cascadeWorkItems.append(cleanup)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: cleanup)
    }
    override func layout() {
        super.layout()
        let crossfadeFrame = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 16) / 2, width: 20, height: 16)
        for view in [current, outgoing] {
            let raw = view === current ? rawCurrent : rawOutgoing
            switch transition {
            case .system:
                view.frame = bounds
                view.imageAlignment = .alignCenter
            case .crossfade:
                if bounds.width > 0, bounds.height > 0 {
                    if speakerLevelActive >= 0, let parts = Self.speakerParts(pointSize: 10, canvas: bounds.size) {
                        ensureSpeakerLayers(parts: parts, canvas: bounds.size)
                    } else if let raw {
                        let target = NSPoint(x: crossfadeFrame.minX, y: bounds.midY)
                        view.frame = bounds
                        view.imageAlignment = .alignCenter
                        let aligned = alignedCanvasImage(name: raw.name, raw: raw.image, anchor: raw.anchor, target: target, canvas: bounds.size)
                        if view.image !== aligned { view.image = aligned }
                        if view === current { currentAnchor = target } else { outgoingAnchor = target }
                    }
                } else {
                    view.frame = bounds
                    view.imageAlignment = .alignBottomLeft
                }
            case .pinned:
                if let raw {
                    view.frame = NSRect(x: bounds.midX - raw.anchor.x, y: bounds.midY - raw.anchor.y,
                                        width: raw.image.size.width, height: raw.image.size.height)
                } else { view.frame = bounds }
                view.imageAlignment = .alignBottomLeft
            }
        }
    }
    func setSymbol(_ name: String, image: NSImage?, animated: Bool) {
        cancelCascade()
        if transition == .crossfade && name.hasPrefix("speaker") {
            let level = name == "speaker.slash.fill" ? 0 : name.contains("1") ? 1 : name.contains("2") ? 2 : name.contains("3") ? 3 : 0
            setSpeakerCascade(from: speakerLevelActive, to: level, pointSize: 10, animated: animated && speakerLevelActive >= 0)
            return
        }
        speakerLevelActive = -1
        for w in waveViews { w.alphaValue = 0 }
        slashShape.opacity = 0
        let oldAnchor = currentAnchor
        let oldRaw = rawCurrent
        let usesAnchor = transition != .system
        let resolved = usesAnchor ? image.map { Self.glyph(name, image: $0) } : nil
        let rawImage = resolved?.image ?? image
        currentAnchor = resolved?.anchor ?? .zero
        rawCurrent = rawImage.map { (name, $0, currentAnchor) }
        symbol = name
        needsLayout = true
        guard animated, current.image != nil, let rawImage, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if #available(macOS 14, *) { current.removeAllSymbolEffects() }
            current.layer?.removeAllAnimations(); outgoing.layer?.removeAllAnimations()
            rawOutgoing = nil; outgoing.image = nil; current.image = rawImage
            if usesAnchor { layoutSubtreeIfNeeded() }
            applyTint(); return
        }
        if usesAnchor {
            outgoingAnchor = oldAnchor
            rawOutgoing = oldRaw
            outgoing.image = current.image; outgoing.contentTintColor = current.contentTintColor
            current.image = rawImage
            needsLayout = true; layoutSubtreeIfNeeded()
            let alpha = tint?.alphaComponent ?? 1
            CATransaction.begin(); CATransaction.setDisableActions(true)
            outgoing.alphaValue = 0; current.alphaValue = alpha
            CATransaction.commit()
            for (view, from, to) in [(outgoing, alpha, CGFloat(0)), (current, CGFloat(0), alpha)] {
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = from; fade.toValue = to
                fade.duration = 0.14; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.layer?.add(fade, forKey: "symbolCrossfade")
            }
            return
        }
        if #available(macOS 15, *) {
            // This automatically gains SF Symbols' Draw transitions on macOS 26.
            current.setSymbolImage(rawImage, contentTransition: .replace.magic(fallback: .replace), options: .speed(3))
        } else if #available(macOS 14, *) {
            current.setSymbolImage(rawImage, contentTransition: .replace, options: .speed(3))
        } else { current.image = rawImage }
    }
}
#endif
