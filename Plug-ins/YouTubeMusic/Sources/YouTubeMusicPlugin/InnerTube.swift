import Foundation
import PluginKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// InnerTube (`WEB_REMIX`) endpoint definitions, `ytcfg` extraction, and signed request builders for YouTube Music.
public enum InnerTube {
    public static let origin = "https://music.youtube.com"
    public static let apiBase = "https://music.youtube.com/youtubei/v1"
    public static let uploadURL = "https://music.youtube.com/playlist_image_upload/playlist_custom_thumbnail"
    public static let maxPages = 100
    public static let songsSearchParams = "EgWKAQIIAWoKEAMQBBAJEAoQBQ%3D%3D"

    public struct Config: Sendable, Equatable {
        public var userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        public var clientVersion = "1.20261117.06.00"

        public init() {}

        public static func from(initializeConfig: [String: JSONValue]) -> Config {
            var cfg = Config()
            if let ua = initializeConfig["userAgent"]?.stringValue, !ua.isEmpty {
                cfg.userAgent = ua
            }
            if let cv = initializeConfig["clientVersion"]?.stringValue, !cv.isEmpty {
                cfg.clientVersion = cv
            }
            return cfg
        }
    }

    // MARK: - ytcfg Extraction

    /// Extracts `INNERTUBE_API_KEY`, `INNERTUBE_CLIENT_VERSION`, `VISITOR_DATA`, `SESSION_INDEX`, `DELEGATED_SESSION_ID`, and `LOGGED_IN` from `music.youtube.com` HTML.
    public static func extractClientConfig(fromHTML html: String, fallbackClientVersion: String) throws -> InnerTubeClientConfig {
        if let jsonObj = extractYTCfgObject(fromHTML: html),
           let apiKey = jsonObj["INNERTUBE_API_KEY"] as? String, !apiKey.isEmpty {
            let clientVersion = (jsonObj["INNERTUBE_CLIENT_VERSION"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? fallbackClientVersion
            let visitorData = (jsonObj["VISITOR_DATA"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let sessionIndex: String? = {
                if let s = jsonObj["SESSION_INDEX"] as? String, !s.isEmpty { return s }
                if let n = jsonObj["SESSION_INDEX"] as? NSNumber { return n.stringValue }
                return nil
            }()
            let delegatedSessionID = extractDelegatedSessionID(
                direct: jsonObj["DELEGATED_SESSION_ID"] as? String,
                datasyncID: jsonObj["DATASYNC_ID"] as? String
            )
            let loggedIn = jsonObj["LOGGED_IN"] as? Bool
            return InnerTubeClientConfig(
                apiKey: apiKey,
                clientVersion: clientVersion,
                visitorData: visitorData,
                sessionIndex: sessionIndex,
                delegatedSessionID: delegatedSessionID,
                loggedIn: loggedIn
            )
        }

        // Fallback key lookup if YouTube restructures ytcfg.set(...) call wrapping.
        if let apiKey = firstRegexCapture(in: html, pattern: #""INNERTUBE_API_KEY"\s*:\s*"([^"]+)""#), !apiKey.isEmpty {
            let clientVersion = firstRegexCapture(in: html, pattern: #""INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)""#)
                ?? fallbackClientVersion
            let visitorData = firstRegexCapture(in: html, pattern: #""VISITOR_DATA"\s*:\s*"([^"]+)""#)
            let sessionIndex = firstRegexCapture(in: html, pattern: #""SESSION_INDEX"\s*:\s*"?(\d+)"?"#)
            let delegatedSessionID = extractDelegatedSessionID(
                direct: firstRegexCapture(in: html, pattern: #""DELEGATED_SESSION_ID"\s*:\s*"([^"]+)""#),
                datasyncID: firstRegexCapture(in: html, pattern: #""DATASYNC_ID"\s*:\s*"([^"]+)""#)
            )
            let loggedIn = firstRegexCapture(in: html, pattern: #""LOGGED_IN"\s*:\s*(true|false)"#).map { $0 == "true" }
            return InnerTubeClientConfig(
                apiKey: apiKey,
                clientVersion: clientVersion,
                visitorData: visitorData,
                sessionIndex: sessionIndex,
                delegatedSessionID: delegatedSessionID,
                loggedIn: loggedIn
            )
        }

        throw PluginError(code: .apiChanged, message: "Missing INNERTUBE_API_KEY in YouTube Music page.")
    }

    private static func extractDelegatedSessionID(direct: String?, datasyncID: String?) -> String? {
        if let direct = direct?.trimmingCharacters(in: .whitespacesAndNewlines), !direct.isEmpty {
            return direct
        }
        if let datasyncID = datasyncID?.trimmingCharacters(in: .whitespacesAndNewlines),
           let range = datasyncID.range(of: "||") {
            let pageID = String(datasyncID[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let gaiaID = String(datasyncID[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !pageID.isEmpty && !gaiaID.isEmpty && pageID != gaiaID {
                return pageID
            }
        }
        return nil
    }

    private static func extractYTCfgObject(fromHTML html: String) -> [String: Any]? {
        var searchRange = html.startIndex..<html.endIndex
        while let marker = html.range(of: "ytcfg.set(", range: searchRange) {
            var idx = marker.upperBound
            while idx < html.endIndex && html[idx].isWhitespace {
                idx = html.index(after: idx)
            }
            if idx < html.endIndex, html[idx] == "{",
               let objectSlice = balancedJSONSlice(in: html, from: idx),
               let data = objectSlice.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               json["INNERTUBE_API_KEY"] != nil {
                return json
            }
            searchRange = marker.upperBound..<html.endIndex
        }
        return nil
    }

    private static func balancedJSONSlice(in text: String, from start: String.Index) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...idx])
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private static func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    // MARK: - Requests

    public static func makeBootstrapRequest(userAgent: String, cookieHeader: String?) -> URLRequest {
        makeBrowsePageRequest(path: "/", userAgent: userAgent, cookieHeader: cookieHeader)
    }

    public static func makeBrowsePageRequest(
        path: String,
        userAgent: String,
        cookieHeader: String?,
        authUser: String? = nil,
        delegatedSessionID: String? = nil
    ) -> URLRequest {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let urlString = normalizedPath == "/" ? origin : "\(origin)\(normalizedPath)"
        let url = URL(string: urlString) ?? URL(string: origin)!
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let cookieHeader, !cookieHeader.isEmpty {
            req.httpShouldHandleCookies = false
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let authUser, !authUser.isEmpty {
            req.setValue(authUser, forHTTPHeaderField: "X-Goog-AuthUser")
        }
        if let delegatedSessionID, !delegatedSessionID.isEmpty {
            req.setValue(delegatedSessionID, forHTTPHeaderField: "X-Goog-PageId")
        }
        return req
    }

    public static func clientContext(clientConfig: InnerTubeClientConfig, session: YTMusicUserSession? = nil) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": "WEB_REMIX",
            "clientVersion": clientConfig.clientVersion,
            "hl": "en",
            "gl": "US",
        ]
        if let visitorData = clientConfig.visitorData, !visitorData.isEmpty {
            client["visitorData"] = visitorData
        }
        var ctx: [String: Any] = ["client": client]
        if let pageID = resolvedDelegatedPageID(session: session, clientConfig: clientConfig) {
            ctx["user"] = ["onBehalfOfUser": pageID]
        }
        return ctx
    }

    public static func makeAPIRequest(
        endpoint: String,
        payload: [String: Any],
        clientConfig: InnerTubeClientConfig,
        userAgent: String,
        session: YTMusicUserSession?
    ) -> URLRequest? {
        var components = URLComponents(string: "\(apiBase)/\(endpoint)")
        components?.queryItems = [
            URLQueryItem(name: "key", value: clientConfig.apiKey),
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        guard let url = components?.url else { return nil }

        var bodyDict = payload
        bodyDict["context"] = clientContext(clientConfig: clientConfig, session: session)
        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(clientConfig.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue(origin, forHTTPHeaderField: "X-Origin")
        req.setValue("\(origin)/", forHTTPHeaderField: "Referer")
        if let visitorData = clientConfig.visitorData, !visitorData.isEmpty {
            req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        applyAuthHeaders(to: &req, session: session, clientConfig: clientConfig)
        return req
    }

    public static func makeUploadStartRequest(
        byteCount: Int,
        filename: String = "cover.jpg",
        clientConfig: InnerTubeClientConfig,
        userAgent: String,
        session: YTMusicUserSession
    ) -> URLRequest? {
        guard let url = URL(string: uploadURL) else { return nil }
        let meta = ["filename": filename]
        let metaData = (try? JSONSerialization.data(withJSONObject: meta)) ?? Data()

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.httpBody = metaData
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue(origin, forHTTPHeaderField: "X-Origin")
        req.setValue("\(origin)/", forHTTPHeaderField: "Referer")
        req.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        req.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        req.setValue("\(byteCount)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        req.setValue("image/jpeg", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        req.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(clientConfig.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        applyAuthHeaders(to: &req, session: session, clientConfig: clientConfig)
        return req
    }

    public static func makeUploadFinalizeRequest(
        uploadSessionURL: URL,
        jpegData: Data,
        userAgent: String,
        session: YTMusicUserSession,
        clientConfig: InnerTubeClientConfig? = nil
    ) -> URLRequest {
        var req = URLRequest(url: uploadSessionURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.httpBody = jpegData
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue(origin, forHTTPHeaderField: "X-Origin")
        req.setValue("\(origin)/", forHTTPHeaderField: "Referer")
        req.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        req.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        applyAuthHeaders(to: &req, session: session, clientConfig: clientConfig)
        return req
    }

    private static func resolvedDelegatedPageID(session: YTMusicUserSession?, clientConfig: InnerTubeClientConfig?) -> String? {
        if let cfgID = clientConfig?.delegatedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !cfgID.isEmpty {
            return cfgID
        }
        if let sessID = session?.delegatedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessID.isEmpty {
            return sessID
        }
        return nil
    }

    private static func applyAuthHeaders(
        to req: inout URLRequest,
        session: YTMusicUserSession?,
        clientConfig: InnerTubeClientConfig?
    ) {
        guard let session, session.isSignedIn, let cookieHeader = session.cookieHeader else { return }
        req.httpShouldHandleCookies = false
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if let auth = session.authorizationHeader(origin: origin) {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let resolvedAuthUser = (session.authUser?.isEmpty == false ? session.authUser : nil)
            ?? (clientConfig?.sessionIndex?.isEmpty == false ? clientConfig?.sessionIndex : nil)
            ?? "0"
        req.setValue(resolvedAuthUser, forHTTPHeaderField: "X-Goog-AuthUser")
        if let pageID = resolvedDelegatedPageID(session: session, clientConfig: clientConfig) {
            req.setValue(pageID, forHTTPHeaderField: "X-Goog-PageId")
        }
    }
}
