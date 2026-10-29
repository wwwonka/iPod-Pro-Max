//
//  DeviceDataFolder.swift
//  iPod Pro Max
//
//  The `iPod Pro Max/Data/` folder on the iPod, where what belongs to the iPod travels with it
//  (docs/Données/Sur l'iPod.md). Small JSON files, written safely: FAT32 has no journal, so each file
//  is written aside, flushed and renamed, and the previous generation is kept as `.bak`.
//

import Foundation

/// Dates use the default (exact) encoding: an ISO 8601 string drops the fractions of a second that
/// change detection compares.
public struct DeviceDataFolder: Sendable {
    public let url: URL

    public init(mountPoint: URL) {
        url = mountPoint.appendingPathComponent("iPod Pro Max", isDirectory: true).appendingPathComponent("Data", isDirectory: true)
    }

    /// Decodes `name`, falling back to `name.bak` when the current file is unreadable.
    public func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let decoder = JSONDecoder()
        for candidate in [name, name + ".bak"] {
            if let data = try? Data(contentsOf: url.appendingPathComponent(candidate)),
               let value = try? decoder.decode(T.self, from: data) {
                return value
            }
        }
        return nil
    }

    public func write<T: Encodable>(_ value: T, to name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent(name)
        let backup = url.appendingPathComponent(name + ".bak")
        if fm.fileExists(atPath: file.path) {
            if fm.fileExists(atPath: backup.path) { try? fm.removeItem(at: backup) }
            try? fm.copyItem(at: file, to: backup)
        }
        try FileOps.writeReplacing(data, to: file)
    }
}
