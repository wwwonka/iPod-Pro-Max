import Foundation
import PluginKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cross-platform HTTP response wrapper for YouTube Music InnerTube calls.
public struct HTTPResponseData: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func headerValue(_ name: String) -> String? {
        let target = name.lowercased()
        return headers.first { $0.key.lowercased() == target }?.value
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponseData
}

/// Default `URLSession.portableData` transport supporting macOS, Linux, and Windows with cancellation.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponseData {
        do {
            let (data, response) = try await session.portableData(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PluginError(code: .network, message: "Invalid network response from YouTube Music.")
            }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let ks = k as? String, let vs = v as? String {
                    headers[ks] = vs
                }
            }
            return HTTPResponseData(statusCode: http.statusCode, headers: headers, body: data)
        } catch let err as PluginError {
            throw err
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PluginError(code: .network, message: error.localizedDescription)
        }
    }
}

/// Ephemeral InnerTube Web client configuration scraped from `https://music.youtube.com` `ytcfg`.
public struct InnerTubeClientConfig: Equatable, Sendable {
    public var apiKey: String
    public var clientVersion: String
    public var visitorData: String?
    public var sessionIndex: String?
    public var delegatedSessionID: String?
    public var loggedIn: Bool?

    public init(
        apiKey: String,
        clientVersion: String,
        visitorData: String? = nil,
        sessionIndex: String? = nil,
        delegatedSessionID: String? = nil,
        loggedIn: Bool? = nil
    ) {
        self.apiKey = apiKey
        self.clientVersion = clientVersion
        self.visitorData = visitorData
        self.sessionIndex = sessionIndex
        self.delegatedSessionID = delegatedSessionID
        self.loggedIn = loggedIn
    }
}

/// Optional authenticated YouTube Music Web session captured via browser cookies, WebView, or pasted `Cookie` header.
public struct YTMusicUserSession: Codable, Equatable, Sendable {
    public var cookieHeader: String?
    public var displayName: String?
    public var authUser: String?
    public var delegatedSessionID: String?

    public init(
        cookieHeader: String? = nil,
        displayName: String? = nil,
        authUser: String? = nil,
        delegatedSessionID: String? = nil
    ) {
        self.cookieHeader = cookieHeader
        self.displayName = displayName
        self.authUser = authUser
        self.delegatedSessionID = delegatedSessionID
    }

    public var isSignedIn: Bool {
        let cookies = YTMusicCookieHelper.parseCookies(cookieHeader ?? "")
        return YTMusicCookieHelper.hasAuthCookie(cookies)
    }

    public func authorizationHeader(origin: String = InnerTube.origin, now: Date = Date()) -> String? {
        guard let cookieHeader, !cookieHeader.isEmpty else { return nil }
        return YTMusicCookieHelper.buildSAPISIDAuthHeader(cookieHeader: cookieHeader, origin: origin, now: now)
    }
}

/// Pure helpers for parsing `Cookie` strings and computing Google `SAPISIDHASH` authorization headers.
public enum YTMusicCookieHelper {
    public static func parseCookies(_ header: String) -> [String: String] {
        var out: [String: String] = [:]
        let cleaned = header.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "; ")
        for pair in cleaned.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            out[name] = value
        }
        return out
    }

    public static func hasAuthCookie(_ cookies: [String: String]) -> Bool {
        !(cookies["SAPISID"]?.isEmpty ?? true)
            || !(cookies["__Secure-3PAPISID"]?.isEmpty ?? true)
            || !(cookies["__Secure-1PAPISID"]?.isEmpty ?? true)
    }

    /// Computes Google's `SAPISIDHASH` (and `SAPISID1PHASH`/`SAPISID3PHASH` when present) using portable `PluginKit.SHA1`.
    public static func buildSAPISIDAuthHeader(
        cookieHeader: String,
        origin: String = InnerTube.origin,
        now: Date = Date()
    ) -> String? {
        let cookies = parseCookies(cookieHeader)
        let sapisid = cookies["__Secure-3PAPISID"] ?? cookies["SAPISID"]
        let sapisid1p = cookies["__Secure-1PAPISID"]
        let sapisid3p = cookies["__Secure-3PAPISID"]

        let timestamp = Int(now.timeIntervalSince1970)
        var schemes: [String] = []

        func hashToken(scheme: String, secret: String?) {
            guard let secret, !secret.isEmpty else { return }
            let input = "\(timestamp) \(secret) \(origin)"
            let digest = PluginSHA1.hex(Data(input.utf8))
            schemes.append("\(scheme) \(timestamp)_\(digest)")
        }

        hashToken(scheme: "SAPISIDHASH", secret: sapisid)
        hashToken(scheme: "SAPISID1PHASH", secret: sapisid1p)
        hashToken(scheme: "SAPISID3PHASH", secret: sapisid3p)

        return schemes.isEmpty ? nil : schemes.joined(separator: " ")
    }
}

/// Manages YouTube Music InnerTube bootstrap configuration (memory-only) and optional user session cookies.
public actor YTMusicTokenManager {
    private let transport: any HTTPTransport
    private var userAgent = InnerTube.Config().userAgent
    private var defaultClientVersion = InnerTube.Config().clientVersion
    private var logHandler: (@Sendable (PluginLogLevel, String) async -> Void)?
    private var apiChangedHandler: (@Sendable (String) async -> Void)?

    private var cachedConfig: InnerTubeClientConfig?
    private var configFetchedAt: Date?
    private var inFlightBootstrap: Task<InnerTubeClientConfig, Error>?
    private var userSession: YTMusicUserSession?
    private var sessionStorageURL: URL?

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func configureStorage(dataDirectory: String?) {
        guard let dataDirectory, !dataDirectory.isEmpty else { return }
        let url = URL(fileURLWithPath: dataDirectory, isDirectory: true)
            .appendingPathComponent("ytmusic_user_session.json")
        self.sessionStorageURL = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(YTMusicUserSession.self, from: data),
           decoded.isSignedIn {
            self.userSession = decoded
        }
    }

    public func configure(
        userAgent: String,
        defaultClientVersion: String,
        log: @escaping @Sendable (PluginLogLevel, String) async -> Void,
        onAPIChanged: @escaping @Sendable (String) async -> Void
    ) {
        self.userAgent = userAgent
        self.defaultClientVersion = defaultClientVersion
        self.logHandler = log
        self.apiChangedHandler = onAPIChanged
    }

    public func setUserSession(_ session: YTMusicUserSession?) {
        userSession = session
        persistUserSession(session)
    }

    public func clearUserSession() {
        userSession = nil
        if let url = sessionStorageURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func currentUserSession() -> YTMusicUserSession? {
        userSession
    }

    public func currentAccountStatus() -> PluginAccountStatus {
        guard let userSession, userSession.isSignedIn else {
            return PluginAccountStatus(status: "signedOut")
        }
        return PluginAccountStatus(status: "signedIn", displayName: userSession.displayName ?? "YouTube Music Web")
    }

    public func invalidateClientConfig() {
        cachedConfig = nil
        configFetchedAt = nil
    }

    /// Returns a valid InnerTube client config, refreshing `music.youtube.com` HTML at most once when stale.
    public func getClientConfig(forceRefresh: Bool = false) async throws -> InnerTubeClientConfig {
        try Task.checkCancellation()
        if forceRefresh {
            cachedConfig = nil
            configFetchedAt = nil
        }

        if let cachedConfig,
           let fetchedAt = configFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 3600 {
            return cachedConfig
        }

        if let existing = inFlightBootstrap {
            return try await existing.value
        }

        let cookie = userSession?.cookieHeader
        let ua = userAgent
        let fallbackVer = defaultClientVersion
        let task = Task<InnerTubeClientConfig, Error> {
            try await self.bootstrapConfig(userAgent: ua, cookieHeader: cookie, fallbackVersion: fallbackVer)
        }
        inFlightBootstrap = task
        do {
            let cfg = try await task.value
            inFlightBootstrap = nil
            cachedConfig = cfg
            configFetchedAt = Date()
            return cfg
        } catch {
            inFlightBootstrap = nil
            throw error
        }
    }

    public func requireUserSession() throws -> YTMusicUserSession {
        guard let userSession, userSession.isSignedIn else {
            throw PluginError(
                code: .unauthorized,
                message: "Sign in to YouTube Music in Plug-in Settings to modify your playlists."
            )
        }
        return userSession
    }

    private func bootstrapConfig(
        userAgent: String,
        cookieHeader: String?,
        fallbackVersion: String
    ) async throws -> InnerTubeClientConfig {
        let req = InnerTube.makeBootstrapRequest(userAgent: userAgent, cookieHeader: cookieHeader)
        let response = try await transport.send(req)

        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 429 {
                throw PluginError(code: .rateLimited, message: "YouTube Music is limiting requests.", retryAfterSeconds: 30)
            }
            throw PluginError(code: .network, message: "YouTube Music page returned HTTP \(response.statusCode).")
        }

        guard let html = String(data: response.body, encoding: .utf8), !html.isEmpty else {
            await reportAPIChanged("Could not decode YouTube Music HTML as UTF-8.")
            throw PluginError(code: .apiChanged, message: "YouTube Music changed how it works. Update the YouTube Music plug-in.")
        }

        do {
            return try InnerTube.extractClientConfig(fromHTML: html, fallbackClientVersion: fallbackVersion)
        } catch let err as PluginError where err.code == .apiChanged {
            await reportAPIChanged(err.message)
            throw err
        }
    }

    private func persistUserSession(_ session: YTMusicUserSession?) {
        guard let url = sessionStorageURL else { return }
        if let session, session.isSignedIn {
            do {
                let dir = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(session)
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                // Keep session in memory if persistent storage is temporarily read-only.
            }
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func reportAPIChanged(_ detail: String) async {
        await logHandler?(.error, "YouTube Music bootstrap apiChanged: \(detail)")
        await apiChangedHandler?("YouTube Music changed how it works. Update the YouTube Music plug-in.")
    }
}
