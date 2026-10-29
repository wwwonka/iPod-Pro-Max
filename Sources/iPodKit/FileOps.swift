//
//  FileOps.swift
//  iPod Pro Max
//
//  File operations whose behavior differs between macOS, Linux and Windows: replacing a file in one
//  step (FAT32 has no journal, so the iTunesDB is written aside, flushed, then renamed over the old
//  one) and reading a volume's capacity.
//

import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum FileOps {
    /// Writes `data` next to `destination`, flushes it to the disk, then renames it over `destination`.
    public static func writeReplacing(_ data: Data, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".ipodpromax.tmp")
        if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw IPodDBError.io("Couldn't create \(tmp.lastPathComponent)")
        }
        let handle = try FileHandle(forWritingTo: tmp)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try replaceItem(at: destination, withItemAt: tmp)
    }

    /// Moves `source` over `destination`, replacing it when it exists.
    public static func replaceItem(at destination: URL, withItemAt source: URL) throws {
        #if os(Windows)
        let ok = nativePath(source).withCString(encodedAs: UTF16.self) { src in
            nativePath(destination).withCString(encodedAs: UTF16.self) { dst in
                MoveFileExW(src, dst, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            }
        }
        if !ok {
            throw IPodDBError.io("Couldn't replace \(destination.lastPathComponent) (error \(GetLastError()))")
        }
        #else
        let result = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in rename(src!, dst!) }
        }
        if result != 0 {
            throw IPodDBError.io("Couldn't replace \(destination.lastPathComponent) (errno \(errno))")
        }
        #endif
    }

    /// The path as the OS spells it (`E:\iPod_Control` on Windows, where `URL.path` uses slashes).
    public static func nativePath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    }

    /// Total and free bytes of the volume holding `url` (0, 0 when unknown).
    public static func volumeCapacity(of url: URL) -> (total: Int64, free: Int64) {
        #if os(macOS)
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        if let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacity {
            return (Int64(total), Int64(free))
        }
        #endif
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path) else { return (0, 0) }
        let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? (attrs[.systemSize] as? Int64) ?? 0
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? (attrs[.systemFreeSize] as? Int64) ?? 0
        return (total, free)
    }
}
