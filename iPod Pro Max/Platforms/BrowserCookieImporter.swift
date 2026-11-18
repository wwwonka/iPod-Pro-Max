import Foundation

/// A local browser profile that appears to contain an active Spotify session (`sp_dc`) cookie.
struct BrowserCookieCandidate: Identifiable, Hashable, Sendable {
    enum SourceKind: Hashable, Sendable {
        case firefox(dbPath: String)
        case chromium(dbPath: String, keychainService: String, keychainAccount: String)
        case safari(binaryCookiesPath: String)
    }

    var id: String
    var browserName: String
    var profileLabel: String?
    var lastExpiry: Int64
    var kind: SourceKind

    var displayTitle: String {
        if let profileLabel, !profileLabel.isEmpty, profileLabel != "Default" {
            return "\(browserName) (\(profileLabel))"
        }
        return browserName
    }
}

enum BrowserCookieImportError: LocalizedError {
    case unsupportedPlatform
    case noCookiesFound
    case safariPermissionDenied
    case keychainDenied(browser: String)
    case decryptFailed(browser: String)
    case malformedDatabase(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Browser cookie import is currently only supported on macOS."
        case .noCookiesFound:
            return "No active Spotify session (sp_dc) found in local browsers. Sign in on open.spotify.com in Chrome, Brave, Arc, or Firefox first."
        case .safariPermissionDenied:
            return "Safari requires Full Disk Access in System Settings › Privacy & Security › Full Disk Access. You can import from Chrome, Firefox, Brave, or Arc instead."
        case .keychainDenied(let browser):
            return "macOS Keychain access for '\(browser) Safe Storage' was denied."
        case .decryptFailed(let browser):
            return "Could not decrypt the Spotify cookie from \(browser)."
        case .malformedDatabase(let detail):
            return detail
        }
    }
}

#if os(macOS)
import CommonCrypto
import CryptoKit
import Security
import SQLite3

/// Reads Spotify `sp_dc` cookies on demand from installed macOS browsers (zero background work).
enum BrowserCookieImporter {
    static var isSupportedOnPlatform: Bool { true }

    private struct ChromiumSpec {
        let name: String
        let relativeDataDir: String
        let keychainService: String
        let keychainAccount: String
    }

    private struct FirefoxSpec {
        let name: String
        let relativeProfilesDir: String
    }

    private static let chromiumSpecs: [ChromiumSpec] = [
        ChromiumSpec(name: "Google Chrome", relativeDataDir: "Google/Chrome", keychainService: "Chrome Safe Storage", keychainAccount: "Chrome"),
        ChromiumSpec(name: "Brave", relativeDataDir: "BraveSoftware/Brave-Browser", keychainService: "Brave Safe Storage", keychainAccount: "Brave"),
        ChromiumSpec(name: "Arc", relativeDataDir: "Arc/User Data", keychainService: "Arc Safe Storage", keychainAccount: "Arc"),
        ChromiumSpec(name: "Microsoft Edge", relativeDataDir: "Microsoft Edge", keychainService: "Microsoft Edge Safe Storage", keychainAccount: "Microsoft Edge"),
        ChromiumSpec(name: "Vivaldi", relativeDataDir: "Vivaldi", keychainService: "Vivaldi Safe Storage", keychainAccount: "Vivaldi"),
        ChromiumSpec(name: "Dia", relativeDataDir: "Dia/User Data", keychainService: "Dia Safe Storage", keychainAccount: "Dia"),
        ChromiumSpec(name: "Opera", relativeDataDir: "com.operasoftware.Opera", keychainService: "Opera Safe Storage", keychainAccount: "Opera"),
        ChromiumSpec(name: "Chromium", relativeDataDir: "Chromium", keychainService: "Chromium Safe Storage", keychainAccount: "Chromium"),
    ]

    private static let firefoxSpecs: [FirefoxSpec] = [
        FirefoxSpec(name: "Firefox", relativeProfilesDir: "Firefox/Profiles"),
        FirefoxSpec(name: "Zen", relativeProfilesDir: "zen/Profiles"),
        FirefoxSpec(name: "LibreWolf", relativeProfilesDir: "LibreWolf/Profiles"),
        FirefoxSpec(name: "Waterfox", relativeProfilesDir: "Waterfox/Profiles"),
    ]

    /// Scans browser cookie stores on disk for Spotify `sp_dc` presence without touching macOS Keychain.
    static func discoverSpotifyCookieBrowsers() -> [BrowserCookieCandidate] {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }

        var results: [BrowserCookieCandidate] = []

        // 1. Firefox family (unencrypted SQLite)
        for spec in firefoxSpecs {
            let profilesRoot = appSupport.appendingPathComponent(spec.relativeProfilesDir, isDirectory: true)
            guard let children = try? fm.contentsOfDirectory(at: profilesRoot, includingPropertiesForKeys: [.isDirectoryKey]) else {
                continue
            }
            for profileDir in children {
                let dbURL = profileDir.appendingPathComponent("cookies.sqlite")
                guard fm.fileExists(atPath: dbURL.path) else { continue }
                if let info = probeSQLite(
                    dbURL: dbURL,
                    sql: "SELECT expiry FROM moz_cookies WHERE (host LIKE '%.spotify.com' OR host = 'spotify.com') AND name = 'sp_dc' AND length(value) > 0 ORDER BY expiry DESC LIMIT 1"
                ) {
                    let cleanProfile = profileDir.lastPathComponent.split(separator: ".").dropFirst().joined(separator: ".")
                    results.append(BrowserCookieCandidate(
                        id: "ff:\(dbURL.path)",
                        browserName: spec.name,
                        profileLabel: cleanProfile.isEmpty ? nil : cleanProfile,
                        lastExpiry: info,
                        kind: .firefox(dbPath: dbURL.path)
                    ))
                }
            }
        }

        // 2. Chromium family (encrypted SQLite; Keychain is only touched later if selected)
        for spec in chromiumSpecs {
            let baseDir = appSupport.appendingPathComponent(spec.relativeDataDir, isDirectory: true)
            guard fm.fileExists(atPath: baseDir.path) else { continue }

            var profileDirs: [URL] = []
            if let children = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.isDirectoryKey]) {
                for child in children {
                    let name = child.lastPathComponent
                    if name == "Default" || name.hasPrefix("Profile ") {
                        profileDirs.append(child)
                    }
                }
            }
            // Opera sometimes puts Cookies right in the base data dir
            if fm.fileExists(atPath: baseDir.appendingPathComponent("Cookies").path) {
                profileDirs.append(baseDir)
            }

            for dir in profileDirs {
                let dbURL = dir.appendingPathComponent("Cookies")
                guard fm.fileExists(atPath: dbURL.path) else { continue }
                if let expiry = probeSQLite(
                    dbURL: dbURL,
                    sql: "SELECT expires_utc FROM cookies WHERE (host_key LIKE '%.spotify.com' OR host_key = 'spotify.com') AND name = 'sp_dc' AND (length(value) > 0 OR length(encrypted_value) > 0) ORDER BY expires_utc DESC LIMIT 1"
                ) {
                    let label = (dir == baseDir) ? nil : dir.lastPathComponent
                    results.append(BrowserCookieCandidate(
                        id: "chr:\(dbURL.path)",
                        browserName: spec.name,
                        profileLabel: label,
                        lastExpiry: expiry,
                        kind: .chromium(
                            dbPath: dbURL.path,
                            keychainService: spec.keychainService,
                            keychainAccount: spec.keychainAccount
                        )
                    ))
                }
            }
        }

        // 3. Safari (if readable — requires Full Disk Access on modern macOS)
        let safariPath = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
            .path
        if let data = try? Data(contentsOf: URL(fileURLWithPath: safariPath)),
           let cookie = parseSafariBinaryCookies(data: data, domainSuffix: "spotify.com", cookieName: "sp_dc"),
           !cookie.isEmpty {
            results.append(BrowserCookieCandidate(
                id: "safari:\(safariPath)",
                browserName: "Safari",
                profileLabel: nil,
                lastExpiry: Int64.max / 2,
                kind: .safari(binaryCookiesPath: safariPath)
            ))
        }

        return results.sorted { $0.lastExpiry > $1.lastExpiry }
    }

    /// Reads and decrypts the `sp_dc` value for the chosen browser profile.
    static func readSpotifyCookie(from candidate: BrowserCookieCandidate) throws -> String {
        switch candidate.kind {
        case .firefox(let dbPath):
            guard let val = try withTemporarySQLiteCopy(at: URL(fileURLWithPath: dbPath), query: { (db) -> String? in
                let sql = "SELECT value FROM moz_cookies WHERE (host LIKE '%.spotify.com' OR host = 'spotify.com') AND name = 'sp_dc' AND length(value) > 0 ORDER BY expiry DESC LIMIT 1"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) else { return nil }
                return String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
            }), !val.isEmpty else {
                throw BrowserCookieImportError.noCookiesFound
            }
            return val

        case .chromium(let dbPath, let keychainService, let keychainAccount):
            struct Row {
                var plain: String
                var encrypted: Data
                var hostKey: String
                var metaVersion: Int
            }
            guard let row: Row = try withTemporarySQLiteCopy(at: URL(fileURLWithPath: dbPath), query: { db in
                var metaVersion = 0
                var mStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version' LIMIT 1", -1, &mStmt, nil) == SQLITE_OK {
                    if sqlite3_step(mStmt) == SQLITE_ROW, let cStr = sqlite3_column_text(mStmt, 0) {
                        metaVersion = Int(String(cString: cStr)) ?? 0
                    }
                    sqlite3_finalize(mStmt)
                }

                let sql = "SELECT value, encrypted_value, host_key FROM cookies WHERE (host_key LIKE '%.spotify.com' OR host_key = 'spotify.com') AND name = 'sp_dc' ORDER BY expires_utc DESC LIMIT 1"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

                let plain = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let bytes = sqlite3_column_bytes(stmt, 1)
                let blob: Data
                if bytes > 0, let rawPtr = sqlite3_column_blob(stmt, 1) {
                    blob = Data(bytes: rawPtr, count: Int(bytes))
                } else {
                    blob = Data()
                }
                let hostKey = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                return Row(plain: plain, encrypted: blob, hostKey: hostKey, metaVersion: metaVersion)
            }) else {
                throw BrowserCookieImportError.noCookiesFound
            }

            let trimmedPlain = row.plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPlain.isEmpty {
                return trimmedPlain
            }
            guard !row.encrypted.isEmpty else {
                throw BrowserCookieImportError.noCookiesFound
            }

            let password = try readKeychainPassword(service: keychainService, account: keychainAccount, browserName: candidate.browserName)
            guard let decrypted = decryptChromiumMacCookie(
                encryptedValue: row.encrypted,
                hostKey: row.hostKey,
                metaVersion: row.metaVersion,
                password: password
            ), !decrypted.isEmpty else {
                throw BrowserCookieImportError.decryptFailed(browser: candidate.browserName)
            }
            return decrypted

        case .safari(let path):
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                guard let val = parseSafariBinaryCookies(data: data, domainSuffix: "spotify.com", cookieName: "sp_dc"),
                      !val.isEmpty else {
                    throw BrowserCookieImportError.noCookiesFound
                }
                return val
            } catch let err as NSError where err.domain == NSCocoaErrorDomain && (err.code == NSFileReadNoPermissionError || err.code == NSFileNoSuchFileError) {
                if err.code == NSFileReadNoPermissionError {
                    throw BrowserCookieImportError.safariPermissionDenied
                }
                throw BrowserCookieImportError.noCookiesFound
            }
        }
    }

    /// Checks whether Safari's binarycookies file exists yet failed permission checks (to improve error hints).
    static func safariBlockedByPermissions() -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
            .path
        do {
            _ = try Data(contentsOf: URL(fileURLWithPath: path))
            return false
        } catch let err as NSError {
            return err.domain == NSCocoaErrorDomain && err.code == NSFileReadNoPermissionError
        }
    }

    // MARK: - SQLite Snapshot Helper

    private static func probeSQLite(dbURL: URL, sql: String) -> Int64? {
        try? withTemporarySQLiteCopy(at: dbURL) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    private static func withTemporarySQLiteCopy<T>(at dbURL: URL, query: (OpaquePointer) -> T?) throws -> T? {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ippm-cookies-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let copiedDB = tempDir.appendingPathComponent("cookies.db")
        try fm.copyItem(at: dbURL, to: copiedDB)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: dbURL.path + suffix)
            if fm.fileExists(atPath: sidecar.path) {
                try? fm.copyItem(at: sidecar, to: URL(fileURLWithPath: copiedDB.path + suffix))
            }
        }

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(copiedDB.path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        return query(db)
    }

    // MARK: - Chromium Keychain & AES-128-CBC Decryption

    private static func readKeychainPassword(service: String, account: String, browserName: String) throws -> String {
        let queries: [[CFString: Any]] = [
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ],
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ],
        ]

        for q in queries {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data,
               let pwd = String(data: data, encoding: .utf8), !pwd.isEmpty {
                return pwd
            }
            if status == errSecAuthFailed || status == errSecUserCanceled {
                throw BrowserCookieImportError.keychainDenied(browser: browserName)
            }
        }
        throw BrowserCookieImportError.keychainDenied(browser: browserName)
    }

    private static func decryptChromiumMacCookie(
        encryptedValue: Data,
        hostKey: String,
        metaVersion: Int,
        password: String
    ) -> String? {
        guard encryptedValue.count > 3 else { return nil }
        let prefix = String(data: encryptedValue.prefix(3), encoding: .ascii)
        guard prefix == "v10" || prefix == "v11" else {
            return String(data: encryptedValue, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cipherData = Data(encryptedValue.dropFirst(3))

        var derivedKey = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let saltBytes = Array("saltysalt".utf8)
        let pbkdfStatus = password.withCString { pwdPtr in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pwdPtr,
                password.utf8.count,
                saltBytes,
                saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                &derivedKey,
                derivedKey.count
            )
        }
        guard pbkdfStatus == kCCSuccess else { return nil }

        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var outBytes = [UInt8](repeating: 0, count: cipherData.count + kCCBlockSizeAES128)
        var outLen: size_t = 0

        let cryptStatus = cipherData.withUnsafeBytes { cipherPtr in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                derivedKey,
                derivedKey.count,
                iv,
                cipherPtr.baseAddress,
                cipherData.count,
                &outBytes,
                outBytes.count,
                &outLen
            )
        }
        guard cryptStatus == kCCSuccess, outLen > 0 else { return nil }

        var plainData = Data(outBytes.prefix(outLen))
        // Chrome DB v24+ prepends SHA-256(host_key) (32 bytes) to every encrypted cookie value.
        if plainData.count > 32 {
            let expectedHostHash = Data(SHA256.hash(data: Data(hostKey.utf8)))
            if plainData.prefix(32) == expectedHostHash || metaVersion >= 24 {
                plainData = Data(plainData.dropFirst(32))
            }
        }
        return String(data: plainData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Safari Binary Cookies Parser

    private static func parseSafariBinaryCookies(data: Data, domainSuffix: String, cookieName: String) -> String? {
        func readUInt32BE(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            var val: UInt32 = 0
            for i in 0..<4 {
                val = (val << 8) | UInt32(data[offset + i])
            }
            return val
        }
        func readUInt32LE(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }
        func readCString(from start: Int, limit: Int) -> String? {
            guard start >= 0, start < limit, limit <= data.count else { return nil }
            var end = start
            while end < limit && data[end] != 0 {
                end += 1
            }
            return String(data: data[start..<end], encoding: .utf8)
        }

        guard data.count >= 8,
              String(data: data.prefix(4), encoding: .ascii) == "cook",
              let numPages = readUInt32BE(4) else {
            return nil
        }

        var cursor = 8
        var pageSizes: [Int] = []
        for _ in 0..<numPages {
            guard let sz = readUInt32BE(cursor) else { return nil }
            pageSizes.append(Int(sz))
            cursor += 4
        }

        for pageSize in pageSizes {
            let pageStart = cursor
            let pageEnd = min(pageStart + pageSize, data.count)
            cursor = pageEnd
            guard pageStart + 8 <= pageEnd,
                  let count = readUInt32LE(pageStart + 4) else { continue }

            for idx in 0..<Int(count) {
                guard let relOffset = readUInt32LE(pageStart + 8 + idx * 4) else { continue }
                let cookieStart = pageStart + Int(relOffset)
                guard cookieStart + 32 <= pageEnd,
                      let cookieSize = readUInt32LE(cookieStart),
                      let urlOff = readUInt32LE(cookieStart + 16),
                      let nameOff = readUInt32LE(cookieStart + 20),
                      let valueOff = readUInt32LE(cookieStart + 28) else { continue }

                let cookieLimit = min(cookieStart + Int(cookieSize), pageEnd)
                guard let domain = readCString(from: cookieStart + Int(urlOff), limit: cookieLimit),
                      let name = readCString(from: cookieStart + Int(nameOff), limit: cookieLimit),
                      let value = readCString(from: cookieStart + Int(valueOff), limit: cookieLimit) else {
                    continue
                }
                if name == cookieName && (domain == domainSuffix || domain.hasSuffix("." + domainSuffix)) && !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }
}

#else

enum BrowserCookieImporter {
    static var isSupportedOnPlatform: Bool { false }
    static func discoverSpotifyCookieBrowsers() -> [BrowserCookieCandidate] { [] }
    static func readSpotifyCookie(from candidate: BrowserCookieCandidate) throws -> String {
        throw BrowserCookieImportError.unsupportedPlatform
    }
    static func safariBlockedByPermissions() -> Bool { false }
}

#endif
