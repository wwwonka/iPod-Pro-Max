import DeviceKit
import Foundation

/// Names of the mounted iPods, from DeviceKit (the same detection as the CLI). Touches the disk:
/// call it off the main thread.
func connectedIPods() -> [String] {
    DeviceScanner.scan().map(\.displayName).sorted()
}

/// Calls `update` with the mounted iPods now, then each time a volume is mounted, unmounted or
/// renamed. Waits on the OS's notifications (DeviceKit's `VolumeWatcher`): nothing runs in between.
func watchIPods(_ update: @MainActor ([String]) -> Void) async {
    await update(Task.detached(priority: .utility) { connectedIPods() }.value)
    for await _ in VolumeWatcher.changes() {
        await update(Task.detached(priority: .utility) { connectedIPods() }.value)
    }
}
