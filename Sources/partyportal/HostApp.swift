// The host's side as a Mac app: a window with the panel, and an icon in the menu bar that stays when the
// window is closed. The panel itself is the same page the local server gives a browser (web/host.html),
// shown in a web view — one implementation for the app, for a browser tab and for scripts.

import AppKit
import WebKit

// MARK: The window

final class HostWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let url: URL
    private var window: NSWindow?
    private var webView: WKWebView?

    init(adminPort: UInt16) {
        url = URL(string: "http://127.0.0.1:\(adminPort)/")!
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// ⌘R: load the panel again (after an update of the page, or when it looks stuck).
    @objc func reload() { webView?.reload() }

    func show() {
        if window == nil { build() }
        // With a window open this is an ordinary app (Dock icon, ⌘Tab, a menu); without one it lives in the menu bar.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "pp")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1080, height: 760), configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setValue(false, forKey: "drawsBackground")  // no white flash before the page paints

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = "PartyPortal"
        // The title bar takes the colour of the panel's own header, so the two read as one strip.
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(srgbRed: 0x1e / 255, green: 0x1f / 255, blue: 0x22 / 255, alpha: 1)
        win.minSize = NSSize(width: 560, height: 480)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = view
        win.center()
        win.setFrameAutosaveName("PartyPortalHost")
        window = win
        webView = view
        view.load(URLRequest(url: url))
    }

    // Closing the window keeps PartyPortal running in the menu bar.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    // The panel asks the app for things a page cannot do by itself.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.host == url.host,
              let body = message.body as? [String: Any] else { return }
        if let text = body["copy"] as? String, text.count < 4096 {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // Only the panel lives in this window; any other link opens in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = action.request.url else { return decisionHandler(.cancel) }
        if target.host == url.host, target.port == url.port { return decisionHandler(.allow) }
        if target.scheme == "about" { return decisionHandler(.allow) }
        NSWorkspace.shared.open(target)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let target = action.request.url { NSWorkspace.shared.open(target) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // The local server may still be starting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if let self { self.webView?.load(URLRequest(url: self.url)) }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.load(URLRequest(url: url)) }

    // alert() and confirm() from the page, as sheets on the window.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        guard let window else { alert.runModal(); return completionHandler() }
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return completionHandler(alert.runModal() == .alertFirstButtonReturn) }
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
}

// MARK: The menu bar icon

/// What the icon says at a glance.
enum PortalMood: Equatable {
    case idle        // nothing shared
    case waiting     // a window is shared, nobody is there
    case watching    // a guest is connected and only watching
    case control     // a guest has the mouse and keyboard
    case attention   // something needs the host: a missing permission, a paused guest

    var color: NSColor? {
        switch self {
        case .idle: return nil  // drawn as a template: follows the menu bar's own colour
        case .waiting: return NSColor(srgbRed: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255, alpha: 1)
        case .watching: return NSColor(srgbRed: 0xF0 / 255, green: 0xB2 / 255, blue: 0x32 / 255, alpha: 1)
        case .control: return NSColor(srgbRed: 0x23 / 255, green: 0xA5 / 255, blue: 0x5A / 255, alpha: 1)
        case .attention: return NSColor(srgbRed: 0xF2 / 255, green: 0x3F / 255, blue: 0x43 / 255, alpha: 1)
        }
    }
}

enum PortalMark {
    /// The logo — a party hat coming up through a portal ring — in one colour, sized for the menu bar.
    /// Same geometry as site/assets/mark.svg (a 64×64 box), without the stripes: they vanish at this size.
    static func image(points: CGFloat = 18, color: NSColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let k = rect.width / 64
            ctx.scaleBy(x: k, y: k)
            (color ?? .black).set()

            // The ring is an ellipse centred on (32, 47); its far half goes behind the hat, its near half in front.
            func ring(from: CGFloat, to: CGFloat) -> NSBezierPath {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: .zero, radius: 25, startAngle: from, endAngle: to)
                var shape = AffineTransform(translationByX: 32, byY: 47)
                shape.scale(x: 1, y: 9.5 / 25)
                arc.transform(using: shape)
                arc.lineWidth = 6.5
                arc.lineCapStyle = .round
                return arc
            }
            ring(from: 180, to: 360).stroke()

            // The hat shows above the ring and through its opening, never below the near edge. In one colour
            // it would melt into the ring, so a thin gap is cut around it and inside the ring's near half.
            var tilt = AffineTransform(translationByX: 32, byY: 47)
            tilt.rotate(byDegrees: -11)
            tilt.translate(x: -32, y: -47)
            let hat = NSBezierPath()
            hat.move(to: NSPoint(x: 32, y: 9))
            hat.line(to: NSPoint(x: 52.9, y: 60))
            hat.line(to: NSPoint(x: 11.1, y: 60))
            hat.close()
            hat.transform(using: tilt)
            hat.lineJoinStyle = .round

            func through(inset: CGFloat) -> NSBezierPath {  // above the ring, plus the lower half of its opening
                let area = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 64, height: 47))
                let half = NSBezierPath()
                half.appendArc(withCenter: .zero, radius: 1, startAngle: 0, endAngle: 180)
                half.close()
                var shape = AffineTransform(translationByX: 32, byY: 47)
                shape.scale(x: 25 - inset, y: max(0.5, 9.5 - inset))
                half.transform(using: shape)
                area.append(half)
                return area
            }
            let gap: CGFloat = 3.2
            ctx.saveGState()
            through(inset: 0).addClip()
            ctx.setBlendMode(.clear)
            hat.lineWidth = gap * 2
            hat.stroke()
            hat.fill()
            ctx.restoreGState()

            ctx.saveGState()
            through(inset: 3.25 + gap).addClip()
            hat.fill()
            ctx.restoreGState()

            NSBezierPath(ovalIn: NSRect(x: 27.3 - 6.5, y: 9.7 - 6.5, width: 13, height: 13)).fill()
            ring(from: 0, to: 180).stroke()
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}

final class StatusIcon: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let core: Core
    private let openWindow: () -> Void
    private let quit: () -> Void
    private var mood: PortalMood?
    private var timer: Timer?

    init(core: Core, openWindow: @escaping () -> Void, quit: @escaping () -> Void) {
        self.core = core
        self.openWindow = openWindow
        self.quit = quit
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// One line for the tooltip and the top of the menu, and the mood that colours the icon.
    static func read(_ state: [String: Any]) -> (mood: PortalMood, line: String, link: String?) {
        let sharing = state["sharing"] as? [String: Any]
        let guest = state["guest"] as? [String: Any]
        let permissions = state["permissions"] as? [String: Any] ?? [:]
        let links = state["link"] as? [String: Any] ?? [:]
        let link = (links["public"] as? String) ?? (links["local"] as? String)
        let fake = (state["fake"] as? Bool) ?? false
        if !fake, permissions["screen"] as? Bool == false { return (.attention, "Screen Recording permission is missing", link) }
        guard let sharing else { return (.idle, "Not sharing anything", link) }
        let title = ((sharing["window"] as? [String: Any])?["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "a window"
        guard let guest else { return (.waiting, "Sharing \(title) — waiting for a guest", link) }
        if (guest["control"] as? Bool) ?? false {
            if let paused = sharing["paused"] as? String, !paused.isEmpty { return (.attention, "Sharing \(title) — the guest is paused", link) }
            return (.control, "Sharing \(title) — the guest is in control", link)
        }
        return (.watching, "Sharing \(title) — a guest is watching", link)
    }

    private func refresh() {
        let (now, line, _) = Self.read(core.stateJSON())
        item.button?.toolTip = "PartyPortal: \(line)"
        guard now != mood else { return }
        mood = now
        item.button?.image = PortalMark.image(color: now.color)
        item.button?.setAccessibilityLabel("PartyPortal")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let state = core.stateJSON()
        let (_, line, link) = Self.read(state)
        menu.removeAllItems()
        let head = menu.addItem(withTitle: line, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(.separator())
        add(menu, "Open PartyPortal", #selector(open))
        if link != nil, state["sharing"] is [String: Any] { add(menu, "Copy the guest's link", #selector(copyLink)) }
        if state["guest"] is [String: Any] { add(menu, "Disconnect the guest", #selector(kick)) }
        if state["sharing"] is [String: Any] { add(menu, "Stop sharing", #selector(stop)) }
        menu.addItem(.separator())
        add(menu, "Quit PartyPortal", #selector(quitApp))
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
    }

    @objc private func open() { openWindow() }
    @objc private func quitApp() { quit() }
    @objc private func stop() { core.hostAction("stop") }
    @objc private func kick() { core.hostAction("kick") }
    @objc private func copyLink() {
        guard let link = Self.read(core.stateJSON()).link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }
}

// MARK: The app's own menu

enum MainMenu {
    /// Shown while the window is open. ⌘W closes the window (the app stays in the menu bar), ⌘Q quits for real.
    static func install(quit: Selector, target: AnyObject, reload: Selector, window: AnyObject) {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "About PartyPortal", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide PartyPortal", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit PartyPortal", action: quit, keyEquivalent: "q").target = target
        main.addItem(withTitle: "PartyPortal", action: nil, keyEquivalent: "").submenu = app

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: reload, keyEquivalent: "r").target = window
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }
}
