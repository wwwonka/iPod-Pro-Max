import DeviceKit
import Foundation
import iPodKit

/// The mounted iPods, from DeviceKit (the same detection as the CLI). Touches the disk: call it
/// off the main thread.
func connectedIPods() -> [IPodDevice] {
    DeviceScanner.scan().sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
}

/// Calls `update` with the mounted iPods now, then each time a volume is mounted, unmounted or
/// renamed. Waits on the OS's notifications (DeviceKit's `VolumeWatcher`): nothing runs in between.
func watchIPods(_ update: @MainActor ([IPodDevice]) -> Void) async {
    await update(Task.detached(priority: .utility) { connectedIPods() }.value)
    for await _ in VolumeWatcher.changes() {
        await update(Task.detached(priority: .utility) { connectedIPods() }.value)
    }
}

/// The eject button's glyph color on GTK and WinUI, as in the Finder's sidebar: dim at rest,
/// brighter under the pointer, white (near black in light mode) while pressed. The dark values are
/// the Finder's, measured on screen; macOS itself uses the system label colors they come from.
enum EjectButtonState {
    case normal, hover, pressed
}

/// What's behind the button: nothing, the gray selection (sidebar not focused), or the accent one.
enum EjectButtonBackground {
    case plain, selected, accent
}

func ejectButtonRGB(_ state: EjectButtonState, dark: Bool, on background: EjectButtonBackground = .plain) -> (r: UInt8, g: UInt8, b: UInt8) {
    switch (background, state, dark) {
    case (.accent, .normal, _): return (0xE6, 0xE6, 0xE6)
    case (.accent, _, _): return (0xFF, 0xFF, 0xFF)
    // The gray selection is as dark as the button at rest: lighter, so it still shows.
    case (.selected, .normal, true): return (0x8E, 0x8E, 0x93)
    case (.selected, .hover, true): return (0xC7, 0xC7, 0xCC)
    case (.selected, .normal, false): return (0x8E, 0x8E, 0x93)
    case (.selected, .hover, false): return (0x5A, 0x5A, 0x5E)
    case (_, .normal, true): return (0x49, 0x49, 0x49)
    case (_, .hover, true): return (0x9F, 0xA4, 0xB9)
    case (_, .pressed, true): return (0xFF, 0xFF, 0xFF)
    case (_, .normal, false): return (0xAE, 0xAE, 0xAE)
    case (_, .hover, false): return (0x76, 0x76, 0x76)
    case (_, .pressed, false): return (0x23, 0x23, 0x23)
    }
}
