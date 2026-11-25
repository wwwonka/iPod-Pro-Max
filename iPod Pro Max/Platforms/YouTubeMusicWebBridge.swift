import Foundation

/// Ephemeral authenticated cookie session extracted on-demand from an OS WebView for YouTube Music.
struct YouTubeMusicWebAuthSession: Sendable {
    var cookieHeader: String
    var displayName: String?
    var authUser: String?
    var delegatedSessionID: String? = nil
}

#if canImport(WebKit) && canImport(AppKitBackend)
import AppKit
import WebKit

/// Native macOS `WKWebView` bridge for YouTube Music login (interactive) and silent on-demand cookie refresh.
/// Zero background processes or timers at rest: hidden WebViews are created strictly on demand and torn down
/// immediately once YouTube Music authentication cookies (`SAPISID` / `__Secure-3PAPISID`) are captured.
@MainActor
final class YouTubeMusicWebBridge: NSObject {
    static let shared = YouTubeMusicWebBridge()

    private var activeLoginSession: YTInteractiveLoginSession?
    private var activeSilentRefreshTask: Task<YouTubeMusicWebAuthSession?, Never>?

    var isSupportedOnPlatform: Bool { true }

    private override init() {
        super.init()
    }

    func signInInteractively() async throws -> YouTubeMusicWebAuthSession {
        activeLoginSession?.cancel()
        let session = YTInteractiveLoginSession()
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

    func refreshSilently() async -> YouTubeMusicWebAuthSession? {
        if let existing = activeSilentRefreshTask {
            return await existing.value
        }
        let task = Task<YouTubeMusicWebAuthSession?, Never> { @MainActor in
            let runner = YTSilentRefreshSession()
            return await runner.run(timeoutSeconds: 15)
        }
        activeSilentRefreshTask = task
        let result = await task.value
        activeSilentRefreshTask = nil
        return result
    }

    func signOut() async {
        await Self.clearGoogleAndYouTubeWebsiteData()
    }

    static func clearGoogleAndYouTubeWebsiteData() async {
        let dataStore = WKWebsiteDataStore.default()
        let cookieStore = dataStore.httpCookieStore
        let cookies = await withCheckedContinuation { cont in
            cookieStore.getAllCookies { cont.resume(returning: $0) }
        }
        for cookie in cookies {
            let dom = cookie.domain.lowercased()
            if dom.contains("youtube") || dom.contains("google") || dom.contains("youtu.be") {
                await withCheckedContinuation { cont in
                    cookieStore.delete(cookie) { cont.resume() }
                }
            }
        }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { cont in
            dataStore.fetchDataRecords(ofTypes: types) { cont.resume(returning: $0) }
        }
        let targetRecords = records.filter { rec in
            let name = rec.displayName.lowercased()
            return name.contains("youtube") || name.contains("google")
        }
        if !targetRecords.isEmpty {
            await withCheckedContinuation { cont in
                dataStore.removeData(ofTypes: types, for: targetRecords) { cont.resume() }
            }
        }
    }

    func seedCookies(fromHeader header: String) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cleaned = header.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "; ")
        for pair in cleaned.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty, !name.hasPrefix("__Host-") else { continue }
            // Only seed onto `.youtube.com` so `accounts.google.com` auth cookies are never corrupted.
            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: ".youtube.com",
                .path: "/",
                .name: name,
                .value: value,
                .expires: Date().addingTimeInterval(365 * 24 * 3600),
            ]
            if name.hasPrefix("__Secure-") {
                props[.secure] = "TRUE"
            }
            if let cookie = HTTPCookie(properties: props) {
                await withCheckedContinuation { cont in
                    store.setCookie(cookie) { cont.resume() }
                }
            }
        }
    }

    static func readCookieSessionFromStore() async -> (cookieHeader: String, hasAuth: Bool) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        var byName: [String: String] = [:]
        for cookie in cookies {
            let dom = cookie.domain.lowercased()
            let matches = dom == "youtube.com" || dom.hasSuffix(".youtube.com") || dom == "google.com" || dom.hasSuffix(".google.com")
            guard matches, !cookie.value.isEmpty else { continue }
            if byName[cookie.name] == nil || dom.contains("youtube.com") {
                byName[cookie.name] = cookie.value
            }
        }
        let hasAuth = !(byName["__Secure-3PAPISID"]?.isEmpty ?? true)
            || !(byName["SAPISID"]?.isEmpty ?? true)
            || !(byName["__Secure-1PAPISID"]?.isEmpty ?? true)
        let header = byName.keys.sorted().compactMap { name in
            byName[name].map { "\(name)=\($0)" }
        }.joined(separator: "; ")
        return (header, hasAuth)
    }

    fileprivate static func makeConfiguredWebView(frame: NSRect) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        return WKWebView(frame: frame, configuration: config)
    }

    fileprivate static func probePage(_ webView: WKWebView) async -> (loggedIn: Bool, authUser: String?, delegatedSessionID: String?, displayName: String?)? {
        guard let host = webView.url?.host?.lowercased(), host.hasSuffix("music.youtube.com") else {
            return nil
        }
        let js = """
        (function(){
          var out = { loggedIn: false };
          if (window.ytcfg && typeof window.ytcfg.get === 'function') {
            out.loggedIn = !!window.ytcfg.get('LOGGED_IN');
            var idx = window.ytcfg.get('SESSION_INDEX');
            if (idx !== undefined && idx !== null) out.authUser = String(idx);
            var del = window.ytcfg.get('DELEGATED_SESSION_ID');
            if (typeof del === 'string' && del.length > 0) out.delegatedSessionID = del;
            var accName = window.ytcfg.get('ACCOUNT_NAME');
            if (typeof accName === 'string' && accName.trim().length > 0) out.displayName = accName.trim();
          }
          if (!out.displayName) {
            var avatar = document.querySelector('#button img#img, ytmusic-nav-bar img#img, tp-yt-paper-icon-button[aria-label], button#avatar-btn');
            var candidate = (avatar && avatar.getAttribute && (avatar.getAttribute('alt') || avatar.getAttribute('aria-label'))) || '';
            if (candidate && candidate !== 'Avatar image' && candidate !== 'Settings' && candidate !== 'Sign in') {
              out.displayName = candidate;
            }
          }
          return out;
        })();
        """
        guard let dict = try? await webView.evaluateJavaScript(js) as? [String: Any] else { return nil }
        return (
            loggedIn: (dict["loggedIn"] as? Bool) ?? false,
            authUser: dict["authUser"] as? String,
            delegatedSessionID: (dict["delegatedSessionID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: (dict["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - Interactive Login Window

@MainActor
private final class YTInteractiveLoginSession: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<YouTubeMusicWebAuthSession, Error>?
    private var isFinishing = false

    func run() async throws -> YouTubeMusicWebAuthSession {
        // Clear any stale/conflicting Google & YouTube cookies so `accounts.google.com` CheckCookie succeeds cleanly.
        await YouTubeMusicWebBridge.clearGoogleAndYouTubeWebsiteData()
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let webView = YouTubeMusicWebBridge.makeConfiguredWebView(
                frame: NSRect(x: 0, y: 0, width: 480, height: 680)
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
            window.title = "Sign in to YouTube Music"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.delegate = self
            window.contentView = webView
            window.center()
            window.orderFrontRegardless()
            self.window = window

            let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26hl%3Den%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F&hl=en")!
            webView.load(URLRequest(url: loginURL))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func cancel() {
        finish(with: .failure(CancellationError()))
    }

    func windowWillClose(_ notification: Notification) {
        if !isFinishing {
            finish(with: .failure(NSError(domain: "YouTubeMusicWebBridge", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Sign in cancelled."
            ])))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let host = webView.url?.host?.lowercased(), host.hasSuffix("music.youtube.com") else { return }
        Task { @MainActor [weak self] in
            for delayNs: UInt64 in [0, 350_000_000, 800_000_000] {
                if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
                guard let self, !self.isFinishing else { return }
                let probe = await YouTubeMusicWebBridge.probePage(webView)
                let storeCookies = await YouTubeMusicWebBridge.readCookieSessionFromStore()
                guard storeCookies.hasAuth && (probe?.loggedIn ?? true) else { continue }
                self.finish(with: .success(YouTubeMusicWebAuthSession(
                    cookieHeader: storeCookies.cookieHeader,
                    displayName: probe?.displayName,
                    authUser: probe?.authUser,
                    delegatedSessionID: probe?.delegatedSessionID
                )))
                return
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private func finish(with result: Result<YouTubeMusicWebAuthSession, Error>) {
        guard !isFinishing else { return }
        isFinishing = true
        let cont = continuation
        continuation = nil

        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        window?.delegate = nil
        window?.close()
        window = nil

        cont?.resume(with: result)
    }
}

// MARK: - Silent Background Refresh

@MainActor
private final class YTSilentRefreshSession: NSObject, WKNavigationDelegate {
    private var hostWindow: NSWindow?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<YouTubeMusicWebAuthSession?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isFinishing = false

    func run(timeoutSeconds: Double) async -> YouTubeMusicWebAuthSession? {
        let current = await YouTubeMusicWebBridge.readCookieSessionFromStore()
        guard current.hasAuth else { return nil }

        return await withCheckedContinuation { cont in
            self.continuation = cont
            let webView = YouTubeMusicWebBridge.makeConfiguredWebView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600)
            )
            webView.navigationDelegate = self
            let offscreen = NSWindow(
                contentRect: NSRect(x: -4000, y: -4000, width: 800, height: 600),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            offscreen.isReleasedWhenClosed = false
            offscreen.alphaValue = 0
            offscreen.ignoresMouseEvents = true
            offscreen.contentView = webView
            offscreen.orderBack(nil)
            self.hostWindow = offscreen
            self.webView = webView

            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                self?.finish(with: nil)
            }

            webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let host = webView.url?.host?.lowercased(), host.hasSuffix("music.youtube.com") else { return }
        Task { @MainActor [weak self] in
            for delayNs: UInt64 in [0, 350_000_000, 800_000_000] {
                if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
                guard let self, !self.isFinishing else { return }
                let probe = await YouTubeMusicWebBridge.probePage(webView)
                let storeCookies = await YouTubeMusicWebBridge.readCookieSessionFromStore()
                guard storeCookies.hasAuth else {
                    self.finish(with: nil)
                    return
                }
                guard probe?.loggedIn == true else { continue }
                self.finish(with: YouTubeMusicWebAuthSession(
                    cookieHeader: storeCookies.cookieHeader,
                    displayName: probe?.displayName,
                    authUser: probe?.authUser,
                    delegatedSessionID: probe?.delegatedSessionID
                ))
                return
            }
            self?.finish(with: nil)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(with: nil)
    }

    private func finish(with session: YouTubeMusicWebAuthSession?) {
        guard !isFinishing else { return }
        isFinishing = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let cont = continuation
        continuation = nil

        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        hostWindow?.close()
        hostWindow = nil

        cont?.resume(returning: session)
    }
}

#else

@MainActor
final class YouTubeMusicWebBridge {
    static let shared = YouTubeMusicWebBridge()
    var isSupportedOnPlatform: Bool { false }
    func signInInteractively() async throws -> YouTubeMusicWebAuthSession {
        throw NSError(domain: "YouTubeMusicWebBridge", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Paste your YouTube Music Cookie header or sign in on macOS."
        ])
    }
    func cancelInteractiveSignIn() {}
    func refreshSilently() async -> YouTubeMusicWebAuthSession? { nil }
    func signOut() async {}
    func seedCookies(fromHeader _: String) async {}
}

#endif
