import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Portable safe JSON persistence (temp file -> fsync -> atomic rename -> `.bak` generation),
/// matching `iPodKit.DeviceDataFolder` without depending on `iPodKit`.
public enum SafeStorage {
    public static func writeReplacing(_ data: Data, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".ipodpromax.tmp")
        if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: tmp)
        do {
            if #available(macOS 10.15.4, *) {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } else {
                handle.write(data)
                handle.synchronizeFile()
                handle.closeFile()
            }
        } catch {
            try? handle.close()
            throw error
        }
        try replaceItem(at: destination, withItemAt: tmp)
    }

    public static func replaceItem(at destination: URL, withItemAt source: URL) throws {
        #if os(Windows)
        let srcPath = nativePath(source)
        let dstPath = nativePath(destination)
        let ok = srcPath.withCString(encodedAs: UTF16.self) { src in
            dstPath.withCString(encodedAs: UTF16.self) { dst in
                MoveFileExW(src, dst, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            }
        }
        if !ok {
            throw NSError(domain: "PluginKit.SafeStorage", code: Int(GetLastError()), userInfo: [
                NSLocalizedDescriptionKey: "Couldn't replace \(destination.lastPathComponent) (error \(GetLastError()))"
            ])
        }
        #else
        let result = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in rename(src!, dst!) }
        }
        if result != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Couldn't replace \(destination.lastPathComponent) (errno \(errno))"
            ])
        }
        #endif
    }

    public static func readWithBackup<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let decoder = JSONDecoder()
        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".bak")
        for candidate in [url, backup] {
            if let data = try? Data(contentsOf: candidate),
               let value = try? decoder.decode(type, from: data) {
                return value
            }
        }
        return nil
    }

    public static func writeWithBackup<T: Codable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".bak")
        let decoder = JSONDecoder()
        if fm.fileExists(atPath: url.path),
           let previous = try? Data(contentsOf: url),
           (try? decoder.decode(T.self, from: previous)) != nil {
            try writeReplacing(previous, to: backup)
        }
        try writeReplacing(data, to: url)
    }

    public static func nativePath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    }

    public static func availableBytes(at url: URL) -> Int64? {
        #if os(macOS)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let free = values.volumeAvailableCapacity {
            return Int64(free)
        }
        #endif
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? (attrs[.systemFreeSize] as? Int64) {
            return free
        }
        return nil
    }

    /// Resolves the OS Downloads folder (`~/Downloads/iPod Pro Max` or `xdg-user-dir DOWNLOAD`).
    public static func defaultDownloadsFolder() -> URL {
        #if os(Linux)
        if let xdg = linuxXDGDownloadsDir() {
            return xdg.appendingPathComponent("iPod Pro Max", isDirectory: true)
        }
        #endif
        if let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return dir.appendingPathComponent("iPod Pro Max", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Downloads/iPod Pro Max", isDirectory: true)
    }

    #if os(Linux)
    private static func linuxXDGDownloadsDir() -> URL? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-user-dir")
        proc.arguments = ["DOWNLOAD"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        } catch {
            return nil
        }
    }
    #endif

    /// Opens a URL in the user's default browser. Returns `false` if launching the browser failed.
    @discardableResult
    public static func openURL(_ url: URL) -> Bool {
        #if os(macOS)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [url.absoluteString]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
        #elseif os(Windows)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        proc.arguments = ["/c", "start", "", url.absoluteString]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            return true
        } catch {
            return false
        }
        #else
        let candidates = ["/usr/bin/xdg-open", "/bin/xdg-open"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = [url.absoluteString]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            return true
        } catch {
            return false
        }
        #endif
    }

    /// Removes macOS quarantine attribute and ad-hoc signs executables after extracting `.ippmplugin`.
    public static func prepareInstalledExecutables(in pluginDir: URL, manifest: PluginManifest) {
        #if os(macOS)
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", pluginDir.path]
        xattr.standardOutput = FileHandle.nullDevice
        xattr.standardError = FileHandle.nullDevice
        try? xattr.run()
        xattr.waitUntilExit()

        var targets: [URL] = []
        if let macExec = manifest.executable["macos"] {
            targets.append(pluginDir.appendingPathComponent(macExec))
        }
        let fm = FileManager.default
        for sub in ["bin", "vendor"] {
            let dir = pluginDir.appendingPathComponent(sub, isDirectory: true)
            if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    if fm.isExecutableFile(atPath: fileURL.path) {
                        targets.append(fileURL)
                    }
                }
            }
        }
        var seen = Set<String>()
        for target in targets where fm.fileExists(atPath: target.path) && seen.insert(target.path).inserted {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            let cs = Process()
            cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            cs.arguments = ["--force", "--sign", "-", target.path]
            cs.standardOutput = FileHandle.nullDevice
            cs.standardError = FileHandle.nullDevice
            try? cs.run()
            cs.waitUntilExit()
        }
        #endif
    }
}
