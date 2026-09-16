import Foundation

/// The rules for what the app may show. Edit `allowedPathPrefixes` to change them.
enum URLPolicy {

    enum Decision: Equatable {
        case allow                  // show inside the app
        case block                  // do nothing, or bounce back to the inbox
        case openExternally(URL)    // hand to Safari (web links that people send you)
    }

    /// The only hosts whose pages the app shows. Other Instagram subdomains (help, applink, ...) are blocked.
    static let allowedHosts: [String] = ["www.instagram.com", "instagram.com"]

    /// Instagram pages the app may show. A page is allowed when its path starts with one of these.
    static let allowedPathPrefixes: [String] = [
        "/direct/",             // inbox, threads, new message, message requests
        "/accounts/login/",     // login page, two-factor code page
        "/accounts/onetap/",    // "Save your login info?" page shown right after login
        "/accounts/password/",  // forgot-password flow
        "/challenge/",          // security checks ("confirm it's you")
        "/auth_platform/",      // authentication-app code entry
    ]

    /// When true, non-Instagram links you tap inside a DM open in Safari. When false they are blocked.
    static let openExternalLinksInSafari = true

    /// Outside sites that are never opened, even in Safari: Instagram's "Open app" buttons point here.
    static let blockedExternalHosts: [String] = ["apps.apple.com", "itunes.apple.com", "play.google.com"]

    static let inboxURL = URL(string: "https://www.instagram.com/direct/inbox/")!
    static let loginURL = URL(string: "https://www.instagram.com/accounts/login/?next=%2Fdirect%2Finbox%2F")!
    static let landingURL = URL(string: "https://www.instagram.com/")!

    /// - Parameter allowLandingPage: while you are logged out, Instagram's front page ("/") is just a login
    ///   form, so the app may show it. Once you are logged in, "/" is the feed and stays blocked.
    static func decision(for url: URL, allowLandingPage: Bool = false) -> Decision {
        guard let scheme = url.scheme?.lowercased() else { return .block }

        // Harmless in-page URLs: empty pages and in-memory images.
        if scheme == "about" || scheme == "blob" { return .allow }

        // Anything that is not a normal web link (instagram://, itms-apps://, fb://, mailto:) is refused.
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return .block }

        if isInstagramHost(host) {
            if host == "l.instagram.com" {
                // Instagram wraps outgoing links as https://l.instagram.com/?u=<real link>
                guard let target = outboundTarget(of: url), !blockedExternalHosts.contains(target.host?.lowercased() ?? "") else { return .block }
                return openExternalLinksInSafari ? .openExternally(target) : .block
            }
            guard allowedHosts.contains(host) else { return .block }
            let path = normalized(path: url.path)
            if allowLandingPage && path == "/" { return .allow }
            return allowedPathPrefixes.contains(where: { path.hasPrefix($0) }) ? .allow : .block
        }

        if blockedExternalHosts.contains(host) { return .block }
        return openExternalLinksInSafari ? .openExternally(url) : .block
    }

    static func isInstagramHost(_ host: String) -> Bool {
        host == "instagram.com" || host.hasSuffix(".instagram.com")
    }

    /// Treats "/direct" and "/direct/" the same, and an empty path as "/".
    private static func normalized(path: String) -> String {
        var result = path.isEmpty ? "/" : path
        if !result.hasSuffix("/") { result += "/" }
        return result
    }

    private static func outboundTarget(of url: URL) -> URL? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "u" })?.value,
              let target = URL(string: raw),
              let scheme = target.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        return target
    }
}
