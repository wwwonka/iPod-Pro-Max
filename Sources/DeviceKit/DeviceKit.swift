//
//  DeviceKit.swift
//  iPod Pro Max
//
//  Finds mounted iPods, tells when volumes come and go, identifies the USB device behind a volume
//  and ejects it. One implementation per OS (DeviceKit+macOS/Linux/Windows.swift), all event-driven:
//  nothing runs while no disk is plugged in or removed. See docs/Architecture/DeviceKit.md.
//

import Foundation
import iPodKit

/// A mounted volume that may be an iPod.
public struct MountedVolume: Sendable, Hashable {
    public let url: URL
    /// The label the OS shows, when it knows one.
    public let name: String?

    public init(url: URL, name: String?) {
        self.url = url
        self.name = name
    }
}

public enum DeviceScanner {
    /// iPods currently mounted, plus folders standing in for iPods (`simulatedFolders`).
    /// Touches the disk: call it off the main thread.
    public static func scan(simulatedFolders: [URL] = [], includeRealDevices: Bool = true) -> [IPodDevice] {
        var found: [IPodDevice] = []
        if includeRealDevices {
            for volume in Platform.candidateVolumes() {
                if let device = IPodDevice.detect(volume: volume.url, volumeName: volume.name, usbLookup: USBIdentification.identify(volume:)) {
                    found.append(device)
                }
            }
        }
        for folder in simulatedFolders {
            if let device = IPodDevice.detect(volume: folder, simulated: true) { found.append(device) }
        }
        return found
    }

    /// The iPod at `path` (a mount point or a simulated iPod folder), if there is one.
    public static func device(at path: URL) -> IPodDevice? {
        // Compared as normalized paths, not URLs: "E:", "e:\" and "/Volumes/IPOD" (no trailing slash,
        // or through a symlink) must still find the mounted iPod, not fall back to a simulated one.
        let wanted = comparablePath(path)
        if let volume = Platform.candidateVolumes().first(where: { comparablePath($0.url) == wanted }) {
            return IPodDevice.detect(volume: volume.url, volumeName: volume.name, usbLookup: USBIdentification.identify(volume:))
        }
        return IPodDevice.detect(volume: path, simulated: true)
    }

    private static func comparablePath(_ url: URL) -> String {
        var path = FileOps.nativePath(url.resolvingSymlinksInPath().standardizedFileURL)
        #if os(Windows)
        path = path.replacingOccurrences(of: "/", with: "\\").uppercased()
        while path.hasSuffix("\\") { path.removeLast() }
        #else
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        #endif
        return path
    }

    /// Mounted removable volumes, iPods or not (what `scan` looks at).
    public static func candidateVolumes() -> [MountedVolume] { Platform.candidateVolumes() }
}

public enum USBIdentification {
    /// Walks from the mounted volume to the USB device that hosts it (vendor, product, serial number).
    public static func identify(volume: URL) -> USBDeviceIdentity? { Platform.usbIdentity(volume: volume) }
}

/// Calls `onChange` (on a background queue) when a volume is mounted, unmounted or renamed.
/// Nothing is polled: it waits on the OS's own notifications until `stop()` or deinit.
public final class VolumeWatcher: @unchecked Sendable {
    private var backend: PlatformWatcher?

    public init(onChange: @escaping @Sendable () -> Void) {
        backend = PlatformWatcher(onChange: onChange)
    }

    public func stop() {
        backend?.stop()
        backend = nil
    }

    deinit { stop() }

    /// The same notifications as an async sequence.
    public static func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let watcher = VolumeWatcher { continuation.yield(()) }
            continuation.onTermination = { _ in watcher.stop() }
        }
    }
}

public enum Ejector {
    /// Unmounts the iPod and asks the OS to eject it, so it can be unplugged safely.
    public static func eject(_ device: IPodDevice) async throws {
        guard !device.isSimulated else { return }
        let url = device.mountPoint
        try await Task.detached(priority: .userInitiated) {
            try await Platform.eject(volume: url)
        }.value
    }
}

public enum DeviceKitError: LocalizedError {
    case ejectFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ejectFailed(let s): return s
        }
    }
}
