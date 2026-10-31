//
//  DeviceDataFolder.swift
//  iPod Pro Max
//
//  The `iPod Pro Max/Persistent Data/` folder on the iPod, where what belongs to the iPod travels with
//  it (Docs/Données/Sur l'iPod.md): the app's settings shared by every OS, the CLI's sync record.
//  Small JSON files, written safely: FAT32 has no journal, so each file is written aside, flushed and
//  renamed, and the previous generation is kept as `.bak`.
//

import Foundation

/// Dates use the default (exact) encoding: an ISO 8601 string drops the fractions of a second that
/// change detection compares.
public struct DeviceDataFolder: Sendable {
    public static let folderName = "Persistent Data"
    public let url: URL
    /// `iPod Pro Max/Data/`, the folder's name until 2026-10-31: still read, never written.
    let legacyURL: URL?

    public init(mountPoint: URL) {
        let app = mountPoint.appendingPathComponent("iPod Pro Max", isDirectory: true)
        url = app.appendingPathComponent(Self.folderName, isDirectory: true)
        legacyURL = app.appendingPathComponent("Data", isDirectory: true)
    }

    /// Any folder of small JSON files written the same safe way.
    public init(url: URL) {
        self.url = url
        legacyURL = nil
    }

    /// Decodes `name`, falling back to `name.bak` when the current file is unreadable, then to the
    /// legacy `Data/` folder.
    public func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let decoder = JSONDecoder()
        for folder in [url] + (legacyURL.map { [$0] } ?? []) {
            for candidate in [name, name + ".bak"] {
                if let data = try? Data(contentsOf: folder.appendingPathComponent(candidate)),
                   let value = try? decoder.decode(T.self, from: data) {
                    return value
                }
            }
        }
        return nil
    }

    /// Identity/ownership registries must never be silently replaced after both copies are damaged.
    public func readChecked<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
        if let value = read(type, from: name) { return value }
        for folder in [url] + (legacyURL.map { [$0] } ?? []) {
            for candidate in [name, name + ".bak"] where FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
                throw IPodDBError.corrupt("Could not read \(name) or its backup.")
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
