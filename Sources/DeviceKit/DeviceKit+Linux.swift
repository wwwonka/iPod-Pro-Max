//
//  DeviceKit+Linux.swift
//  iPod Pro Max
//
//  Linux: mounts from /proc/self/mountinfo; mount events by waiting in poll() on that same file (the
//  kernel wakes it on every mount table change, no polling loop); the USB device from sysfs; ejection
//  through udisks2 (udisksctl), the same path as the desktop's eject button.
//

#if os(Linux)
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Musl  // the static Linux SDK, for the command-line tool
#endif
import iPodKit

enum Platform {
    struct Mount {
        var majorMinor: String
        var mountPoint: String
        var fsType: String
        var source: String
    }

    /// File systems an iPod can be formatted with (FAT32 from Windows, HFS+ from a Mac).
    static let iPodFileSystems: Set<String> = ["vfat", "msdos", "fat", "hfsplus", "hfs", "exfat", "fuseblk"]

    static func mounts() -> [Mount] {
        guard let text = try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8) else { return [] }
        var result: [Mount] = []
        for line in text.split(separator: "\n") {
            // id parent major:minor root mountpoint options [optional…] - fstype source superoptions
            let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7, let dash = fields.firstIndex(of: "-"), dash + 2 < fields.count else { continue }
            result.append(Mount(majorMinor: fields[2], mountPoint: unescape(fields[4]), fsType: fields[dash + 1], source: unescape(fields[dash + 2])))
        }
        return result
    }

    /// mountinfo writes spaces and a few other characters as octal escapes (\040).
    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var bytes: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        while i < u.count {
            if u[i] == 0x5C, i + 3 < u.count, let v = UInt8(String(decoding: u[(i + 1)...(i + 3)], as: UTF8.self), radix: 8) {
                bytes.append(v)
                i += 4
            } else {
                bytes.append(u[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func candidateVolumes() -> [MountedVolume] {
        mounts()
            .filter { iPodFileSystems.contains($0.fsType) && $0.source.hasPrefix("/dev/") && $0.mountPoint != "/" }
            .map { MountedVolume(url: URL(fileURLWithPath: $0.mountPoint, isDirectory: true), name: ($0.mountPoint as NSString).lastPathComponent) }
    }

    private static func mount(for volume: URL) -> Mount? {
        let path = volume.standardizedFileURL.path
        return mounts().last { URL(fileURLWithPath: $0.mountPoint).standardizedFileURL.path == path }
    }

    /// /sys/dev/block/<major:minor> links to the partition inside the USB device's sysfs tree; the
    /// first ancestor with idVendor/idProduct is the USB device.
    static func usbIdentity(volume: URL) -> USBDeviceIdentity? {
        guard let m = mount(for: volume) else { return nil }
        var dir = URL(fileURLWithPath: "/sys/dev/block/\(m.majorMinor)").resolvingSymlinksInPath()
        for _ in 0..<16 {
            if let vendor = hex(dir.appendingPathComponent("idVendor")), let product = hex(dir.appendingPathComponent("idProduct")) {
                return USBDeviceIdentity(vendorID: vendor, productID: product,
                                         serialNumber: text(dir.appendingPathComponent("serial")),
                                         productName: text(dir.appendingPathComponent("product")))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || parent.path == "/sys" { break }
            dir = parent
        }
        return nil
    }

    private static func text(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hex(_ url: URL) -> Int? { text(url).flatMap { Int($0, radix: 16) } }

    /// udisksctl unmount, then power-off of the whole disk (spins the iPod's drive down and makes it
    /// show "OK to disconnect"). Falls back to umount + eject when udisks isn't there.
    static func eject(volume: URL) async throws {
        guard let m = mount(for: volume) else { throw DeviceKitError.ejectFailed("\(volume.lastPathComponent) is no longer mounted.") }
        let partition = m.source
        let disk = wholeDisk(of: partition)
        if let udisks = which("udisksctl") {
            try run(udisks, ["unmount", "-b", partition, "--no-user-interaction"])
            // Power-off can be refused by policy; the volume is already unmounted, so that is not fatal.
            _ = try? run(udisks, ["power-off", "-b", disk, "--no-user-interaction"])
            return
        }
        try run(which("umount") ?? "/usr/bin/umount", [m.mountPoint])
        if let eject = which("eject") { _ = try? run(eject, [disk]) }
    }

    /// /dev/sdb1 → /dev/sdb, through sysfs (works for sdX, mmcblkXpY, nvmeXnYpZ).
    static func wholeDisk(of partition: String) -> String {
        let name = (partition as NSString).lastPathComponent
        let link = URL(fileURLWithPath: "/sys/class/block/\(name)").resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: link.appendingPathComponent("partition").path) {
            return "/dev/" + link.deletingLastPathComponent().lastPathComponent
        }
        return partition
    }

    private static func which(_ tool: String) -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return dirs.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw DeviceKitError.ejectFailed("\((tool as NSString).lastPathComponent) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return message
    }
}

/// Waits in poll() on /proc/self/mountinfo, which the kernel flags (POLLPRI) on every mount table change.
final class PlatformWatcher: @unchecked Sendable {
    private let mountFD: Int32
    private var wakePipe: [Int32] = [-1, -1]
    private let thread: Thread?

    init(onChange: @escaping @Sendable () -> Void) {
        mountFD = open("/proc/self/mountinfo", O_RDONLY | O_CLOEXEC)
        _ = pipe(&wakePipe)
        let fd = mountFD
        let wake = wakePipe[0]
        guard fd >= 0, wake >= 0 else {
            // No thread will close these: do it here (stop() then has nothing to wake).
            if fd >= 0 { close(fd) }
            if wake >= 0 { close(wake) }
            if wakePipe[1] >= 0 { close(wakePipe[1]); wakePipe[1] = -1 }
            thread = nil
            return
        }
        thread = Thread {
            defer { close(fd); close(wake) }
            var fds = [pollfd(fd: fd, events: Int16(POLLPRI | POLLERR), revents: 0),
                       pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
            while true {
                fds[0].revents = 0; fds[1].revents = 0
                let n = poll(&fds, 2, -1)
                if n < 0 { if errno == EINTR { continue } else { return } }
                if fds[1].revents != 0 { return }
                if fds[0].revents != 0 {
                    // Reading the file to its end re-arms the notification.
                    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    lseek(fd, 0, SEEK_SET)
                    while read(fd, &buffer, buffer.count) > 0 {}
                    onChange()
                }
            }
        }
        thread?.qualityOfService = .utility
        thread?.name = "ipodpromax.volumes"
        // Read once so the first poll only reports real changes.
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while read(fd, &buffer, buffer.count) > 0 {}
        thread?.start()
    }

    func stop() {
        guard wakePipe[1] >= 0 else { return }
        var byte: UInt8 = 1
        _ = write(wakePipe[1], &byte, 1)
        close(wakePipe[1])
        wakePipe[1] = -1
    }

    // The thread closes the descriptors it polls when the wake byte makes it return.
    deinit { stop() }
}
#endif
