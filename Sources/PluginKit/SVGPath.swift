import Foundation

/// One step of an SVG path in the artwork's coordinates (y down), compatible with `CustomSymbol`.
public enum SVGPathStep: Sendable, Equatable {
    case move(Double, Double)
    case line(Double, Double)
    case curve(Double, Double, Double, Double, Double, Double)
    case close
}

/// Parsed single-path monochrome SVG badge, matching the subset supported by `CustomSymbol` (M, L, l, C, Z/z).
public struct ParsedSVGBadge: Sendable, Equatable {
    public var steps: [SVGPathStep]
    public var viewBoxWidth: Double
    public var viewBoxHeight: Double

    public init(steps: [SVGPathStep], viewBoxWidth: Double, viewBoxHeight: Double) {
        self.steps = steps
        self.viewBoxWidth = viewBoxWidth
        self.viewBoxHeight = viewBoxHeight
    }

    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var xs: [Double] = []
        var ys: [Double] = []
        for step in steps {
            switch step {
            case .move(let x, let y), .line(let x, let y):
                xs.append(x)
                ys.append(y)
            case .curve(let x1, let y1, let x2, let y2, let x, let y):
                xs.append(contentsOf: [x1, x2, x])
                ys.append(contentsOf: [y1, y2, y])
            case .close:
                break
            }
        }
        return (xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0)
    }
}

public enum SVGBadgeError: LocalizedError, Equatable {
    case unreadable
    case invalidRoot
    case nonSquareViewBox
    case multiplePaths
    case missingPath
    case unsupportedElements(String)
    case unsupportedCommands(String)
    case emptyPath

    public var errorDescription: String? {
        switch self {
        case .unreadable: "badge SVG could not be read as UTF-8 text"
        case .invalidRoot: "badge SVG must contain an <svg> element"
        case .nonSquareViewBox: "badge SVG must declare a square viewBox"
        case .multiplePaths: "badge SVG must contain a single <path> element"
        case .missingPath: "badge SVG must contain a <path d=\"…\"> element"
        case .unsupportedElements(let name): "badge SVG contains unsupported element <\(name)>; only a single <path> is allowed"
        case .unsupportedCommands(let cmd): "badge SVG path uses unsupported command '\(cmd)'; only M, L, C and Z are supported"
        case .emptyPath: "badge SVG path contains no geometry"
        }
    }
}

public enum SVGBadgeParser {
    /// Parses and validates a plug-in badge SVG against Annexe B:
    /// - valid `<svg>` with a square `viewBox` (or equal `width`/`height`)
    /// - exactly one `<path>` (no `<circle>`, `<rect>`, `<polygon>`, `<text>`, etc.)
    /// - path data using only `M`, `L`, `l`, `C`, `Z`/`z`.
    public static func parse(data: Data) throws -> ParsedSVGBadge {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SVGBadgeError.unreadable
        }
        return try parse(svgString: text)
    }

    public static func parse(svgString: String) throws -> ParsedSVGBadge {
        let trimmed = svgString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let svgOpen = firstTag(named: "svg", in: trimmed) else {
            throw SVGBadgeError.invalidRoot
        }

        let (vw, vh) = try parseViewBox(in: svgOpen)
        guard vw > 0, vh > 0, abs(vw - vh) < 0.001 else {
            throw SVGBadgeError.nonSquareViewBox
        }

        let disallowed = ["circle", "rect", "ellipse", "polygon", "polyline", "line", "text", "image", "use"]
        for tag in disallowed {
            if firstTag(named: tag, in: trimmed) != nil {
                throw SVGBadgeError.unsupportedElements(tag)
            }
        }

        let paths = allTags(named: "path", in: trimmed)
        guard !paths.isEmpty else { throw SVGBadgeError.missingPath }
        guard paths.count == 1 else { throw SVGBadgeError.multiplePaths }

        guard let d = attributeValue(named: "d", in: paths[0]) else {
            throw SVGBadgeError.missingPath
        }
        let steps = try parsePathData(d)
        guard !steps.isEmpty else { throw SVGBadgeError.emptyPath }
        return ParsedSVGBadge(steps: steps, viewBoxWidth: vw, viewBoxHeight: vh)
    }

    public static func parsePathData(_ svgPath: String) throws -> [SVGPathStep] {
        var steps: [SVGPathStep] = []
        var numbers: [Double] = []
        var command: Character = "M"
        var current = (x: 0.0, y: 0.0)

        func flush() {
            switch command {
            case "M" where numbers.count >= 2:
                steps.append(.move(numbers[0], numbers[1]))
                current = (numbers[0], numbers[1])
            case "L" where numbers.count >= 2:
                steps.append(.line(numbers[0], numbers[1]))
                current = (numbers[0], numbers[1])
            case "l" where numbers.count >= 2:
                current = (current.x + numbers[0], current.y + numbers[1])
                steps.append(.line(current.x, current.y))
            case "C" where numbers.count >= 6:
                steps.append(.curve(numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], numbers[5]))
                current = (numbers[4], numbers[5])
            default:
                break
            }
            numbers = []
        }

        var token = ""
        func endNumber() {
            if let value = Double(token) { numbers.append(value) }
            token = ""
        }

        let allowed: Set<Character> = ["M", "L", "l", "C", "Z", "z"]
        for ch in svgPath {
            if ch.isLetter {
                // Allow scientific notation exponent like 1e-5
                if (ch == "e" || ch == "E"), !token.isEmpty {
                    token.append(ch)
                    continue
                }
                endNumber()
                flush()
                guard allowed.contains(ch) else {
                    throw SVGBadgeError.unsupportedCommands(String(ch))
                }
                command = ch
                if ch == "Z" || ch == "z" {
                    steps.append(.close)
                }
            } else if ch == " " || ch == "," || ch == "\n" || ch == "\r" || ch == "\t" {
                endNumber()
                let arity = command == "C" ? 6 : 2
                if numbers.count == arity { flush() }
            } else if ch == "-" && !token.isEmpty && !token.hasSuffix("e") && !token.hasSuffix("E") {
                endNumber()
                let arity = command == "C" ? 6 : 2
                if numbers.count == arity { flush() }
                token.append(ch)
            } else {
                token.append(ch)
            }
        }
        endNumber()
        flush()
        return steps
    }

    private static func firstTag(named name: String, in text: String) -> String? {
        allTags(named: name, in: text).first
    }

    private static func allTags(named name: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<\(name)\\b[^>]*>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func attributeValue(named attr: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(attr)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')",
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, range: range) else { return nil }
        for idx in [1, 2] {
            if let r = Range(match.range(at: idx), in: tag) {
                return String(tag[r])
            }
        }
        return nil
    }

    private static func parseViewBox(in svgTag: String) throws -> (Double, Double) {
        if let vb = attributeValue(named: "viewBox", in: svgTag) {
            let parts = vb.split { $0 == " " || $0 == "," || $0 == "\t" }.compactMap { Double($0) }
            if parts.count == 4 {
                return (parts[2], parts[3])
            }
            throw SVGBadgeError.nonSquareViewBox
        }
        if let w = attributeValue(named: "width", in: svgTag).flatMap({ Double($0.replacingOccurrences(of: "px", with: "")) }),
           let h = attributeValue(named: "height", in: svgTag).flatMap({ Double($0.replacingOccurrences(of: "px", with: "")) }) {
            return (w, h)
        }
        throw SVGBadgeError.nonSquareViewBox
    }
}
