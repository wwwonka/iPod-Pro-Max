import Foundation

/// Pure-Swift, Foundation-only ZIP archive reader and writer (Store + RFC 1951 DEFLATE inflate/deflate).
/// No external libraries (`Compression`, `zlib`, `unzip` binary) so `.ippmplugin` packages work
/// identically on macOS, Linux (including static musl), and Windows.
public enum ZipArchiveError: LocalizedError, Equatable {
    case invalidArchive(String)
    case unsafePath(String)
    case unsupportedCompression(UInt16)
    case corruptedData(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArchive(let msg): "Invalid ZIP archive: \(msg)"
        case .unsafePath(let path): "Unsafe archive path: \(path)"
        case .unsupportedCompression(let method): "Unsupported ZIP compression method: \(method)"
        case .corruptedData(let msg): "Corrupted ZIP data: \(msg)"
        }
    }
}

public struct ZipEntry: Sendable, Equatable {
    public var path: String
    public var data: Data
    public var unixPermissions: UInt16

    public init(path: String, data: Data, unixPermissions: UInt16 = 0o644) {
        self.path = path
        self.data = data
        self.unixPermissions = unixPermissions
    }
}

public enum ZipArchive {
    // MARK: - Reading

    public static func read(from url: URL) throws -> [ZipEntry] {
        let data = try Data(contentsOf: url)
        return try read(data: data)
    }

    /// Reads only the named entries, mapping the file instead of loading it: a 60 MB game
    /// archive costs the pages of its central directory and of those entries.
    public static func read(from url: URL, only names: Set<String>) throws -> [ZipEntry] {
        try read(from: url) { names.contains($0) }
    }

    /// Same, for the entries whose raw name passes `include`.
    public static func read(from url: URL, where include: (String) -> Bool) throws -> [ZipEntry] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try withoutActuallyEscaping(include) { try read(data: data, where: $0) }
    }

    public static func read(data: Data, where include: ((String) -> Bool)? = nil) throws -> [ZipEntry] {
        guard data.count >= 22 else {
            throw ZipArchiveError.invalidArchive("file too small")
        }
        // Locate End of Central Directory (0x06054b50) scanning backwards from end (max comment 65535 bytes).
        let minOffset = max(0, data.count - 22 - 65535)
        var eocdOffset: Int?
        var pos = data.count - 22
        while pos >= minOffset {
            if readUInt32LE(data, pos) == 0x06054B50 {
                let commentLen = Int(readUInt16LE(data, pos + 20))
                if pos + 22 + commentLen == data.count {
                    eocdOffset = pos
                    break
                }
            }
            pos -= 1
        }
        guard let eocd = eocdOffset else {
            throw ZipArchiveError.invalidArchive("missing end-of-central-directory record")
        }

        let entryCount = Int(readUInt16LE(data, eocd + 10))
        let cdSize = Int(readUInt32LE(data, eocd + 12))
        let cdOffset = Int(readUInt32LE(data, eocd + 16))
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= eocd else {
            throw ZipArchiveError.invalidArchive("central directory out of bounds")
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(entryCount)
        var cursor = cdOffset
        for _ in 0..<entryCount {
            guard cursor + 46 <= cdOffset + cdSize,
                  readUInt32LE(data, cursor) == 0x02014B50 else {
                throw ZipArchiveError.invalidArchive("invalid central directory header")
            }
            let versionMadeBy = readUInt16LE(data, cursor + 4)
            let method = readUInt16LE(data, cursor + 10)
            let expectedCRC = readUInt32LE(data, cursor + 16)
            let compressedSize = Int(readUInt32LE(data, cursor + 20))
            let uncompressedSize = Int(readUInt32LE(data, cursor + 24))
            let nameLen = Int(readUInt16LE(data, cursor + 28))
            let extraLen = Int(readUInt16LE(data, cursor + 30))
            let commentLen = Int(readUInt16LE(data, cursor + 32))
            let externalAttrs = readUInt32LE(data, cursor + 38)
            let localHeaderOffset = Int(readUInt32LE(data, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLen + extraLen + commentLen <= cdOffset + cdSize else {
                throw ZipArchiveError.invalidArchive("central directory entry truncated")
            }
            let nameData = data[nameStart..<(nameStart + nameLen)]
            guard let rawName = String(data: nameData, encoding: .utf8) else {
                throw ZipArchiveError.invalidArchive("non-UTF-8 entry name")
            }
            cursor = nameStart + nameLen + extraLen + commentLen

            // Skip directory entries (ending with '/')
            if rawName.hasSuffix("/") { continue }
            if let include, !include(rawName) { continue }

            let cleanPath = try sanitizeRelativePath(rawName)

            // Read local file header to find payload start
            guard localHeaderOffset >= 0, localHeaderOffset + 30 <= cdOffset,
                  readUInt32LE(data, localHeaderOffset) == 0x04034B50 else {
                throw ZipArchiveError.invalidArchive("invalid local file header for \(cleanPath)")
            }
            let localNameLen = Int(readUInt16LE(data, localHeaderOffset + 26))
            let localExtraLen = Int(readUInt16LE(data, localHeaderOffset + 28))
            let payloadStart = localHeaderOffset + 30 + localNameLen + localExtraLen
            guard payloadStart + compressedSize <= cdOffset else {
                throw ZipArchiveError.invalidArchive("compressed payload out of bounds for \(cleanPath)")
            }
            let compressedData = data[payloadStart..<(payloadStart + compressedSize)]

            // Reject symlinks (S_IFLNK = 0o120000) for security
            let creatorOS = versionMadeBy >> 8
            let unixMode = UInt16((externalAttrs >> 16) & 0xFFFF)
            if creatorOS == 3 && (unixMode & 0o170000) == 0o120000 {
                throw ZipArchiveError.unsafePath(cleanPath)
            }

            let uncompressed: Data
            switch method {
            case 0:
                uncompressed = Data(compressedData)
            case 8:
                uncompressed = try Deflate.inflate(Data(compressedData), expectedSize: uncompressedSize)
            default:
                throw ZipArchiveError.unsupportedCompression(method)
            }

            guard uncompressed.count == uncompressedSize else {
                throw ZipArchiveError.corruptedData("size mismatch for \(cleanPath)")
            }
            guard CRC32.checksum(uncompressed) == expectedCRC else {
                throw ZipArchiveError.corruptedData("CRC-32 mismatch for \(cleanPath)")
            }

            let perms: UInt16 = (creatorOS == 3 && (unixMode & 0o777) != 0) ? (unixMode & 0o777) : 0o644
            entries.append(ZipEntry(path: cleanPath, data: uncompressed, unixPermissions: perms))
        }

        return entries
    }

    // MARK: - Writing

    public static func write(entries: [ZipEntry], to url: URL) throws {
        let archiveData = try writeData(entries: entries)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archiveData.write(to: url, options: .atomic)
    }

    public static func writeData(entries: [ZipEntry]) throws -> Data {
        var output = Data()
        struct CentralRecord {
            var nameData: Data
            var crc: UInt32
            var method: UInt16
            var compressedSize: UInt32
            var uncompressedSize: UInt32
            var localHeaderOffset: UInt32
            var unixPermissions: UInt16
        }
        var records: [CentralRecord] = []
        records.reserveCapacity(entries.count)

        for entry in entries {
            let clean = try sanitizeRelativePath(entry.path)
            let nameData = Data(clean.utf8)
            let crc = CRC32.checksum(entry.data)
            let deflated = Deflate.deflateFixed(entry.data)
            let useDeflate = deflated.count < entry.data.count
            let method: UInt16 = useDeflate ? 8 : 0
            let payload = useDeflate ? deflated : entry.data

            let localOffset = UInt32(output.count)
            // Local file header (30 bytes)
            appendUInt32LE(&output, 0x04034B50)
            appendUInt16LE(&output, 20) // version needed: 2.0
            appendUInt16LE(&output, 0x0800) // UTF-8 filename flag
            appendUInt16LE(&output, method)
            appendUInt16LE(&output, 0) // mod time
            appendUInt16LE(&output, 0x5421) // mod date
            appendUInt32LE(&output, crc)
            appendUInt32LE(&output, UInt32(payload.count))
            appendUInt32LE(&output, UInt32(entry.data.count))
            appendUInt16LE(&output, UInt16(nameData.count))
            appendUInt16LE(&output, 0) // extra len
            output.append(nameData)
            output.append(payload)

            records.append(CentralRecord(
                nameData: nameData,
                crc: crc,
                method: method,
                compressedSize: UInt32(payload.count),
                uncompressedSize: UInt32(entry.data.count),
                localHeaderOffset: localOffset,
                unixPermissions: entry.unixPermissions
            ))
        }

        let cdOffset = UInt32(output.count)
        for rec in records {
            appendUInt32LE(&output, 0x02014B50)
            appendUInt16LE(&output, (3 << 8) | 20) // Unix creator (3), spec 2.0
            appendUInt16LE(&output, 20)
            appendUInt16LE(&output, 0x0800) // UTF-8
            appendUInt16LE(&output, rec.method)
            appendUInt16LE(&output, 0)
            appendUInt16LE(&output, 0x5421)
            appendUInt32LE(&output, rec.crc)
            appendUInt32LE(&output, rec.compressedSize)
            appendUInt32LE(&output, rec.uncompressedSize)
            appendUInt16LE(&output, UInt16(rec.nameData.count))
            appendUInt16LE(&output, 0) // extra
            appendUInt16LE(&output, 0) // comment
            appendUInt16LE(&output, 0) // disk number
            appendUInt16LE(&output, 0) // internal attrs
            let extAttrs = (UInt32(0o100000 | (rec.unixPermissions & 0o777)) << 16)
            appendUInt32LE(&output, extAttrs)
            appendUInt32LE(&output, rec.localHeaderOffset)
            output.append(rec.nameData)
        }
        let cdSize = UInt32(output.count) - cdOffset

        // End of Central Directory (22 bytes)
        appendUInt32LE(&output, 0x06054B50)
        appendUInt16LE(&output, 0) // disk
        appendUInt16LE(&output, 0) // cd disk
        appendUInt16LE(&output, UInt16(records.count))
        appendUInt16LE(&output, UInt16(records.count))
        appendUInt32LE(&output, cdSize)
        appendUInt32LE(&output, cdOffset)
        appendUInt16LE(&output, 0) // comment len

        return output
    }

    // MARK: - Path Safety

    public static func sanitizeRelativePath(_ raw: String) throws -> String {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains("\0") else {
            throw ZipArchiveError.unsafePath(raw)
        }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            if part.isEmpty || part == "." || part == ".." {
                throw ZipArchiveError.unsafePath(raw)
            }
        }
        return parts.joined(separator: "/")
    }

    private static func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func appendUInt16LE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

// MARK: - CRC32

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - RFC 1951 DEFLATE (Inflate + Fixed Huffman Deflate)

enum Deflate {
    private static let lengthBase: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
    ]
    private static let lengthExtraBits: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
    ]
    private static let distBase: [Int] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
    ]
    private static let distExtraBits: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
    ]
    private static let codeLengthOrder: [Int] = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
    ]

    struct BitReader {
        let bytes: [UInt8]
        var byteIndex = 0
        var bitBuffer: UInt64 = 0
        var bitCount = 0

        init(_ data: Data) {
            self.bytes = Array(data)
        }

        mutating func ensure(_ n: Int) throws {
            while bitCount < n {
                guard byteIndex < bytes.count else {
                    throw ZipArchiveError.corruptedData("unexpected end of deflate stream")
                }
                bitBuffer |= UInt64(bytes[byteIndex]) << UInt64(bitCount)
                byteIndex += 1
                bitCount += 8
            }
        }

        mutating func readBits(_ n: Int) throws -> Int {
            if n == 0 { return 0 }
            try ensure(n)
            let value = Int(bitBuffer & ((1 << n) - 1))
            bitBuffer >>= n
            bitCount -= n
            return value
        }

        mutating func alignToByte() {
            let discard = bitCount & 7
            bitBuffer >>= discard
            bitCount -= discard
        }

        mutating func readAlignedBytes(_ count: Int) throws -> [UInt8] {
            alignToByte()
            var out: [UInt8] = []
            out.reserveCapacity(count)
            while out.count < count && bitCount >= 8 {
                out.append(UInt8(bitBuffer & 0xFF))
                bitBuffer >>= 8
                bitCount -= 8
            }
            let remaining = count - out.count
            guard byteIndex + remaining <= bytes.count else {
                throw ZipArchiveError.corruptedData("stored block truncated")
            }
            if remaining > 0 {
                out.append(contentsOf: bytes[byteIndex..<(byteIndex + remaining)])
                byteIndex += remaining
            }
            return out
        }
    }

    struct HuffmanTree {
        // Table indexed by (bit-reversed code << ...) up to maxBits
        let maxBits: Int
        private var countByLen: [Int]
        private var symbols: [Int]
        private var offsets: [Int]

        init(lengths: [Int]) throws {
            let maxL = lengths.max() ?? 0
            self.maxBits = max(1, maxL)
            var counts = [Int](repeating: 0, count: self.maxBits + 1)
            for l in lengths where l > 0 {
                counts[l] += 1
            }
            var left = 1
            for len in 1...self.maxBits {
                left <<= 1
                left -= counts[len]
                if left < 0 {
                    throw ZipArchiveError.corruptedData("invalid Huffman tree")
                }
            }
            var offs = [Int](repeating: 0, count: self.maxBits + 1)
            var sum = 0
            for len in 1...self.maxBits {
                offs[len] = sum
                sum += counts[len]
            }
            var syms = [Int](repeating: 0, count: sum)
            var nextOff = offs
            for (symbol, len) in lengths.enumerated() where len > 0 {
                syms[nextOff[len]] = symbol
                nextOff[len] += 1
            }
            self.countByLen = counts
            self.offsets = offs
            self.symbols = syms
        }

        func decode(from reader: inout BitReader) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for len in 1...maxBits {
                code |= try reader.readBits(1)
                let count = countByLen[len]
                if code - count < first {
                    return symbols[index + (code - first)]
                }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw ZipArchiveError.corruptedData("invalid Huffman code")
        }
    }

    private static let fixedLitTree: HuffmanTree = {
        var lengths = [Int](repeating: 0, count: 288)
        for i in 0...143 { lengths[i] = 8 }
        for i in 144...255 { lengths[i] = 9 }
        for i in 256...279 { lengths[i] = 7 }
        for i in 280...287 { lengths[i] = 8 }
        return try! HuffmanTree(lengths: lengths)
    }()

    private static let fixedDistTree: HuffmanTree = {
        let lengths = [Int](repeating: 5, count: 32)
        return try! HuffmanTree(lengths: lengths)
    }()

    static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        var reader = BitReader(data)
        var out = [UInt8]()
        out.reserveCapacity(expectedSize)

        var bfinal = 0
        repeat {
            bfinal = try reader.readBits(1)
            let btype = try reader.readBits(2)
            switch btype {
            case 0:
                let header = try reader.readAlignedBytes(4)
                let len = Int(header[0]) | (Int(header[1]) << 8)
                let nlen = Int(header[2]) | (Int(header[3]) << 8)
                guard (len ^ 0xFFFF) == nlen else {
                    throw ZipArchiveError.corruptedData("stored block length mismatch")
                }
                let block = try reader.readAlignedBytes(len)
                out.append(contentsOf: block)
            case 1:
                try decodeCompressed(from: &reader, litTree: fixedLitTree, distTree: fixedDistTree, out: &out)
            case 2:
                let (litTree, distTree) = try readDynamicTrees(from: &reader)
                try decodeCompressed(from: &reader, litTree: litTree, distTree: distTree, out: &out)
            default:
                throw ZipArchiveError.corruptedData("reserved deflate block type 3")
            }
        } while bfinal == 0

        return Data(out)
    }

    private static func readDynamicTrees(from reader: inout BitReader) throws -> (HuffmanTree, HuffmanTree) {
        let hlit = try reader.readBits(5) + 257
        let hdist = try reader.readBits(5) + 1
        let hclen = try reader.readBits(4) + 4

        var clLengths = [Int](repeating: 0, count: 19)
        for i in 0..<hclen {
            clLengths[codeLengthOrder[i]] = try reader.readBits(3)
        }
        let clTree = try HuffmanTree(lengths: clLengths)

        let total = hlit + hdist
        var lengths = [Int]()
        lengths.reserveCapacity(total)
        while lengths.count < total {
            let sym = try clTree.decode(from: &reader)
            if sym < 16 {
                lengths.append(sym)
            } else if sym == 16 {
                guard let prev = lengths.last else {
                    throw ZipArchiveError.corruptedData("invalid repeat code in Huffman header")
                }
                let count = 3 + (try reader.readBits(2))
                for _ in 0..<count { lengths.append(prev) }
            } else if sym == 17 {
                let count = 3 + (try reader.readBits(3))
                for _ in 0..<count { lengths.append(0) }
            } else if sym == 18 {
                let count = 11 + (try reader.readBits(7))
                for _ in 0..<count { lengths.append(0) }
            } else {
                throw ZipArchiveError.corruptedData("invalid code length symbol \(sym)")
            }
        }
        guard lengths.count == total else {
            throw ZipArchiveError.corruptedData("code length overflow")
        }
        let litTree = try HuffmanTree(lengths: Array(lengths[0..<hlit]))
        let distTree = try HuffmanTree(lengths: Array(lengths[hlit..<total]))
        return (litTree, distTree)
    }

    private static func decodeCompressed(
        from reader: inout BitReader,
        litTree: HuffmanTree,
        distTree: HuffmanTree,
        out: inout [UInt8]
    ) throws {
        while true {
            let sym = try litTree.decode(from: &reader)
            if sym < 256 {
                out.append(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                let lenIndex = sym - 257
                guard lenIndex >= 0, lenIndex < lengthBase.count else {
                    throw ZipArchiveError.corruptedData("invalid length symbol \(sym)")
                }
                let length = lengthBase[lenIndex] + (try reader.readBits(lengthExtraBits[lenIndex]))
                let distSym = try distTree.decode(from: &reader)
                guard distSym >= 0, distSym < distBase.count else {
                    throw ZipArchiveError.corruptedData("invalid distance symbol \(distSym)")
                }
                let distance = distBase[distSym] + (try reader.readBits(distExtraBits[distSym]))
                guard distance > 0, distance <= out.count else {
                    throw ZipArchiveError.corruptedData("distance \(distance) out of bounds")
                }
                for _ in 0..<length {
                    out.append(out[out.count - distance])
                }
            }
        }
    }

    // MARK: - Fixed Huffman LZ77 Deflate Writer

    private struct BitWriter {
        var bytes: [UInt8] = []
        var bitBuffer: UInt64 = 0
        var bitCount = 0

        mutating func writeBits(_ value: UInt32, count: Int) {
            bitBuffer |= UInt64(value) << UInt64(bitCount)
            bitCount += count
            while bitCount >= 8 {
                bytes.append(UInt8(bitBuffer & 0xFF))
                bitBuffer >>= 8
                bitCount -= 8
            }
        }

        mutating func writeReversedCode(_ code: UInt32, bits: Int) {
            var rev: UInt32 = 0
            var c = code
            for _ in 0..<bits {
                rev = (rev << 1) | (c & 1)
                c >>= 1
            }
            writeBits(rev, count: bits)
        }

        mutating func finish() -> Data {
            if bitCount > 0 {
                bytes.append(UInt8(bitBuffer & 0xFF))
                bitBuffer = 0
                bitCount = 0
            }
            return Data(bytes)
        }
    }

    static func deflateFixed(_ data: Data) -> Data {
        let src = Array(data)
        var writer = BitWriter()
        writer.writeBits(1, count: 1) // BFINAL = 1
        writer.writeBits(1, count: 2) // BTYPE = 01 (fixed Huffman)

        func writeLiteral(_ b: UInt8) {
            let v = UInt32(b)
            if v <= 143 {
                writer.writeReversedCode(0b00110000 + v, bits: 8)
            } else {
                writer.writeReversedCode(0b110010000 + (v - 144), bits: 9)
            }
        }

        func writeLength(_ len: Int) {
            var idx = lengthBase.count - 1
            while idx > 0 && lengthBase[idx] > len { idx -= 1 }
            let sym = 257 + idx
            if sym <= 279 {
                writer.writeReversedCode(UInt32(sym - 256), bits: 7)
            } else {
                writer.writeReversedCode(0b11000000 + UInt32(sym - 280), bits: 8)
            }
            let extra = lengthExtraBits[idx]
            if extra > 0 {
                writer.writeBits(UInt32(len - lengthBase[idx]), count: extra)
            }
        }

        func writeDistance(_ dist: Int) {
            var idx = distBase.count - 1
            while idx > 0 && distBase[idx] > dist { idx -= 1 }
            writer.writeReversedCode(UInt32(idx), bits: 5)
            let extra = distExtraBits[idx]
            if extra > 0 {
                writer.writeBits(UInt32(dist - distBase[idx]), count: extra)
            }
        }

        // Fast 3-byte hash-chain LZ77
        let hashSize = 1 << 15
        let hashMask = hashSize - 1
        var head = [Int](repeating: -1, count: hashSize)
        var prev = [Int](repeating: -1, count: src.count)

        @inline(__always)
        func hash3(_ i: Int) -> Int {
            ((Int(src[i]) << 10) ^ (Int(src[i + 1]) << 5) ^ Int(src[i + 2])) & hashMask
        }

        var i = 0
        while i < src.count {
            var bestLen = 0
            var bestDist = 0
            if i + 3 <= src.count {
                let h = hash3(i)
                var candidate = head[h]
                prev[i] = candidate
                head[h] = i
                var steps = 0
                let minPos = max(0, i - 32768)
                while candidate >= minPos && steps < 32 {
                    if src[candidate] == src[i] && src[candidate + 1] == src[i + 1] && src[candidate + 2] == src[i + 2] {
                        let maxMatch = min(258, src.count - i)
                        var len = 3
                        while len < maxMatch && src[candidate + len] == src[i + len] {
                            len += 1
                        }
                        if len > bestLen {
                            bestLen = len
                            bestDist = i - candidate
                            if len == 258 { break }
                        }
                    }
                    candidate = prev[candidate]
                    steps += 1
                }
            }

            if bestLen >= 3 {
                writeLength(bestLen)
                writeDistance(bestDist)
                let end = min(i + bestLen, src.count - 2)
                var j = i + 1
                while j < end {
                    let h = hash3(j)
                    prev[j] = head[h]
                    head[h] = j
                    j += 1
                }
                i += bestLen
            } else {
                writeLiteral(src[i])
                i += 1
            }
        }

        // End of block (symbol 256: 7 bits 0000000)
        writer.writeReversedCode(0, bits: 7)
        return writer.finish()
    }
}
