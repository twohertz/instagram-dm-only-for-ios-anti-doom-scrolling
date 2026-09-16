import SwiftUI
import WebKit
import os

/// Owns the single WKWebView for the whole app, decides which navigations are allowed,
/// and receives reports from the injected guard script (see `GuardScript`).
final class WebModel: NSObject, ObservableObject {

    /// A short notice shown briefly over the page when something is wrong (for example Instagram refusing
    /// to answer). nil means nothing to show. Ordinary blocked taps are silent.
    @Published var problem: String?

    private let log = Logger(subsystem: AppInfo.bundleID, category: "navigation")
    private var recentBounces: [Date] = []
    private var problemResetWork: DispatchWorkItem?
    private var savedUserAgent = false
    private var cookieStore: WKHTTPCookieStore?
    private var landingPageFallbacks = 0

    /// True when Instagram's session cookie is present. While logged out, the front page is only a login form.
    private var isLoggedIn = false

    /// Created once and kept for the life of the app, so the login session is never thrown away.
    private(set) lazy var webView: WKWebView = makeWebView()

    // MARK: - Setup

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()   // persistent cookies: login survives relaunches
        configuration.applicationNameForUserAgent = Self.safariApplicationName
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile

        let cookieStore = configuration.websiteDataStore.httpCookieStore
        cookieStore.add(self)
        self.cookieStore = cookieStore

        let userContent = configuration.userContentController
        userContent.add(WeakMessageHandler(self), name: GuardScript.messageName)
        installGuardScript(in: userContent)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false          // no long-press previews of blocked pages
        #if DEBUG
        webView.isInspectable = true               // Safari on the Mac -> Develop menu -> this app
        #endif

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pulledToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        // Read the saved cookies first (is the user logged in?), then open the inbox.
        DispatchQueue.main.async { [weak self] in
            self?.refreshLoginState { webView.load(URLRequest(url: URLPolicy.inboxURL)) }
        }
        return webView
    }

    /// (Re)installs the guard script so it applies the same rules as the app for the next page load.
    private func installGuardScript(in controller: WKUserContentController) {
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: GuardScript.source(allowLandingPage: !isLoggedIn),
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
    }

    /// Makes the user agent identical to Mobile Safari on this iOS version, so Instagram
    /// does not treat the app as an "in-app browser".
    private static var safariApplicationName: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(v.majorVersion).\(v.minorVersion) Mobile/15E148 Safari/604.1"
    }

    // MARK: - Actions

    func goToInbox() {
        recentBounces.removeAll()
        landingPageFallbacks = 0
        webView.load(URLRequest(url: URLPolicy.inboxURL))
    }

    /// Opens one conversation (used when a notification is tapped).
    func open(threadID: String) {
        guard !threadID.isEmpty, threadID.allSatisfy(\.isNumber),
              let url = URL(string: "https://www.instagram.com/direct/t/\(threadID)/")
        else { goToInbox(); return }
        recentBounces.removeAll()
        log.notice("OPEN thread \(threadID, privacy: .public)")
        webView.load(URLRequest(url: url))
    }

    /// Called when the app comes to the front: make sure an allowed page is showing.
    func appBecameActive() {
        if let current = webView.url, URLPolicy.decision(for: current, allowLandingPage: !isLoggedIn) != .allow {
            log.notice("FOREGROUND on \(current.path, privacy: .public) -> inbox")
            goToInbox()
        }
        if isLoggedIn { DMNotifier.shared.requestPermissionIfNeeded() }
    }

    @objc private func pulledToRefresh(_ control: UIRefreshControl) {
        control.endRefreshing()
        if let url = webView.url, URLPolicy.decision(for: url, allowLandingPage: !isLoggedIn) == .allow {
            webView.reload()
        } else {
            goToInbox()
        }
    }

    // MARK: - Login state (from the session cookie)

    private func refreshLoginState(completion: (() -> Void)? = nil) {
        guard let cookieStore else { completion?(); return }
        cookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let loggedIn = cookies.contains {
                $0.name == "sessionid" && !$0.value.isEmpty && $0.domain.hasSuffix("instagram.com")
            }
            if loggedIn != self.isLoggedIn {
                self.log.notice("LOGIN STATE \(loggedIn ? "logged in" : "logged out", privacy: .public)")
                self.isLoggedIn = loggedIn
                self.landingPageFallbacks = 0
                self.installGuardScript(in: self.webView.configuration.userContentController)
                if loggedIn {
                    DMNotifier.shared.requestPermissionIfNeeded()
                    DMNotifier.shared.foregroundSync()
                    if let current = self.webView.url,
                       URLPolicy.decision(for: current, allowLandingPage: false) != .allow {
                        self.log.notice("LOGGED IN on \(current.path, privacy: .public) -> inbox")
                        self.webView.load(URLRequest(url: URLPolicy.inboxURL))
                    }
                }
            }
            completion?()
        }
    }

    // MARK: - Helpers

    private func showProblem(_ text: String, for seconds: Double = 4) {
        problem = text
        problemResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.problem = nil }
        problemResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Returns to the inbox after something tried to leave the allowed pages.
    /// Rate-limited, so a misbehaving redirect can never reload forever.
    private func bounce(reason: String, reloadCurrentPage: Bool = false) {
        let now = Date()
        recentBounces = recentBounces.filter { now.timeIntervalSince($0) < 20 }
        recentBounces.append(now)
        switch recentBounces.count {
        case 1, 3:
            if reloadCurrentPage, let current = webView.url,
               URLPolicy.decision(for: current, allowLandingPage: !isLoggedIn) == .allow {
                // The address never changed, but Instagram may already be drawing the blocked screen.
                log.notice("BOUNCE -> reload \(current.path, privacy: .public) (\(reason, privacy: .public))")
                webView.reload()
            } else {
                log.notice("BOUNCE -> inbox (\(reason, privacy: .public))")
                webView.load(URLRequest(url: URLPolicy.inboxURL))
            }
        case 2:
            // Instagram refused the inbox once already; it is probably asking for a login.
            log.notice("BOUNCE -> login page (\(reason, privacy: .public))")
            webView.load(URLRequest(url: URLPolicy.loginURL))
        default:
            log.error("BOUNCE suppressed, too many in 20 s (\(reason, privacy: .public))")
            showProblem("Instagram keeps leaving the inbox. Pull down to retry.")
        }
    }

    private func openInSafari(_ url: URL) {
        log.notice("SAFARI \(url.absoluteString, privacy: .public)")
        UIApplication.shared.open(url)
    }

    private static func label(_ decision: URLPolicy.Decision) -> String {
        switch decision {
        case .allow: return "ALLOW"
        case .block: return "BLOCK"
        case .openExternally: return "EXTERNAL"
        }
    }

    private static func label(_ type: WKNavigationType) -> String {
        switch type {
        case .linkActivated: return "link"
        case .formSubmitted: return "form"
        case .backForward: return "back-forward"
        case .reload: return "reload"
        case .formResubmitted: return "form-resubmit"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Real page loads (first load, redirects, form submits, back/forward, links that force a load)

extension WebModel: WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }

        // Embedded frames (iframes) cannot take over the screen, and Instagram's login uses some.
        if let frame = navigationAction.targetFrame, !frame.isMainFrame {
            decisionHandler(.allow)
            return
        }

        let userTapped = navigationAction.navigationType == .linkActivated
        let wantsNewWindow = navigationAction.targetFrame == nil
        let decision = URLPolicy.decision(for: url, allowLandingPage: !isLoggedIn)
        log.notice("\(Self.label(decision), privacy: .public) \(url.absoluteString, privacy: .public) [\(Self.label(navigationAction.navigationType), privacy: .public)]")

        switch decision {
        case .allow:
            if userTapped || wantsNewWindow {
                // Load tapped links ourselves: a navigation the user starts could otherwise be handed
                // to the Instagram app (universal links) or ask for a new window we do not have.
                decisionHandler(.cancel)
                webView.load(navigationAction.request)
            } else {
                decisionHandler(.allow)
            }

        case .openExternally(let external):
            decisionHandler(.cancel)
            if userTapped || wantsNewWindow {
                openInSafari(external)
            } else {
                bounce(reason: "redirect to \(external.host ?? "another site")")
            }

        case .block:
            decisionHandler(.cancel)
            if !userTapped {
                // Redirects, scripts, form submits, back/forward: the page on screen may now be stale or blank.
                bounce(reason: "navigation to \(url.path)")
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            log.notice("RESPONSE \(http.statusCode) \(http.url?.absoluteString ?? "-", privacy: .public)")
            if http.statusCode == 429 {
                // Instagram's "too many requests" answer comes with an empty page. It sometimes refuses the
                // login page this way while still serving its front page, which shows the same login form
                // while you are logged out, so try that once or twice.
                if !isLoggedIn, http.url?.path != "/", landingPageFallbacks < 2 {
                    landingPageFallbacks += 1
                    log.notice("FALLBACK -> front page (login page answered 429)")
                    decisionHandler(.cancel)
                    webView.load(URLRequest(url: URLPolicy.landingURL))
                    return
                }
                showProblem("Instagram says: too many requests. Wait a few minutes, then pull down to reload.", for: 8)
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log.notice("LOADED \(webView.url?.absoluteString ?? "-", privacy: .public)")
        landingPageFallbacks = 0
        if !savedUserAgent {
            // The background inbox check identifies itself exactly like this web view.
            savedUserAgent = true
            webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
                if let userAgent = result as? String {
                    UserDefaults.standard.set(userAgent, forKey: DMNotifier.userAgentKey)
                    self?.log.notice("USER AGENT \(userAgent, privacy: .public)")
                }
            }
        }
        #if DEBUG
        webView.evaluateJavaScript("document.title + ' | ' + (document.body ? document.body.innerText.length : 0) + ' chars'") { [weak self] result, _ in
            if let text = result as? String { self?.log.notice("PAGE \(text, privacy: .public)") }
        }
        #endif
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // -999: we cancelled it. 102: we cancelled it in the middle of a redirect. Both are expected.
        if nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102) { return }
        log.error("LOAD FAILED \(nsError.localizedDescription, privacy: .public)")
        showProblem("Couldn't load: \(nsError.localizedDescription). Pull down to retry.")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("Web content process crashed; reloading the inbox")
        goToInbox()
    }
}

// MARK: - Popups and JavaScript dialogs

extension WebModel: WKUIDelegate {

    /// Links that want a new window or tab. There is only one view, so allowed ones open here.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            let decision = URLPolicy.decision(for: url, allowLandingPage: !isLoggedIn)
            log.notice("POPUP \(Self.label(decision), privacy: .public) \(url.absoluteString, privacy: .public)")
            switch decision {
            case .allow: webView.load(navigationAction.request)
            case .openExternally(let external): openInSafari(external)
            case .block: break
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        presentDialog(message: message, cancelTitle: nil) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        presentDialog(message: message, cancelTitle: "Cancel", completion: completionHandler)
    }

    private func presentDialog(message: String, cancelTitle: String?, completion: @escaping (Bool) -> Void) {
        guard let presenter = webView.window?.rootViewController?.topMostPresented else {
            completion(false)
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        if let cancelTitle {
            alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in completion(false) })
        }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion(true) })
        presenter.present(alert, animated: true)
    }
}

// MARK: - Reports from the injected guard script

extension WebModel: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == GuardScript.messageName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let urlString = body["url"] as? String,
              let url = URL(string: urlString)
        else { return }

        let decision = URLPolicy.decision(for: url, allowLandingPage: !isLoggedIn)
        log.notice("GUARD \(type, privacy: .public) \(Self.label(decision), privacy: .public) \(url.absoluteString, privacy: .public)")

        switch decision {
        case .allow:
            return   // the script and the app disagree; nothing to do

        case .openExternally(let external):
            if type == "click" {
                openInSafari(external)
            } else {
                bounce(reason: "\(type) to \(external.host ?? "another site")")
            }

        case .block:
            if type != "click" {
                // A route change slipped past the click guard; Instagram may be showing a blocked page.
                bounce(reason: "\(type) to \(url.path)", reloadCurrentPage: type != "watch")
            }
        }
    }
}

// MARK: - Cookie changes (login / logout)

extension WebModel: WKHTTPCookieStoreObserver {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        refreshLoginState()
    }
}

/// WKUserContentController keeps a strong reference to its message handler; this avoids a retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

private extension UIViewController {
    var topMostPresented: UIViewController {
        presentedViewController?.topMostPresented ?? self
    }
}

/// Puts the model's web view into SwiftUI.
struct WebView: UIViewRepresentable {
    let model: WebModel

    func makeUIView(context: Context) -> WKWebView {
        model.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
