import Foundation

// Symbols that SF Symbols doesn't have, drawn from SVG artwork and used exactly like an SF Symbol:
// by name (`systemSymbol("apple-music", pointSize: 25)`, `Symbol(name: "apple-music")`), as a
// template image that takes the tint, hover, press and selection states of any other symbol.
// The artwork lives in Resources/Symbols/<name>.svg; its path data is copied below.

/// One step of an SVG path, in the artwork's own coordinates (y down).
enum CustomSymbolStep {
    case move(Double, Double)
    case line(Double, Double)
    case curve(Double, Double, Double, Double, Double, Double)
    case close
}

struct CustomSymbol {
    var steps: [CustomSymbolStep]

    /// Parses the M, L, C and Z commands of an SVG path (what this artwork uses).
    init(svgPath: String) {
        var steps: [CustomSymbolStep] = []
        var numbers: [Double] = []
        var command: Character = "M"
        var current = (x: 0.0, y: 0.0)
        func flush() {
            switch command {
            case "M" where numbers.count >= 2: steps.append(.move(numbers[0], numbers[1])); current = (numbers[0], numbers[1])
            case "L" where numbers.count >= 2: steps.append(.line(numbers[0], numbers[1])); current = (numbers[0], numbers[1])
            case "l" where numbers.count >= 2:
                current = (current.x + numbers[0], current.y + numbers[1]); steps.append(.line(current.x, current.y))
            case "C" where numbers.count >= 6:
                steps.append(.curve(numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], numbers[5]))
                current = (numbers[4], numbers[5])
            default: break
            }
            numbers = []
        }
        var token = ""
        func endNumber() { if let value = Double(token) { numbers.append(value) }; token = "" }
        for character in svgPath {
            if character.isLetter {
                endNumber(); flush()
                command = character
                if character == "Z" || character == "z" { steps.append(.close) }
            } else if character == " " || character == "," {
                endNumber()
                let arity = command == "C" ? 6 : 2
                if numbers.count == arity { flush() }
            } else {
                token.append(character)
            }
        }
        endNumber(); flush()
        self.steps = steps
    }

    /// The artwork's bounds, control points included (a safe over-estimate for centering).
    var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var xs: [Double] = [], ys: [Double] = []
        for step in steps {
            switch step {
            case .move(let x, let y), .line(let x, let y): xs.append(x); ys.append(y)
            case .curve(_, _, _, _, let x, let y): xs.append(x); ys.append(y)
            case .close: break
            }
        }
        return (xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0)
    }
}

/// The custom symbols, by name.
let customSymbols: [String: CustomSymbol] = [
    "apple-music": CustomSymbol(svgPath: "M 26.558 12.646 L 26.558 23.045 C 26.558 23.805 26.451 24.552 26.11 25.242 C 25.584 26.315 24.73 26.991 23.585 27.319 C 22.951 27.503 22.297 27.603 21.636 27.631 C 19.907 27.717 18.407 26.543 18.101 24.836 C 17.837 23.428 18.513 21.877 19.992 21.152 C 20.575 20.868 21.209 20.697 21.841 20.569 C 22.531 20.42 23.22 20.285 23.903 20.128 C 24.408 20.014 24.735 19.709 24.834 19.188 C 24.863 19.075 24.87 18.953 24.87 18.84 C 24.87 15.533 24.87 12.226 24.87 8.926 C 24.87 8.813 24.848 8.698 24.821 8.592 C 24.75 8.315 24.55 8.151 24.266 8.164 C 23.974 8.178 23.69 8.229 23.406 8.286 C 22.019 8.556 20.633 8.834 19.252 9.118 L 12.517 10.476 C 12.489 10.483 12.453 10.498 12.424 10.498 C 11.919 10.64 11.742 10.868 11.72 11.394 C 11.713 11.472 11.72 11.551 11.72 11.629 C 11.713 16.366 11.72 21.103 11.713 25.838 C 11.713 26.607 11.627 27.361 11.322 28.071 C 10.817 29.237 9.921 29.971 8.713 30.319 C 8.072 30.503 7.418 30.611 6.749 30.631 C 5.007 30.696 3.555 29.536 3.258 27.823 C 3.001 26.344 3.677 24.75 5.355 24.039 C 6.009 23.768 6.685 23.619 7.375 23.477 C 7.894 23.371 8.421 23.264 8.94 23.158 C 9.636 23.009 9.999 22.568 10.035 21.857 C 10.035 16.465 10.035 10.804 10.035 5.413 C 10.035 5.185 10.063 4.958 10.113 4.737 C 10.241 4.218 10.611 3.919 11.108 3.798 C 11.571 3.676 12.047 3.591 12.516 3.492 C 13.853 3.221 15.183 2.951 16.52 2.687 L 20.652 1.848 C 21.875 1.606 23.09 1.357 24.314 1.116 C 24.713 1.038 25.118 0.952 25.522 0.923 C 26.084 0.874 26.476 1.229 26.533 1.798 C 26.547 1.934 26.555 2.069 26.555 2.204 L 26.555 12.638 L 26.558 12.646 Z "),
]

/// Windows and Linux draw symbols from a font that has no glyph for them yet: they show the
/// closest SF Symbol meanwhile.
let customSymbolFontStandIns: [String: String] = [
    "apple-music": "music.note",
    "music.quarternote.3": "music.note",
]
