import Foundation

/// Supported Web services whose browser session cookies can be imported on macOS.
enum BrowserCookieService: Sendable {
    case spotify
    case youtubeMusic

    var serviceDisplayName: String {
        switch self {
        case .spotify: "Spotify (open.spotify.com)"
        case .youtubeMusic: "YouTube Music (music.youtube.com)"
        }
    }

    var primaryDomains: [String] {
        switch self {
        case .spotify: ["spotify.com"]
        case .youtubeMusic: ["youtube.com", "google.com"]
        }
    }

    var probeCookieNames: [String] {
        switch self {
        case .spotify: ["sp_dc"]
        case .youtubeMusic: ["__Secure-3PAPISID", "SAPISID", "__Secure-1PAPISID"]
        }
    }
}

/// A local browser profile that appears to contain an active Web session cookie.
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
    case noCookiesFound(service: String)
    case safariPermissionDenied
    case keychainDenied(browser: String)
    case decryptFailed(browser: String, service: String)
    case malformedDatabase(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Browser cookie import is currently only supported on macOS."
        case .noCookiesFound(let service):
            return "No active \(service) session found in local browsers. Sign in there in Chrome, Brave, Arc, or Firefox first."
        case .safariPermissionDenied:
            return "Safari requires Full Disk Access in System Settings › Privacy & Security › Full Disk Access. You can import from Chrome, Firefox, Brave, or Arc instead."
        case .keychainDenied(let browser):
            return "macOS Keychain access for '\(browser) Safe Storage' was denied."
        case .decryptFailed(let browser, let service):
            return "Could not decrypt the \(service) cookie from \(browser)."
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

/// Reads Spotify (`sp_dc`) and YouTube Music cookies on demand from installed macOS browsers (zero background work).
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

    /// Scans browser cookie stores on disk for an active session of `service` without touching macOS Keychain.
    static func discoverCookieBrowsers(for service: BrowserCookieService) -> [BrowserCookieCandidate] {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }

        var results: [BrowserCookieCandidate] = []
        let ffHostClause = sqlHostCondition(column: "host", domains: service.primaryDomains)
        let chrHostClause = sqlHostCondition(column: "host_key", domains: service.primaryDomains)
        let nameList = service.probeCookieNames.map { "'\($0)'" }.joined(separator: ", ")

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
                    sql: "SELECT expiry FROM moz_cookies WHERE (\(ffHostClause)) AND name IN (\(nameList)) AND length(value) > 0 ORDER BY expiry DESC LIMIT 1"
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
                    sql: "SELECT expires_utc FROM cookies WHERE (\(chrHostClause)) AND name IN (\(nameList)) AND (length(value) > 0 OR length(encrypted_value) > 0) ORDER BY expires_utc DESC LIMIT 1"
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
        if let data = try? Data(contentsOf: URL(fileURLWithPath: safariPath)) {
            let safariCookies = parseSafariBinaryCookies(data: data, domains: service.primaryDomains)
            if service.probeCookieNames.contains(where: { !(safariCookies[$0]?.isEmpty ?? true) }) {
                results.append(BrowserCookieCandidate(
                    id: "safari:\(safariPath)",
                    browserName: "Safari",
                    profileLabel: nil,
                    lastExpiry: Int64.max / 2,
                    kind: .safari(binaryCookiesPath: safariPath)
                ))
            }
        }

        return results.sorted { $0.lastExpiry > $1.lastExpiry }
    }

    /// Reads and decrypts the cookie string (`sp_dc` value for Spotify, full `Cookie:` header for YouTube Music).
    static func readCookiePayload(from candidate: BrowserCookieCandidate, service: BrowserCookieService) throws -> String {
        switch service {
        case .spotify:
            let map = try readCookieMap(from: candidate, service: service)
            guard let spDC = map["sp_dc"], !spDC.isEmpty else {
                throw BrowserCookieImportError.noCookiesFound(service: service.serviceDisplayName)
            }
            return spDC

        case .youtubeMusic:
            let map = try readCookieMap(from: candidate, service: service)
            guard service.probeCookieNames.contains(where: { !(map[$0]?.isEmpty ?? true) }) else {
                throw BrowserCookieImportError.noCookiesFound(service: service.serviceDisplayName)
            }
            return map.keys.sorted().compactMap { name in
                guard let val = map[name], !val.isEmpty else { return nil }
                return "\(name)=\(val)"
            }.joined(separator: "; ")
        }
    }

    private static func sqlHostCondition(column: String, domains: [String]) -> String {
        domains.map { "\(column) LIKE '%.\($0)' OR \(column) = '\($0)'" }.joined(separator: " OR ")
    }

    private static func readCookieMap(from candidate: BrowserCookieCandidate, service: BrowserCookieService) throws -> [String: String] {
        let hostCol = { (col: String) in sqlHostCondition(column: col, domains: service.primaryDomains) }
        switch candidate.kind {
        case .firefox(let dbPath):
            let map = try withTemporarySQLiteCopy(at: URL(fileURLWithPath: dbPath), query: { (db) -> [String: String] in
                let filter = service == .spotify ? "AND name = 'sp_dc'" : ""
                let sql = "SELECT host, name, value FROM moz_cookies WHERE (\(hostCol("host"))) \(filter) AND length(value) > 0 ORDER BY expiry ASC"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
                defer { sqlite3_finalize(stmt) }
                var collected: [String: String] = [:]
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let host = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    guard let nPtr = sqlite3_column_text(stmt, 1),
                          let vPtr = sqlite3_column_text(stmt, 2) else { continue }
                    let name = String(cString: nPtr).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = String(cString: vPtr).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, !value.isEmpty else { continue }
                    // Prefer `.youtube.com` over `.google.com` if both define a key.
                    if collected[name] == nil || host.contains("youtube.com") {
                        collected[name] = value
                    }
                }
                return collected
            }) ?? [:]
            guard !map.isEmpty else {
                throw BrowserCookieImportError.noCookiesFound(service: service.serviceDisplayName)
            }
            return map

        case .chromium(let dbPath, let keychainService, let keychainAccount):
            struct Row {
                var hostKey: String
                var name: String
                var plain: String
                var encrypted: Data
            }
            let payload: (metaVersion: Int, rows: [Row])? = try withTemporarySQLiteCopy(at: URL(fileURLWithPath: dbPath), query: { db in
                var metaVersion = 0
                var mStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version' LIMIT 1", -1, &mStmt, nil) == SQLITE_OK {
                    if sqlite3_step(mStmt) == SQLITE_ROW, let cStr = sqlite3_column_text(mStmt, 0) {
                        metaVersion = Int(String(cString: cStr)) ?? 0
                    }
                    sqlite3_finalize(mStmt)
                }

                let filter = service == .spotify ? "AND name = 'sp_dc'" : ""
                let sql = "SELECT host_key, name, value, encrypted_value FROM cookies WHERE (\(hostCol("host_key"))) \(filter) ORDER BY expires_utc ASC"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (metaVersion, []) }
                defer { sqlite3_finalize(stmt) }
                var rows: [Row] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let hostKey = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let plain = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    let bytes = sqlite3_column_bytes(stmt, 3)
                    let blob: Data
                    if bytes > 0, let rawPtr = sqlite3_column_blob(stmt, 3) {
                        blob = Data(bytes: rawPtr, count: Int(bytes))
                    } else {
                        blob = Data()
                    }
                    guard !name.isEmpty else { continue }
                    rows.append(Row(hostKey: hostKey, name: name, plain: plain, encrypted: blob))
                }
                return (metaVersion, rows)
            })

            guard let payload, !payload.rows.isEmpty else {
                throw BrowserCookieImportError.noCookiesFound(service: service.serviceDisplayName)
            }

            var password: String?
            var collected: [String: String] = [:]
            var failedDecrypts = 0
            for row in payload.rows {
                let value: String?
                let trimmedPlain = row.plain.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedPlain.isEmpty {
                    value = trimmedPlain
                } else if !row.encrypted.isEmpty {
                    if password == nil {
                        password = try readKeychainPassword(service: keychainService, account: keychainAccount, browserName: candidate.browserName)
                    }
                    value = decryptChromiumMacCookie(
                        encryptedValue: row.encrypted,
                        hostKey: row.hostKey,
                        metaVersion: payload.metaVersion,
                        password: password!
                    )
                    if value == nil || value?.isEmpty == true {
                        failedDecrypts += 1
                    }
                } else {
                    value = nil
                }

                if let value, !value.isEmpty {
                    if collected[row.name] == nil || row.hostKey.contains("youtube.com") {
                        collected[row.name] = value
                    }
                }
            }

            if collected.isEmpty {
                if failedDecrypts > 0 {
                    throw BrowserCookieImportError.decryptFailed(browser: candidate.browserName, service: service.serviceDisplayName)
                }
                throw BrowserCookieImportError.noCookiesFound(service: service.serviceDisplayName)
            }
            return collected

        case .safari(let path):
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let map = parseSafariBinaryCookies(data: data, domains: service.primaryDomains)
                guard !map.isEmpty else {
                    throw BrowserCookieImportError.noCookiesFound(service: service.serviceDisplayName)
                }
                return map
            } catch let err as NSError where err.domain == NSCocoaErrorDomain && (err.code == NSFileReadNoPermissionError || err.code == NSFileNoSuchFileError) {
                if err.code == NSFileReadNoPermissionError {
                    throw BrowserCookieImportError.safariPermissionDenied
                }
                throw BrowserCookieImportError.noCookiesFound(service: service.serviceDisplayName)
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

    private static func parseSafariBinaryCookies(data: Data, domains: [String]) -> [String: String] {
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
            return [:]
        }

        var cursor = 8
        var pageSizes: [Int] = []
        for _ in 0..<numPages {
            guard let sz = readUInt32BE(cursor) else { return [:] }
            pageSizes.append(Int(sz))
            cursor += 4
        }

        var collected: [String: String] = [:]
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
                let matchesDomain = domains.contains { d in
                    domain == d || domain.hasSuffix("." + d)
                }
                if matchesDomain && !name.isEmpty && !value.isEmpty {
                    if collected[name] == nil || domain.contains("youtube.com") {
                        collected[name] = value
                    }
                }
            }
        }
        return collected
    }
}

#else

enum BrowserCookieImporter {
    static var isSupportedOnPlatform: Bool { false }
    static func discoverCookieBrowsers(for _: BrowserCookieService) -> [BrowserCookieCandidate] { [] }
    static func readCookiePayload(from _: BrowserCookieCandidate, service _: BrowserCookieService) throws -> String {
        throw BrowserCookieImportError.unsupportedPlatform
    }
    static func safariBlockedByPermissions() -> Bool { false }
}

#endif
