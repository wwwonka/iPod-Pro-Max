//
//  DeviceKit+macOS.swift
//  iPod Pro Max
//
//  macOS: mounted volumes from FileManager, the USB device from the IORegistry (useful when SysInfo is
//  missing or empty, common on iPods restored by recent Finder or iTunes), mount events and ejection
//  through DiskArbitration. No AppKit, so the command-line tool can use it too.
//

#if os(macOS)
import Foundation
import DiskArbitration
import IOKit
import iPodKit

enum Platform {
    static func candidateVolumes() -> [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var result: [MountedVolume] = []
        for v in volumes {
            guard let values = try? v.resourceValues(forKeys: Set(keys)) else { continue }
            // iPods are local, ejectable USB/FireWire disks. Skip network shares, the boot disk and internal drives.
            if values.volumeIsLocal == false { continue }
            if values.volumeIsRootFileSystem == true { continue }
            let ejectable = (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false)
            if !ejectable && (values.volumeIsInternal ?? true) { continue }
            result.append(MountedVolume(url: v, name: values.volumeName))
        }
        return result
    }

    /// Walks from the mounted volume up the IORegistry to the USB device that hosts it.
    static func usbIdentity(volume: URL) -> USBDeviceIdentity? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL) else { return nil }
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }

        var entry: io_registry_entry_t = media
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        var candidate: USBDeviceIdentity?
        for _ in 0..<24 {
            if let vendor = property(entry, "idVendor") as? Int, let product = property(entry, "idProduct") as? Int {
                let serial = property(entry, "USB Serial Number") as? String ?? property(entry, "kUSBSerialNumberString") as? String
                let name = property(entry, "USB Product Name") as? String ?? property(entry, "kUSBProductString") as? String
                let identity = USBDeviceIdentity(vendorID: vendor, productID: product, serialNumber: serial, productName: name)
                // A storage/interface node can repeat the USB IDs without the serial. Keep
                // walking to IOUSBHostDevice, which carries the FireWire GUID used by hash58.
                if let serial, !serial.isEmpty { return identity }
                candidate = identity
            }
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS, parent != IO_OBJECT_NULL else { return candidate }
            IOObjectRelease(entry)
            entry = parent
        }
        return candidate
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return value.takeRetainedValue()
    }

    /// Unmounts every volume of the disk, then ejects it, as Finder's eject button does.
    static func eject(volume: URL) async throws {
        let queue = DispatchQueue(label: "ipodpromax.eject")
        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw DeviceKitError.ejectFailed("DiskArbitration is unavailable.") }
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL) else {
            throw DeviceKitError.ejectFailed("\(volume.lastPathComponent) is no longer mounted.")
        }
        let whole = DADiskCopyWholeDisk(disk) ?? disk
        try await DACall.run { context in
            DADiskUnmount(whole, DADiskUnmountOptions(kDADiskUnmountOptionWhole), { _, dissenter, ctx in DACall.finish(ctx, dissenter) }, context)
        }
        try await DACall.run { context in
            DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, ctx in DACall.finish(ctx, dissenter) }, context)
        }
    }
}

/// Bridges a DiskArbitration completion callback to async/await.
private final class DACall {
    let continuation: CheckedContinuation<Void, Error>
    init(_ c: CheckedContinuation<Void, Error>) { continuation = c }

    static func run(_ start: (UnsafeMutableRawPointer) -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            start(Unmanaged.passRetained(DACall(c)).toOpaque())
        }
    }

    static func finish(_ context: UnsafeMutableRawPointer?, _ dissenter: DADissenter?) {
        guard let context else { return }
        let call = Unmanaged<DACall>.fromOpaque(context).takeRetainedValue()
        if let dissenter {
            let reason = DADissenterGetStatusString(dissenter) as String? ?? "the disk is in use"
            call.continuation.resume(throwing: DeviceKitError.ejectFailed("Couldn't eject the iPod: \(reason)."))
        } else {
            call.continuation.resume()
        }
    }
}

/// DiskArbitration tells when a volume path appears, changes or goes away.
final class PlatformWatcher: @unchecked Sendable {
    private let session: DASession?
    private let queue = DispatchQueue(label: "ipodpromax.volumes", qos: .utility)
    private let onChange: @Sendable () -> Void
    private var context: Unmanaged<PlatformWatcher>?

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        queue.setSpecific(key: Self.queueKey, value: true)
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else { return }
        let ctx = Unmanaged.passUnretained(self)
        context = ctx
        let watch = [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeNameKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, watch, { _, _, ctx in
            guard let ctx else { return }
            Unmanaged<PlatformWatcher>.fromOpaque(ctx).takeUnretainedValue().onChange()
        }, ctx.toOpaque())
        DARegisterDiskDisappearedCallback(session, nil, { _, ctx in
            guard let ctx else { return }
            Unmanaged<PlatformWatcher>.fromOpaque(ctx).takeUnretainedValue().onChange()
        }, ctx.toOpaque())
        DASessionSetDispatchQueue(session, queue)
    }

    func stop() {
        guard let session, context != nil else { return }
        context = nil
        // Unscheduling stops new callbacks, but one may already be queued: drain the queue so none
        // runs (with this object's unretained pointer) after stop() returns and the watcher is freed.
        DASessionSetDispatchQueue(session, nil)
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil { queue.sync {} }
    }

    private static let queueKey = DispatchSpecificKey<Bool>()
}
#endif
