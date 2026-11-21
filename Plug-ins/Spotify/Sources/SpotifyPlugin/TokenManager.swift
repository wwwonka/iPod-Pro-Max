import Foundation
import PluginKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cross-platform HTTP response wrapper used by `TokenManager` and `Pathfinder`.
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

/// Default `URLSession.dataTask` transport supporting macOS 10.15+, Linux, and Windows with cancellation.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponseData {
        try Task.checkCancellation()
        let box = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        let ns = error as NSError
                        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: PluginError(code: .network, message: error.localizedDescription))
                        }
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: PluginError(code: .network, message: "Invalid network response from Spotify."))
                        return
                    }
                    var headers: [String: String] = [:]
                    for (k, v) in http.allHeaderFields {
                        if let ks = k as? String, let vs = v as? String {
                            headers[ks] = vs
                        }
                    }
                    continuation.resume(returning: HTTPResponseData(
                        statusCode: http.statusCode,
                        headers: headers,
                        body: data ?? Data()
                    ))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

private final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func set(_ t: URLSessionDataTask) {
        lock.lock()
        let shouldCancel = cancelled
        task = t
        lock.unlock()
        if shouldCancel { t.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

/// Short-lived anonymous session parsed from Spotify's embed page (memory only, never written to disk).
public struct EmbedSession: Equatable, Sendable {
    public var accessToken: String
    public var expiresAtMs: Int64
    public var isAnonymous: Bool

    public init(accessToken: String, expiresAtMs: Int64, isAnonymous: Bool) {
        self.accessToken = accessToken
        self.expiresAtMs = expiresAtMs
        self.isAnonymous = isAnonymous
    }
}

/// Optional authenticated Spotify Web session captured by the native login WebView or pasted manually (`sp_dc`).
public struct UserWebSession: Codable, Equatable, Sendable {
    public var spDC: String?
    public var username: String?
    public var displayName: String?
    public var accessToken: String?
    public var clientToken: String?
    public var expiresAtMs: Int64

    public init(
        spDC: String? = nil,
        username: String? = nil,
        displayName: String? = nil,
        accessToken: String? = nil,
        clientToken: String? = nil,
        expiresAtMs: Int64 = 0
    ) {
        self.spDC = spDC
        self.username = username
        self.displayName = displayName
        self.accessToken = accessToken
        self.clientToken = clientToken
        self.expiresAtMs = expiresAtMs
    }

    public var isSignedIn: Bool {
        let hasToken = !(accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasCookie = !(spDC?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return hasToken || hasCookie
    }
}

/// Manages both the in-memory anonymous embed token (`SPO-3`) and optional authenticated Web session tokens.
public actor TokenManager {
    public static let defaultBootstrapPlaylistID = "37i9dQZF1DXcBWIGoYBM5M"
    public static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private let transport: any HTTPTransport
    private var userAgent: String
    private var session: EmbedSession?
    private var userSession: UserWebSession?
    private var sessionFileURL: URL?
    private var inFlightBootstrap: Task<EmbedSession, Error>?
    private var logHandler: (@Sendable (PluginLogLevel, String) async -> Void)?
    private var apiChangedHandler: (@Sendable (String) async -> Void)?

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        userAgent: String = TokenManager.defaultUserAgent
    ) {
        self.transport = transport
        self.userAgent = userAgent
    }

    public func configure(
        userAgent: String?,
        log: (@Sendable (PluginLogLevel, String) async -> Void)?,
        onAPIChanged: (@Sendable (String) async -> Void)?
    ) {
        if let userAgent, !userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.userAgent = userAgent
        }
        self.logHandler = log
        self.apiChangedHandler = onAPIChanged
    }

    public func configureStorage(dataDirectory: String) {
        let dir = URL(fileURLWithPath: dataDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(".spotify-session.json")
        self.sessionFileURL = file
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode(UserWebSession.self, from: data),
           decoded.isSignedIn {
            self.userSession = decoded
        }
    }

    public func setUserSession(_ newSession: UserWebSession) {
        self.userSession = newSession
        persistUserSession(newSession)
    }

    public func clearUserSession() {
        self.userSession = nil
        if let sessionFileURL {
            try? FileManager.default.removeItem(at: sessionFileURL)
        }
    }

    public func currentUserSession() -> UserWebSession? {
        userSession
    }

    public func setResolvedAccountInfo(username: String?, displayName: String?) {
        guard var cur = userSession else { return }
        var changed = false
        if let username, !username.isEmpty, cur.username != username {
            cur.username = username
            changed = true
        }
        if let displayName, !displayName.isEmpty, cur.displayName != displayName {
            cur.displayName = displayName
            changed = true
        }
        if changed {
            userSession = cur
            persistUserSession(cur)
        }
    }

    public func currentAccountStatus() -> PluginAccountStatus {
        guard let userSession, userSession.isSignedIn else {
            return PluginAccountStatus(status: "signedOut")
        }
        return PluginAccountStatus(
            status: "signedIn",
            displayName: userSession.displayName?.isEmpty == false ? userSession.displayName : "Spotify Web"
        )
    }

    public func getUserWriteCredentials() throws -> (accessToken: String, clientToken: String?) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard let userSession,
              let token = userSession.accessToken,
              !token.isEmpty,
              userSession.expiresAtMs == 0 || nowMs < userSession.expiresAtMs - 30_000 else {
            throw PluginError(code: .unauthorized, message: "Spotify web session expired or not signed in.")
        }
        return (token, userSession.clientToken)
    }

    public func getPreferredAuth(preferredPlaylistID: String? = nil) async throws -> (accessToken: String, clientToken: String?, isUserToken: Bool) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if let userSession,
           let tok = userSession.accessToken,
           !tok.isEmpty,
           userSession.expiresAtMs == 0 || nowMs < userSession.expiresAtMs - 30_000 {
            return (tok, userSession.clientToken, true)
        }
        let anon = try await getToken(preferredPlaylistID: preferredPlaylistID)
        return (anon, nil, false)
    }

    public func invalidate(isUserToken: Bool) {
        if isUserToken {
            if var cur = userSession {
                cur.accessToken = nil
                cur.expiresAtMs = 0
                userSession = cur
                persistUserSession(cur)
            }
        } else {
            session = nil
        }
    }

    private func persistUserSession(_ s: UserWebSession) {
        guard let sessionFileURL,
              let data = try? JSONEncoder().encode(s) else { return }
        let dir = sessionFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: sessionFileURL, options: .atomic)
        #if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionFileURL.path)
        #endif
    }

    /// Returns a valid in-memory anonymous bearer token, bootstrapping if absent or < 60 s from expiry.
    public func getToken(preferredPlaylistID: String? = nil) async throws -> String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if let session, nowMs < session.expiresAtMs - 60_000 {
            return session.accessToken
        }

        if let existing = inFlightBootstrap {
            let refreshed = try await existing.value
            return refreshed.accessToken
        }

        let bootstrapID = preferredPlaylistID ?? Self.defaultBootstrapPlaylistID
        let ua = self.userAgent
        let transport = self.transport
        let log = self.logHandler
        let apiChanged = self.apiChangedHandler

        let task = Task<EmbedSession, Error> {
            try Task.checkCancellation()
            let urlString = "https://open.spotify.com/embed/playlist/\(bootstrapID)"
            guard let url = URL(string: urlString) else {
                throw PluginError(code: .unsupported, message: "Invalid Spotify embed URL.")
            }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

            let response = try await transport.send(request)
            if response.statusCode >= 400 {
                // If an album/private target wasn't fetchable as a playlist embed or blocked, report status HTTP code without retry loop.
                throw PluginError(
                    code: .network,
                    message: "Spotify embed page returned HTTP \(response.statusCode)."
                )
            }

            guard let html = String(data: response.body, encoding: .utf8) else {
                await log?(.error, "Spotify embed response was not valid UTF-8.")
                await apiChanged?(SpotifyMessages.apiChanged)
                throw PluginError(code: .apiChanged, message: SpotifyMessages.apiChanged)
            }

            do {
                return try Self.extractSession(fromHTML: html)
            } catch let detailError as EmbedParsingFailure {
                await log?(.error, "Embed page parse error: \(detailError.logDetail)")
                await apiChanged?(SpotifyMessages.apiChanged)
                throw PluginError(code: .apiChanged, message: SpotifyMessages.apiChanged)
            }
        }

        inFlightBootstrap = task
        do {
            let newSession = try await task.value
            self.session = newSession
            self.inFlightBootstrap = nil
            return newSession.accessToken
        } catch {
            self.inFlightBootstrap = nil
            throw error
        }
    }

    public func invalidate() {
        session = nil
    }

    // MARK: - Pure HTML/__NEXT_DATA__ Extraction

    public struct EmbedParsingFailure: Error {
        public let logDetail: String
    }

    /// Extracts anonymous `EmbedSession` from Spotify embed HTML (`<script id="__NEXT_DATA__" type="application/json">`).
    public static func extractSession(fromHTML html: String) throws -> EmbedSession {
        guard let scriptRange = html.range(of: #"<script[^>]*id="__NEXT_DATA__"[^>]*>"#, options: [.regularExpression, .caseInsensitive]) else {
            throw EmbedParsingFailure(logDetail: "Missing <script id=\"__NEXT_DATA__\"> element in embed page HTML.")
        }
        guard let closeRange = html[scriptRange.upperBound...].range(of: "</script>", options: .caseInsensitive) else {
            throw EmbedParsingFailure(logDetail: "Unterminated <script id=\"__NEXT_DATA__\"> element in embed page HTML.")
        }
        let jsonText = String(html[scriptRange.upperBound..<closeRange.lowerBound])
        guard let jsonData = jsonText.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            throw EmbedParsingFailure(logDetail: "Malformed JSON inside __NEXT_DATA__ script tag.")
        }

        guard let props = root["props"] as? [String: Any] else {
            throw EmbedParsingFailure(logDetail: "Missing JSON path 'props' in __NEXT_DATA__.")
        }
        guard let pageProps = props["pageProps"] as? [String: Any] else {
            throw EmbedParsingFailure(logDetail: "Missing JSON path 'props.pageProps' in __NEXT_DATA__.")
        }
        guard let state = pageProps["state"] as? [String: Any] else {
            throw EmbedParsingFailure(logDetail: "Missing JSON path 'props.pageProps.state' in __NEXT_DATA__.")
        }
        guard let settings = state["settings"] as? [String: Any] else {
            throw EmbedParsingFailure(logDetail: "Missing JSON path 'props.pageProps.state.settings' in __NEXT_DATA__.")
        }
        guard let session = settings["session"] as? [String: Any] else {
            throw EmbedParsingFailure(logDetail: "Missing JSON path 'props.pageProps.state.settings.session' in __NEXT_DATA__.")
        }

        guard let token = session["accessToken"] as? String, !token.isEmpty else {
            throw EmbedParsingFailure(logDetail: "Missing 'props.pageProps.state.settings.session.accessToken' in __NEXT_DATA__.")
        }

        let expiresMs: Int64
        if let n = session["accessTokenExpirationTimestampMs"] as? NSNumber {
            expiresMs = n.int64Value
        } else {
            throw EmbedParsingFailure(logDetail: "Missing 'props.pageProps.state.settings.session.accessTokenExpirationTimestampMs' in __NEXT_DATA__.")
        }

        let isAnon = (session["isAnonymous"] as? Bool) ?? true
        return EmbedSession(accessToken: token, expiresAtMs: expiresMs, isAnonymous: isAnon)
    }
}

public enum SpotifyMessages {
    public static let apiChanged = "Spotify changed how it works. Update the Spotify plug-in."
}
