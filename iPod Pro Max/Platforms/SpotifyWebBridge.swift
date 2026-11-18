import Foundation

/// Ephemeral authenticated session tokens extracted on-demand from an OS WebView for Spotify Web.
struct SpotifyWebAuthSession: Sendable {
    var spDC: String?
    var accessToken: String
    var clientToken: String?
    var expiresAtMs: Int64
    var displayName: String?
}

#if canImport(WebKit) && canImport(AppKitBackend)
import AppKit
import WebKit

/// Native macOS `WKWebView` bridge for Spotify login (interactive) and silent on-demand token refresh.
/// Zero background processes or timers at rest: hidden WebViews are created strictly on demand and torn
/// down immediately after capturing `(accessToken, clientToken)`.
@MainActor
final class SpotifyWebBridge: NSObject {
    static let shared = SpotifyWebBridge()

    private var activeLoginSession: InteractiveLoginSession?
    private var activeSilentRefreshTask: Task<SpotifyWebAuthSession?, Never>?

    var isSupportedOnPlatform: Bool { true }

    private override init() {
        super.init()
    }

    func signInInteractively() async throws -> SpotifyWebAuthSession {
        activeLoginSession?.cancel()
        let session = InteractiveLoginSession()
        activeLoginSession = session
        defer {
            if activeLoginSession === session {
                activeLoginSession = nil
            }
        }
        return try await session.run()
    }

    func cancelInteractiveSignIn() {
        activeLoginSession?.cancel()
        activeLoginSession = nil
    }

    func refreshSilently(preferredPlaylistID: String?) async -> SpotifyWebAuthSession? {
        if let existing = activeSilentRefreshTask {
            return await existing.value
        }
        let task = Task<SpotifyWebAuthSession?, Never> { @MainActor in
            let runner = SilentRefreshSession(preferredPlaylistID: preferredPlaylistID)
            return await runner.run(timeoutSeconds: 15)
        }
        activeSilentRefreshTask = task
        let result = await task.value
        activeSilentRefreshTask = nil
        return result
    }

    func signOut() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        for cookie in cookies where cookie.domain.localizedCaseInsensitiveContains("spotify") {
            await withCheckedContinuation { cont in
                store.delete(cookie) { cont.resume() }
            }
        }
    }

    func seedSpDCCookie(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let props: [HTTPCookiePropertyKey: Any] = [
            .domain: ".spotify.com",
            .path: "/",
            .name: "sp_dc",
            .value: trimmed,
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(365 * 24 * 3600),
        ]
        guard let cookie = HTTPCookie(properties: props) else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        await withCheckedContinuation { cont in
            store.setCookie(cookie) { cont.resume() }
        }
    }

    // MARK: - Shared JS Observer

    fileprivate static let handlerName = "ippmSpotify"

    /// Observes Spotify Web's own token / Pathfinder requests strictly on `open.spotify.com` (never on login/captcha pages).
    fileprivate static let observerScriptSource = """
    (function() {
      if (!window.location || window.location.hostname !== 'open.spotify.com') return;
      function send(obj) {
        try { window.webkit.messageHandlers.ippmSpotify.postMessage(obj); } catch (_) {}
      }
      function inspectHeaders(hdrs) {
        if (!hdrs) return;
        try {
          var normalized = (typeof hdrs.get === 'function') ? hdrs : (Array.isArray(hdrs) || typeof hdrs === 'object' ? new Headers(hdrs) : null);
          var auth = normalized ? normalized.get('authorization') : null;
          var ctok = normalized ? normalized.get('client-token') : null;
          if (auth && typeof auth === 'string' && auth.indexOf('Bearer ') === 0) {
            send({ kind: 'headerToken', accessToken: auth.slice(7).trim(), clientToken: ctok || null });
          } else if (ctok && typeof ctok === 'string') {
            send({ kind: 'clientToken', clientToken: ctok });
          }
        } catch (_) {}
      }
      function inspectTokenJSON(url, data) {
        if (!data || typeof data !== 'object') return;
        if (data.accessToken && (url.indexOf('/api/token') !== -1 || url.indexOf('get_access_token') !== -1 || data.accessTokenExpirationTimestampMs)) {
          send({
            kind: 'apiToken',
            accessToken: data.accessToken,
            expiresAtMs: data.accessTokenExpirationTimestampMs || 0,
            isAnonymous: !!data.isAnonymous
          });
        } else if (data.granted_token && data.granted_token.token) {
          send({ kind: 'clientToken', clientToken: data.granted_token.token });
        }
        try {
          var profile = (data.data && data.data.me && data.data.me.profile)
            || (data.data && data.data.currentUser && data.data.currentUser.profile);
          var uname = (profile && (profile.name || profile.username))
            || (url.indexOf('/v1/me') !== -1 ? (data.display_name || data.id) : null);
          if (!uname && profile && typeof profile.uri === 'string') {
            var um = profile.uri.match(/^spotify:user:([^:]+)$/);
            if (um && um[1]) uname = um[1];
          }
          if (uname && typeof uname === 'string') {
            send({ kind: 'username', username: uname });
          }
        } catch (_) {}
      }
      function readSessionElements() {
        try {
          var ids = ['session', 'appServerConfig', 'config'];
          for (var i = 0; i < ids.length; i++) {
            var el = document.getElementById(ids[i]);
            if (el && el.textContent) {
              try {
                var parsed = JSON.parse(el.textContent);
                if (parsed && parsed.accessToken) {
                  send({
                    kind: 'apiToken',
                    accessToken: parsed.accessToken,
                    expiresAtMs: parsed.accessTokenExpirationTimestampMs || 0,
                    isAnonymous: !!parsed.isAnonymous
                  });
                }
                var prof = parsed && (parsed.profile || parsed.user || parsed);
                var uname = prof && (prof.displayName || prof.name || prof.username);
                if (uname && typeof uname === 'string') {
                  send({ kind: 'username', username: uname });
                }
              } catch (_) {}
            }
          }
          var link = document.querySelector('[data-testid="user-widget-link"], a[href*="/user/"]');
          if (link) {
            var label = link.getAttribute('aria-label') || link.getAttribute('title') || '';
            if (!label) {
              var fig = link.querySelector('figure[title], img[alt]');
              if (fig) label = fig.getAttribute('title') || fig.getAttribute('alt') || '';
            }
            if (!label) {
              var href = link.getAttribute('href') || '';
              var m = href.match(/\\/user\\/([^/?#]+)/);
              if (m && m[1]) label = decodeURIComponent(m[1]);
            }
            if (label && label.trim()) {
              send({ kind: 'username', username: label.trim() });
            }
          }
        } catch (_) {}
      }
      if (!window.__ippmHooked) {
        window.__ippmHooked = true;
        var origFetch = window.fetch;
        if (typeof origFetch === 'function') {
          window.fetch = function(input, init) {
            try {
              var url = (typeof input === 'string') ? input : (input && input.url ? input.url : '');
              if (init && init.headers) inspectHeaders(init.headers);
              if (input && input.headers) inspectHeaders(input.headers);
              var p = origFetch.apply(this, arguments);
              if (url && (url.indexOf('/api/token') !== -1 || url.indexOf('get_access_token') !== -1 || url.indexOf('clienttoken.spotify.com') !== -1 || url.indexOf('pathfinder') !== -1 || url.indexOf('/v1/me') !== -1)) {
                p.then(function(resp) {
                  try {
                    resp.clone().json().then(function(data) {
                      inspectTokenJSON(url, data);
                    }).catch(function(){});
                  } catch (_) {}
                }).catch(function(){});
              }
              return p;
            } catch (_) {
              return origFetch.apply(this, arguments);
            }
          };
        }
        if (window.XMLHttpRequest && window.XMLHttpRequest.prototype) {
          var origOpen = window.XMLHttpRequest.prototype.open;
          var origSetHeader = window.XMLHttpRequest.prototype.setRequestHeader;
          var origSend = window.XMLHttpRequest.prototype.send;
          window.XMLHttpRequest.prototype.open = function(method, url) {
            this.__ippmUrl = (typeof url === 'string') ? url : '';
            this.__ippmHeaders = {};
            return origOpen.apply(this, arguments);
          };
          window.XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
            try {
              if (!this.__ippmHeaders) this.__ippmHeaders = {};
              if (name) this.__ippmHeaders[String(name).toLowerCase()] = value;
            } catch (_) {}
            return origSetHeader.apply(this, arguments);
          };
          window.XMLHttpRequest.prototype.send = function() {
            try {
              if (this.__ippmHeaders) inspectHeaders(this.__ippmHeaders);
              var xhrUrl = this.__ippmUrl || '';
              if (xhrUrl.indexOf('/api/token') !== -1 || xhrUrl.indexOf('get_access_token') !== -1 || xhrUrl.indexOf('clienttoken.spotify.com') !== -1) {
                this.addEventListener('load', function() {
                  try {
                    var parsed = (typeof this.response === 'object' && this.response) ? this.response : JSON.parse(this.responseText || '{}');
                    inspectTokenJSON(xhrUrl, parsed);
                  } catch (_) {}
                });
              }
            } catch (_) {}
            return origSend.apply(this, arguments);
          };
        }
        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', readSessionElements);
        }
      }
      readSessionElements();
    })();
    """

    fileprivate static func makeConfiguredWebView(frame: NSRect, messageHandler: WKScriptMessageHandler) -> WKWebView {
        let contentController = WKUserContentController()
        let userScript = WKUserScript(source: observerScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        contentController.addUserScript(userScript)
        let endScript = WKUserScript(source: observerScriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        contentController.addUserScript(endScript)
        contentController.add(messageHandler, name: handlerName)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController = contentController
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Use authentic Safari/WebKit UA matching the WKWebView JS engine (do NOT spoof Chrome on WebKit).
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let webView = WKWebView(frame: frame, configuration: config)
        return webView
    }

    fileprivate static func readSpDCCookie() async -> String? {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        return cookies.first(where: {
            $0.name == "sp_dc" && $0.domain.localizedCaseInsensitiveContains("spotify") && !$0.value.isEmpty
        })?.value
    }

    fileprivate static func probeOpenPage(_ webView: WKWebView) async -> (accessToken: String?, expiresAtMs: Int64, isAnonymous: Bool, username: String?)? {
        guard let host = webView.url?.host?.lowercased(), host.hasSuffix("open.spotify.com") else {
            return nil
        }
        let js = """
        (function(){
          var out = {};
          var ids = ['session', 'appServerConfig', 'config'];
          for (var i = 0; i < ids.length; i++) {
            var el = document.getElementById(ids[i]);
            if (el && el.textContent) {
              try {
                var p = JSON.parse(el.textContent);
                if (p && p.accessToken) {
                  out.accessToken = p.accessToken;
                  out.expiresAtMs = p.accessTokenExpirationTimestampMs || 0;
                  out.isAnonymous = !!p.isAnonymous;
                }
                var prof = p && (p.profile || p.user || p);
                var u = prof && (prof.displayName || prof.name || prof.username);
                if (u && typeof u === 'string') out.username = u;
              } catch (_) {}
            }
          }
          var link = document.querySelector('[data-testid="user-widget-link"], a[href*="/user/"]');
          if (link) {
            var label = link.getAttribute('aria-label') || link.getAttribute('title') || '';
            if (!label) {
              var fig = link.querySelector('figure[title], img[alt]');
              if (fig) label = fig.getAttribute('title') || fig.getAttribute('alt') || '';
            }
            if (!label) {
              var href = link.getAttribute('href') || '';
              var m = href.match(/\\/user\\/([^/?#]+)/);
              if (m && m[1]) label = decodeURIComponent(m[1]);
            }
            if (label && label.trim()) out.username = label.trim();
          }
          return (out.accessToken || out.username) ? out : null;
        })();
        """
        guard let result = try? await webView.evaluateJavaScript(js) as? [String: Any] else { return nil }
        return (
            accessToken: result["accessToken"] as? String,
            expiresAtMs: (result["expiresAtMs"] as? NSNumber)?.int64Value ?? 0,
            isAnonymous: (result["isAnonymous"] as? Bool) ?? true,
            username: (result["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - Interactive Login Window

@MainActor
private final class InteractiveLoginSession: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<SpotifyWebAuthSession, Error>?

    private var capturedAccessToken: String?
    private var capturedClientToken: String?
    private var capturedUsername: String?
    private var capturedExpiresAtMs: Int64 = 0
    private var isAnonymousToken = true
    private var hasHeaderToken = false
    private var isFinishing = false

    func run() async throws -> SpotifyWebAuthSession {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let webView = SpotifyWebBridge.makeConfiguredWebView(
                frame: NSRect(x: 0, y: 0, width: 480, height: 680),
                messageHandler: self
            )
            webView.navigationDelegate = self
            webView.uiDelegate = self
            self.webView = webView

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Sign in to Spotify"
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            window.contentView = webView
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.window = window

            if let url = URL(string: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F") {
                webView.load(URLRequest(url: url))
            }
        }
    }

    func cancel() {
        finish(throwing: CancellationError())
    }

    func windowWillClose(_ notification: Notification) {
        if !isFinishing {
            finish(throwing: CancellationError())
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }

        switch kind {
        case "apiToken":
            let anon = (body["isAnonymous"] as? Bool) ?? true
            if !anon, let tok = body["accessToken"] as? String, !tok.isEmpty {
                capturedAccessToken = tok
                isAnonymousToken = false
                if let exp = (body["expiresAtMs"] as? NSNumber)?.int64Value, exp > 0 {
                    capturedExpiresAtMs = exp
                }
            }
        case "headerToken":
            if let tok = body["accessToken"] as? String, !tok.isEmpty {
                capturedAccessToken = tok
                hasHeaderToken = true
            }
            if let ct = body["clientToken"] as? String, !ct.isEmpty {
                capturedClientToken = ct
            }
        case "clientToken":
            if let ct = body["clientToken"] as? String, !ct.isEmpty {
                capturedClientToken = ct
            }
        case "username":
            if let uname = body["username"] as? String, !uname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                capturedUsername = uname.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        default:
            break
        }
        Task { await self.tryCompleteIfReady() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            for delayNs: UInt64 in [0, 350_000_000, 600_000_000, 1_000_000_000] {
                if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
                guard !self.isFinishing else { return }
                await self.probeSessionScriptIfNeeded()
                await self.tryCompleteIfReady()
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    private func probeSessionScriptIfNeeded() async {
        guard !isFinishing, let webView,
              let probed = await SpotifyWebBridge.probeOpenPage(webView) else { return }
        if let tok = probed.accessToken, !tok.isEmpty, !probed.isAnonymous {
            capturedAccessToken = tok
            isAnonymousToken = false
            if probed.expiresAtMs > 0 {
                capturedExpiresAtMs = probed.expiresAtMs
            }
        }
        if let uname = probed.username, !uname.isEmpty {
            capturedUsername = uname
        }
    }

    private func tryCompleteIfReady() async {
        guard !isFinishing else { return }
        guard let host = webView?.url?.host?.lowercased(), host.hasSuffix("open.spotify.com") else { return }
        guard let spDC = await SpotifyWebBridge.readSpDCCookie(), !spDC.isEmpty else { return }
        if isAnonymousToken && hasHeaderToken {
            isAnonymousToken = false
        }
        if isAnonymousToken || capturedAccessToken == nil || capturedUsername == nil {
            await probeSessionScriptIfNeeded()
        }
        guard !isAnonymousToken, let accessToken = capturedAccessToken, !accessToken.isEmpty else {
            return
        }
        // Give Spotify Web up to 600 ms to also emit its `client-token` and user handle if not yet received.
        if capturedClientToken == nil || capturedUsername == nil {
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        if capturedUsername == nil {
            await probeSessionScriptIfNeeded()
        }
        guard !isFinishing else { return }
        finish(returning: SpotifyWebAuthSession(
            spDC: spDC,
            accessToken: accessToken,
            clientToken: capturedClientToken,
            expiresAtMs: capturedExpiresAtMs,
            displayName: capturedUsername
        ))
    }

    private func finish(returning value: SpotifyWebAuthSession) {
        guard !isFinishing else { return }
        isFinishing = true
        teardown()
        continuation?.resume(returning: value)
        continuation = nil
    }

    private func finish(throwing error: Error) {
        guard !isFinishing else { return }
        isFinishing = true
        teardown()
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func teardown() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: SpotifyWebBridge.handlerName)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }
}

// MARK: - Hidden On-Demand Token Refresh

@MainActor
private final class SilentRefreshSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let preferredPlaylistID: String?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<SpotifyWebAuthSession?, Never>?

    private var capturedAccessToken: String?
    private var capturedClientToken: String?
    private var capturedUsername: String?
    private var capturedExpiresAtMs: Int64 = 0
    private var isAnonymousToken = true
    private var spDCCache: String?
    private var isFinished = false

    init(preferredPlaylistID: String?) {
        self.preferredPlaylistID = preferredPlaylistID
        super.init()
    }

    func run(timeoutSeconds: Double) async -> SpotifyWebAuthSession? {
        guard let spDC = await SpotifyWebBridge.readSpDCCookie(), !spDC.isEmpty else {
            return nil
        }
        self.spDCCache = spDC

        return await withTaskGroup(of: SpotifyWebAuthSession?.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { cont in
                    self.continuation = cont
                    let webView = SpotifyWebBridge.makeConfiguredWebView(
                        frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
                        messageHandler: self
                    )
                    webView.navigationDelegate = self
                    self.webView = webView

                    let path = self.preferredPlaylistID.map { "playlist/\($0)" } ?? ""
                    if let url = URL(string: "https://open.spotify.com/\(path)") {
                        webView.load(URLRequest(url: url))
                    } else {
                        self.complete(with: nil)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            await MainActor.run {
                self.complete(with: first)
            }
            return first
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }

        switch kind {
        case "apiToken":
            let anon = (body["isAnonymous"] as? Bool) ?? true
            if !anon, let tok = body["accessToken"] as? String, !tok.isEmpty {
                capturedAccessToken = tok
                isAnonymousToken = false
                if let exp = (body["expiresAtMs"] as? NSNumber)?.int64Value, exp > 0 {
                    capturedExpiresAtMs = exp
                }
            }
        case "headerToken":
            if let tok = body["accessToken"] as? String, !tok.isEmpty {
                capturedAccessToken = tok
                if spDCCache != nil { isAnonymousToken = false }
            }
            if let ct = body["clientToken"] as? String, !ct.isEmpty {
                capturedClientToken = ct
            }
        case "clientToken":
            if let ct = body["clientToken"] as? String, !ct.isEmpty {
                capturedClientToken = ct
            }
        case "username":
            if let uname = body["username"] as? String, !uname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                capturedUsername = uname.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        default:
            break
        }

        if !isAnonymousToken, let tok = capturedAccessToken, !tok.isEmpty, capturedClientToken != nil, capturedUsername != nil {
            complete(with: SpotifyWebAuthSession(
                spDC: spDCCache,
                accessToken: tok,
                clientToken: capturedClientToken,
                expiresAtMs: capturedExpiresAtMs,
                displayName: capturedUsername
            ))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isFinished else { return }
        if let host = webView.url?.host?.lowercased(), host.contains("accounts.spotify.com") {
            // Session cookie expired; stop silently without popping UI.
            complete(with: nil)
            return
        }
        Task {
            for delayNs: UInt64 in [400_000_000, 600_000_000, 800_000_000] {
                try? await Task.sleep(nanoseconds: delayNs)
                guard !self.isFinished else { return }
                await self.probeUsernameIfNeeded(in: webView)
                if !self.isAnonymousToken, let tok = self.capturedAccessToken, !tok.isEmpty,
                   (self.capturedUsername != nil || delayNs == 800_000_000) {
                    self.complete(with: SpotifyWebAuthSession(
                        spDC: self.spDCCache,
                        accessToken: tok,
                        clientToken: self.capturedClientToken,
                        expiresAtMs: self.capturedExpiresAtMs,
                        displayName: self.capturedUsername
                    ))
                    return
                }
            }
        }
    }

    private func probeUsernameIfNeeded(in webView: WKWebView) async {
        guard let probed = await SpotifyWebBridge.probeOpenPage(webView) else { return }
        if let uname = probed.username, !uname.isEmpty {
            capturedUsername = uname
        }
    }

    private func complete(with result: SpotifyWebAuthSession?) {
        guard !isFinished else { return }
        isFinished = true
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: SpotifyWebBridge.handlerName)
        webView?.navigationDelegate = nil
        webView = nil
        continuation?.resume(returning: result)
        continuation = nil
    }
}

#else

/// Non-macOS fallback: plug-in still works with manual `sp_dc` or OAuth external open.
@MainActor
final class SpotifyWebBridge {
    static let shared = SpotifyWebBridge()
    var isSupportedOnPlatform: Bool { false }
    private init() {}

    func signInInteractively() async throws -> SpotifyWebAuthSession {
        throw NSError(domain: "SpotifyWebBridge", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Paste your Spotify 'sp_dc' cookie or sign in on macOS.",
        ])
    }

    func cancelInteractiveSignIn() {}

    func refreshSilently(preferredPlaylistID: String?) async -> SpotifyWebAuthSession? {
        nil
    }

    func seedSpDCCookie(_ value: String) async {}

    func signOut() async {}
}

#endif
