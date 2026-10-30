//
//  DeviceKit+Windows.swift
//  iPod Pro Max
//
//  Windows: drive letters and labels from Win32; the USB device by walking the Plug and Play tree from
//  the volume's disk (the iPod's USB instance id, USB\VID_05AC&PID_1261\<serial>, holds the serial
//  number); volume arrivals through CM_Register_Notification (no hidden window, no polling); "safely
//  remove" through CM_Request_Device_Eject. The cfgmgr32 calls live in CWinDevices (C).
//

#if os(Windows)
import Foundation
import WinSDK
import CWinDevices
import iPodKit

private func wide(_ s: String) -> [WCHAR] { Array(s.utf16) + [0] }
private func string(_ buffer: [UInt16]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
}

enum Platform {
    static func candidateVolumes() -> [MountedVolume] {
        // An empty card reader or optical drive would otherwise show a "No disk" dialog.
        let previousMode = SetErrorMode(UINT(SEM_FAILCRITICALERRORS))
        defer { SetErrorMode(previousMode) }
        let mask = GetLogicalDrives()
        let system = ProcessInfo.processInfo.environment["SystemDrive"]?.uppercased().first
        var result: [MountedVolume] = []
        for i in 0..<26 where mask & (DWORD(1) << DWORD(i)) != 0 {
            let letter = Character(Unicode.Scalar(UInt8(65 + i)))
            if letter == system { continue }
            let root = "\(letter):\\"
            let type = GetDriveTypeW(wide(root))
            // iPods show up as removable (or, on some models, fixed) disks; never network, optical or RAM drives.
            guard type == UINT(DRIVE_REMOVABLE) || type == UINT(DRIVE_FIXED) else { continue }
            var label = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
            let name = GetVolumeInformationW(wide(root), &label, DWORD(label.count), nil, nil, nil, nil, 0) ? string(label) : ""
            result.append(MountedVolume(url: URL(fileURLWithPath: root, isDirectory: true), name: name.isEmpty ? "\(letter):" : name))
        }
        return result
    }

    private static func driveLetter(_ volume: URL) -> UInt16? {
        let path = FileOps.nativePath(volume)
        guard let first = path.unicodeScalars.first, first.properties.isAlphabetic, path.dropFirst().hasPrefix(":") else { return nil }
        return UInt16(first.value)
    }

    static func usbIdentity(volume: URL) -> USBDeviceIdentity? {
        guard let drive = driveLetter(volume) else { return nil }
        var vendor: UInt32 = 0, product: UInt32 = 0
        var serial = [UInt16](repeating: 0, count: 256)
        guard ipm_usb_identity(drive, &vendor, &product, &serial, serial.count) == 1 else { return nil }
        let s = string(serial)
        return USBDeviceIdentity(vendorID: Int(vendor), productID: Int(product), serialNumber: s.isEmpty ? nil : s, productName: nil)
    }

    /// "Safely remove": Windows flushes and dismounts the volume first, and refuses (veto) while a
    /// program still has a file open on the iPod.
    static func eject(volume: URL) async throws {
        guard let drive = driveLetter(volume) else {
            throw DeviceKitError.ejectFailed("\(FileOps.nativePath(volume)) is not a drive.")
        }
        var veto = [UInt16](repeating: 0, count: Int(MAX_PATH))
        guard ipm_eject(drive, &veto, veto.count) == 1 else {
            let who = string(veto)
            throw DeviceKitError.ejectFailed("Windows refused to eject the iPod\(who.isEmpty ? "" : " (\(who))"): close any program using it and try again.")
        }
    }
}

/// Plug and Play calls back on a thread pool thread when a volume interface arrives or leaves. Drive
/// letters are assigned right after, so the change is reported once things settle (about a second).
final class PlatformWatcher: @unchecked Sendable {
    private var handle: UnsafeMutableRawPointer?
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var generation = 0

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        handle = ipm_watch_start({ context in
            guard let context else { return }
            Unmanaged<PlatformWatcher>.fromOpaque(context).takeUnretainedValue().changed()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func changed() {
        lock.lock()
        generation += 1
        let mine = generation
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.generation
            self.lock.unlock()
            if current == mine { self.onChange() }
        }
    }

    func stop() {
        if let handle { ipm_watch_stop(handle) }
        handle = nil
    }
}
#endif
