import Foundation

/// JavaScript injected into every Instagram page before Instagram's own code runs.
///
/// Instagram is a "single-page app": most taps do not load a new page, they swap content in place and
/// rewrite the address bar. The native web view never hears about those, so this script
///   1. swallows taps on links that lead to blocked pages, and
///   2. refuses in-page route changes to blocked pages,
/// and reports both to the app through `window.webkit.messageHandlers.igdmGuard`.
/// The allowed-path list is taken from `URLPolicy`, so the two sides can never disagree.
enum GuardScript {
    static let messageName = "igdmGuard"

    /// - Parameter allowLandingPage: mirrors `URLPolicy.decision(for:allowLandingPage:)`; true while logged out.
    static func source(allowLandingPage: Bool) -> String {
        let prefixes = URLPolicy.allowedPathPrefixes.map { "\"\($0)\"" }.joined(separator: ", ")
        let hosts = URLPolicy.allowedHosts.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        (function () {
          if (window.__igdmGuardInstalled) { return; }
          window.__igdmGuardInstalled = true;
          var ALLOWED = [\(prefixes)];
          var HOSTS = [\(hosts)];
          var ALLOW_ROOT = \(allowLandingPage ? "true" : "false");
          var lastReport = { url: null, time: 0 };

          function post(payload) {
            try { window.webkit.messageHandlers.\(messageName).postMessage(payload); } catch (e) {}
          }
          function isAllowedHost(host) {
            return HOSTS.indexOf(host) !== -1;
          }
          function isAllowed(url) {
            if (url.protocol === 'about:' || url.protocol === 'blob:') { return true; }
            if (url.protocol !== 'https:' && url.protocol !== 'http:') { return false; }
            if (!isAllowedHost(url.hostname.toLowerCase())) { return false; }
            var path = url.pathname || '/';
            if (path.slice(-1) !== '/') { path += '/'; }
            if (ALLOW_ROOT && path === '/') { return true; }
            for (var i = 0; i < ALLOWED.length; i++) {
              if (path.indexOf(ALLOWED[i]) === 0) { return true; }
            }
            return false;
          }
          function toURL(value) {
            try { return new URL(String(value), location.href); } catch (e) { return null; }
          }

          // 1. Click guard. Registered on window in the capture phase, so it runs before Instagram's handlers.
          window.addEventListener('click', function (event) {
            var target = event.target;
            var anchor = (target && target.closest) ? target.closest('a[href]') : null;
            if (!anchor) { return; }
            var href = anchor.getAttribute('href');
            if (!href || href === '#' || href.indexOf('javascript:') === 0) { return; }
            var url = toURL(href);
            if (!url || isAllowed(url)) { return; }
            event.preventDefault();
            event.stopImmediatePropagation();
            event.stopPropagation();
            post({ type: 'click', url: url.href });
          }, true);

          // 2. Route guard. Instagram moves between pages by rewriting the address bar; refuse blocked ones.
          function guarded(original, name) {
            return function (state, title, url) {
              if (url !== undefined && url !== null) {
                var parsed = toURL(url);
                if (parsed && !isAllowed(parsed)) {
                  post({ type: name, url: parsed.href });
                  return undefined;
                }
              }
              return original.apply(this, arguments);
            };
          }
          history.pushState = guarded(history.pushState, 'pushState');
          history.replaceState = guarded(history.replaceState, 'replaceState');

          function check() {
            var url = toURL(location.href);
            if (!url || isAllowed(url)) { return; }
            var now = Date.now();
            if (lastReport.url === url.href && now - lastReport.time < 10000) { return; }
            lastReport = { url: url.href, time: now };
            post({ type: 'watch', url: url.href });
          }
          window.addEventListener('popstate', check);
          setInterval(check, 400);
        })();
        """
    }
}
