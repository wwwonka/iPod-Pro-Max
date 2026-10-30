//
//  IPodDevice.swift
//  iPod Pro Max
//
//  A mounted iPod (or a folder standing in for one). Reads SysInfo / SysInfoExtended to identify
//  the model and exposes the well-known paths inside iPod_Control.
//

import Foundation

public struct IPodDevice: Identifiable, Hashable, Sendable {
    /// Stable identifier: serial number, FireWire GUID, or the mount path.
    public let id: String
    public let mountPoint: URL
    public let volumeName: String
    public let modelInfo: IPodModelInfo?
    public let generation: IPodGeneration
    public let sysInfo: [String: String]
    public let firewireGUID: String?
    public let serialNumber: String?
    /// DBVersion from SysInfoExtended (drives the checksum requirement on newer models).
    public let extendedDBVersion: Int?
    public let artworkFormatsFromDevice: [ArtworkFormat]?
    public let isSimulated: Bool
    /// Name stored in the iPod's database (what the iPod shows about itself), if readable.
    public let databaseName: String?

    public var displayName: String {
        if let n = databaseName, !n.isEmpty { return n }
        return volumeName
    }

    public static func == (lhs: IPodDevice, rhs: IPodDevice) -> Bool { lhs.id == rhs.id && lhs.mountPoint == rhs.mountPoint }
    public func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(mountPoint) }

    // MARK: Paths

    public var controlDir: URL { mountPoint.appendingPathComponent("iPod_Control", isDirectory: true) }
    public var iTunesDir: URL { controlDir.appendingPathComponent("iTunes", isDirectory: true) }
    public var musicDir: URL { controlDir.appendingPathComponent("Music", isDirectory: true) }
    public var artworkDir: URL { controlDir.appendingPathComponent("Artwork", isDirectory: true) }
    public var deviceDir: URL { controlDir.appendingPathComponent("Device", isDirectory: true) }
    public var iTunesDBURL: URL { iTunesDir.appendingPathComponent("iTunesDB") }
    public var playCountsURL: URL { iTunesDir.appendingPathComponent("Play Counts") }
    public var artworkDBURL: URL { artworkDir.appendingPathComponent("ArtworkDB") }

    // MARK: Capabilities

    public var checksumType: IPodChecksumType {
        // DBVersion in SysInfoExtended is the iTunesDB format version (e.g. 0x30 on a real 2009
        // classic), not a hash-scheme id — only early iPods report it in the 0-2 range here. For
        // every other value, trust the model table's hash requirement instead of guessing .unknown.
        if let v = extendedDBVersion, v <= 2 { return .none }
        return generation.checksum
    }

    public var supportLevel: IPodSupportLevel {
        switch checksumType {
        case .none: return generation == .unknown ? .experimental : .full
        case .hash58:
            guard firewireGUID != nil else { return .unsupported }
            // Confirmed working on real classic3 (160 GB, 2009) hardware: hash58 signing, playlists,
            // artwork, podcasts/audiobooks, sort fields. Earlier classics share the mechanism but
            // weren't the hardware actually tested, so stay experimental out of caution; nano 3G/4G too.
            switch generation {
            case .classic3: return .full
            default: return .experimental
            }
        default: return .unsupported
        }
    }

    public var coverArtFormats: [ArtworkFormat] {
        let fromTable = generation.coverArtFormats
        if !fromTable.isEmpty { return fromTable }
        return artworkFormatsFromDevice ?? []
    }

    public var supportsArtwork: Bool { !coverArtFormats.isEmpty }
    public var supportsPodcasts: Bool { generation.supportsPodcasts }

    public var displayModelName: String {
        if let m = modelInfo { return m.marketingName }
        if generation != .unknown { return generation.displayName }
        return "iPod"
    }

    public var capacityLabel: String? { modelInfo?.capacityDescription }

    public var firewireIDBytes: [UInt8]? {
        guard let g = firewireGUID else { return nil }
        return Hash58.firewireBytes(from: g)
    }

    // MARK: Volume stats

    public struct VolumeStats: Sendable {
        public var total: Int64
        public var free: Int64
        public var used: Int64 { total - free }

        public init(total: Int64, free: Int64) {
            self.total = total
            self.free = free
        }
    }

    public func volumeStats() -> VolumeStats {
        let capacity = FileOps.volumeCapacity(of: mountPoint)
        let total = capacity.total
        var free = capacity.free
        #if os(macOS)
        if isSimulated, let important = (try? mountPoint.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage, important > 0 {
            free = important
        }
        #else
        free = max(free, 0)
        #endif
        return VolumeStats(total: total, free: free)
    }

    /// Existing F00…Fnn folders on the device (created on demand by the sync engine).
    public func musicFolderCount() -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: musicDir.path) else { return 0 }
        return items.filter { $0.count == 3 && $0.hasPrefix("F") && Int($0.dropFirst()) != nil }.count
    }

    /// Reads the on-device database, or an empty one named after the volume when none exists.
    public func readDatabase() throws -> ITunesDatabase {
        if let data = try? Data(contentsOf: iTunesDBURL), !data.isEmpty {
            return try ITunesDBReader(data: data).parse()
        }
        return ITunesDatabase.empty(named: volumeName)
    }

    // MARK: Detection

    /// Reads the iPod at `volume`. `usbLookup` finds the USB device behind the volume (DeviceKit does
    /// it per OS); `volumeName` is the label the OS shows, when it knows one.
    public static func detect(volume: URL, simulated: Bool = false, volumeName knownName: String? = nil,
                       usbLookup: (URL) -> USBDeviceIdentity? = { _ in nil }) -> IPodDevice? {
        let fm = FileManager.default
        let control = volume.appendingPathComponent("iPod_Control", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: control.path, isDirectory: &isDir), isDir.boolValue else { return nil }

        let sysInfo = parseSysInfo(at: control.appendingPathComponent("Device/SysInfo"))
        let extended = parseSysInfoExtended(at: control.appendingPathComponent("Device/SysInfoExtended"))

        var modelNumber = extended?["ModelNumStr"] as? String ?? sysInfo["ModelNumStr"]
        if modelNumber == nil, let pt = extended?["ProductType"] as? String { modelNumber = pt }
        var info = modelNumber.flatMap { IPodModelTable.info(forModelNumber: $0) }
        let sysInfoFirewire = (extended?["FireWireGUID"] as? String) ?? sysInfo["FirewireGuid"] ?? sysInfo["FireWireGUID"]
        var firewire = sysInfoFirewire
        var serial = (extended?["SerialNumber"] as? String) ?? sysInfo["pszSerialNumber"] ?? sysInfo["SerialNumber"]
        if let s = serial, s.isEmpty { serial = nil }

        // Fall back to the USB product id when SysInfo can't tell us the model, and to the USB serial
        // number for the FireWire GUID: on the classic and nano 3G/4G they are the same 16 hex digits,
        // and hash58 can't sign the database without it.
        var usbGeneration: IPodGeneration? = nil
        if !simulated, info == nil || firewire == nil, let usb = usbLookup(volume), usb.isApple {
            if info == nil {
                usbGeneration = usb.generation
                if serial == nil, let s = usb.serialNumber, !s.isEmpty { serial = s }
                if let gen = usbGeneration {
                    let gb = Self.marketingCapacity(bytes: FileOps.volumeCapacity(of: volume).total)
                    info = IPodModelInfo(modelNumber: String(format: "USB %04X", usb.productID), capacityGB: gb, generation: gen, color: nil)
                }
            }
            if firewire == nil, let guid = usb.firewireGUIDFromSerial { firewire = guid }
        }
        let dbVersion = Self.intValue(extended?["DBVersion"])

        var deviceFormats: [ArtworkFormat]? = nil
        if let art = extended?["AlbumArt"] as? [[String: Any]] {
            let fmts = art.compactMap { d -> ArtworkFormat? in
                guard let id = Self.intValue(d["FormatId"]),
                      let w = Self.intValue(d["RenderWidth"]),
                      let h = Self.intValue(d["RenderHeight"]) else { return nil }
                let pixel = (d["PixelFormat"] as? String) ?? "4C353635"
                guard pixel == "4C353635" else { return nil } // only RGB565 LE is supported
                return ArtworkFormat(id: id, width: w, height: h)
            }
            if !fmts.isEmpty { deviceFormats = fmts }
        }

        let volumeName = simulated ? volume.lastPathComponent
            : (knownName ?? (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? volume.lastPathComponent)
        // The id keys the library's per-device sync record: the GUID borrowed from the USB serial
        // number above must not change it, or an iPod already synced would look brand new.
        var identifier = serial ?? sysInfoFirewire ?? ""
        if identifier.isEmpty {
            identifier = (try? volume.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? volume.path
        }
        if simulated { identifier = "folder:" + volume.path }

        var databaseName: String? = nil
        let dbURL = control.appendingPathComponent("iTunes/iTunesDB")
        if let handle = try? FileHandle(forReadingFrom: dbURL) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 32 * 1024 * 1024), !data.isEmpty,
               let db = try? ITunesDBReader(data: data).parse() {
                databaseName = db.masterPlaylist?.name
            }
        }

        return IPodDevice(id: identifier,
                          mountPoint: volume,
                          volumeName: volumeName,
                          modelInfo: info,
                          generation: info?.generation ?? usbGeneration ?? .unknown,
                          sysInfo: sysInfo,
                          firewireGUID: firewire,
                          serialNumber: serial,
                          extendedDBVersion: dbVersion,
                          artworkFormatsFromDevice: deviceFormats,
                          isSimulated: simulated,
                          databaseName: databaseName)
    }

    /// Plist numbers arrive as NSNumber on macOS and as Swift integers elsewhere.
    public static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let n as Int: return n
        case let n as Int64: return Int(n)
        case let n as UInt64: return Int(n)
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    /// Rounds a raw volume size to the capacity printed on the box (30 GB, 60 GB, 4 GB …).
    public static func marketingCapacity(bytes: Int64) -> Double {
        guard bytes > 0 else { return 0 }
        let gb = Double(bytes) / 1_000_000_000
        let steps: [Double] = [0.5, 1, 2, 4, 5, 6, 8, 10, 15, 16, 20, 30, 32, 40, 60, 64, 80, 120, 128, 160, 256]
        return steps.first { $0 >= gb * 0.98 } ?? gb.rounded()
    }

    public static func parseSysInfo(at url: URL) -> [String: String] {
        // SysInfo is a small text file; read at most 64 KB so an odd file can't stall the scan.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { return [:] }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [:] }
        var dict: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { dict[key] = value }
        }
        return dict
    }

    public static func parseSysInfoExtended(at url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    /// Creates the folder skeleton of an iPod inside `folder` (used for the simulated device in Settings).
    public static func createSimulatedIPod(at folder: URL, modelNumber: String = "xA002", name: String = "Test iPod") throws {
        let fm = FileManager.default
        let control = folder.appendingPathComponent("iPod_Control", isDirectory: true)
        try fm.createDirectory(at: control.appendingPathComponent("Device"), withIntermediateDirectories: true)
        try fm.createDirectory(at: control.appendingPathComponent("iTunes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: control.appendingPathComponent("Artwork"), withIntermediateDirectories: true)
        let music = control.appendingPathComponent("Music")
        try fm.createDirectory(at: music, withIntermediateDirectories: true)
        for i in 0..<50 {
            try fm.createDirectory(at: music.appendingPathComponent(String(format: "F%02d", i)), withIntermediateDirectories: true)
        }
        let sysinfo = """
        BoardHwName: iPod Q45
        pszSerialNumber: TEST0000000
        ModelNumStr: \(modelNumber)
        visibleBuildID: 0x01300000 (1.3)
        buildID: 0x01300000 (1.3)
        """
        try sysinfo.write(to: control.appendingPathComponent("Device/SysInfo"), atomically: true, encoding: .utf8)
        if !fm.fileExists(atPath: control.appendingPathComponent("iTunes/iTunesDB").path) {
            let db = ITunesDatabase.empty(named: name)
            let out = try ITunesDBWriter(database: db).write()
            try out.data.write(to: control.appendingPathComponent("iTunes/iTunesDB"))
        }
    }

    public init(id: String, mountPoint: URL, volumeName: String, modelInfo: IPodModelInfo?, generation: IPodGeneration, sysInfo: [String: String], firewireGUID: String?, serialNumber: String?, extendedDBVersion: Int?, artworkFormatsFromDevice: [ArtworkFormat]?, isSimulated: Bool, databaseName: String?) {
        self.id = id
        self.mountPoint = mountPoint
        self.volumeName = volumeName
        self.modelInfo = modelInfo
        self.generation = generation
        self.sysInfo = sysInfo
        self.firewireGUID = firewireGUID
        self.serialNumber = serialNumber
        self.extendedDBVersion = extendedDBVersion
        self.artworkFormatsFromDevice = artworkFormatsFromDevice
        self.isSimulated = isSimulated
        self.databaseName = databaseName
    }
}
