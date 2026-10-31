import Foundation
import SwiftCrossUI

// Window chrome like the SwiftUI app: no title bar, the sidebar runs to the top of the window, the
// traffic lights and the sidebar toggle sit at its top-left corner. SwiftCrossUI has no API for
// this, so each backend's native window is reached through `inspectWindow`:
// WindowChromeMac.swift, WindowChromeGtk.swift and WindowChromeWinUI.swift. They provide
// `windowChrome(colorScheme:)`, `toggleSidebar()`, `performWindowAction(_:)` and `TitleClearance`,
// and share the model below.
//
// The sidebar slide is the same on every platform:
// - the only state is the split view's position; the chrome moves it on the display's clock and,
//   every frame, SwiftCrossUI lays the panes out at the new width (the sidebar and the table are
//   native, so that's essentially the detail's header),
// - the sidebar accepts any width and its rows fill it, except during a slide: they keep the open
//   width, pinned to the right edge and clipped, so they slide with the edge instead of squeezing,
// - the header starts with a `TitleClearance`, which reads the sidebar's width as it is laid out:
//   the title follows the edge and stops clear of the traffic lights, with no state change.

/// The app's identifier: bundle identifier on macOS, application id (and icon name) on Linux.
let appIdentifier = "com.ipodpromax.proto"

/// Width of the open sidebar, at first.
let sidebarWidth = 230.0
/// How narrow and how wide dragging the sidebar's edge can make it.
let sidebarWidthRange = 180.0...400.0
/// The drawn traffic lights and toggle, measured on macOS: lights 12 pt round every 20 pt from
/// x = 20, then the toggle's 32 × 28 pt highlight from x = 92.
enum TitleBarButtons {
    static let lightsX = 20.0
    static let lightSize = 12.0
    static let lightSpacing = 8.0
    static let toggleGap = 20.0
    static let toggleSize = (width: 32.0, height: 28.0)
    static let width = lightsX + 3 * lightSize + 2 * lightSpacing + toggleGap + toggleSize.width
    /// Hover highlight: fades in and out like the Mac toolbar's.
    static let hoverFade = 0.15
}

/// Width the traffic lights and the sidebar toggle take at the window's top-left corner.
let titleBarControlsWidth = TitleBarButtons.width
/// Height of the title area: dragging it, outside its controls, moves the window.
let titleBarHeight = 52.0

/// Room the detail header keeps for the traffic lights and the toggle where the sidebar no longer
/// covers them.
func titleClearance(sidebarWidth width: Double) -> Double {
    max(0, titleBarControlsWidth - width)
}

/// One slide of the sidebar: 0.25 s with an ease-in-out curve, like SwiftUI's toggle. Also counts
/// frames and layout time for the `[bench]` line.
struct SidebarSlide {
    /// `IPPM_SLIDE_SECONDS=<s>` slows it down, to look at the frames.
    static let duration = ProcessInfo.processInfo.environment["IPPM_SLIDE_SECONDS"].flatMap(Double.init) ?? 0.25

    let from: Double
    let to: Double
    let duration: Double
    /// Width the sidebar's rows keep during the slide.
    var openWidth: Double { max(from, to) }
    private(set) var frames = 0
    private var layoutTime = 0.0
    private var slowestLayout = 0.0

    init(from: Double, to: Double, duration: Double = Self.duration) {
        self.from = from
        self.to = to
        self.duration = duration
    }

    /// The sidebar's width `elapsed` seconds in, and whether the slide is over.
    func width(after elapsed: Double) -> (width: Double, done: Bool) {
        let t = min(1, elapsed / duration)
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        return ((from + (to - from) * eased).rounded(), t >= 1)
    }

    /// Records one frame that took `layout` seconds to lay out.
    mutating func record(layout: Double) {
        frames += 1
        layoutTime += layout
        slowestLayout = max(slowestLayout, layout)
    }

    func logResult(elapsed: Double) {
        log("[bench] sidebar \(to == 0 ? "close" : "open"): \(frames) frames in \(Int(elapsed * 1000)) ms, "
            + "layout \(Int(layoutTime / Double(max(frames, 1)) * 1000)) ms per frame, slowest \(Int(slowestLayout * 1000)) ms")
    }
}

enum WindowAction {
    case close, minimize, zoom
}

extension View {
    /// Applies the scheme the chrome read from the system where SwiftCrossUI can't (GTK). Elsewhere
    /// the backend already follows the system, and forcing a value would pin it.
    @ViewBuilder
    func followingSystemColorScheme(_ scheme: ColorScheme) -> some View {
        #if canImport(GtkBackend)
            colorScheme(scheme)
        #else
            // AppKit and WinUI report the system scheme to SwiftCrossUI themselves.
            self
        #endif
    }

    /// Marks a control in the title area: clicks there go to it, not to moving the window. Only
    /// Windows needs it, where the system moves the window (see WindowChromeWinUI.swift); AppKit
    /// knows its controls, and GTK finds them from their click gestures.
    @ViewBuilder
    func titleBarControl() -> some View {
        #if canImport(AppKitBackend) || canImport(GtkBackend)
            self
        #elseif canImport(WinUIBackend)
            inspect { WinUIChrome.shared.addTitleBarControl($0) }
        #else
            self
        #endif
    }
}
