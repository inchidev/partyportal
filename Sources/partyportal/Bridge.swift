// The WebRTC peer on the host. macOS ships a full WebRTC stack inside WebKit, so instead of bundling one
// we run web/bridge.html in a web view nobody looks at. It talks to Core over a local WebSocket and to the
// guest's browser over a direct UDP connection (ICE + DTLS + SCTP data channels).

import AppKit
import WebKit

final class BridgeHost: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var url: URL?

    func start(url: URL) {
        self.url = url
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // WebKit hides this Mac's local addresses behind one-off .local names, which the guest's browser cannot
        // always resolve (phone hotspots, some routers) — and then two devices on the same network have no
        // direct path. The guest is someone the host invited; let them see the LAN address.
        let unfiltered = NSSelectorFromString("_setICECandidateFilteringEnabled:")
        if config.preferences.responds(to: unfiltered) { config.preferences.perform(unfiltered, with: nil) }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 120), configuration: config)
        view.navigationDelegate = self

        // The page must count as visible. WebKit pauses the process of a page that is hidden, off screen or
        // covered for about 220 ms out of every 330, and video then arrives in clumps (measured: frames up to
        // 230 ms late; with a visible window, under 30 ms). So the page lives in a 2×2 pixel black window in a
        // screen corner, above other windows and present on every Space, including full-screen ones.
        // PP_BRIDGE_WINDOW=show makes it a normal small window for debugging.
        let debug = ProcessInfo.processInfo.environment["PP_BRIDGE_WINDOW"] == "show"
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = debug ? NSRect(x: 40, y: 40, width: 200, height: 120) : NSRect(x: screen.maxX - 2, y: screen.minY, width: 2, height: 2)
        let win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.ignoresMouseEvents = true
        win.hasShadow = false
        win.backgroundColor = .black
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.contentView = view
        win.orderFrontRegardless()
        window = win
        webView = view
        view.load(URLRequest(url: url))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let url { webView.load(URLRequest(url: url)) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { retry() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { retry() }

    private func retry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if let self, let url = self.url { self.webView?.load(URLRequest(url: url)) }
        }
    }
}
