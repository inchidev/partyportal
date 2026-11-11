// partyportal — share one window of this Mac with a guest in a browser.
//
//   partyportal                      real windows, real input (needs Screen Recording + Accessibility)
//   partyportal --fake               synthetic picture, input written to a log: works with no permissions
//   partyportal --dry-input          real window, but the guest's input is only logged
//   partyportal --window "Safari"    start sharing the first window whose title or app matches
//   partyportal --check "Safari"     diagnostics: permissions, and whether clicks can reach that window right now
//   partyportal --window "Simulator" --public --print-link --no-open
//                              for scripts and agents: share that window, open a public link and print it
//                              to stdout as one JSON line {"type":"link","url":…,"local":…,"window":…}
//   --view-only                the guest can watch but not touch
//   --admin-port N  --guest-port N  --token T  --config FILE  --input-log FILE  --web DIR  --no-open

import AppKit
import Foundation

var opts = Options()
var args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String {
    guard !args.isEmpty else {
        FileHandle.standardError.write(Data("\(flag): needs a value\n".utf8))
        exit(2)
    }
    return args.removeFirst()
}
/// Diagnostics: `partyportal --check "Safari"` prints the permissions and whether clicks could reach that window right now.
func check(_ name: String) -> Never {
    print("Screen Recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "missing"), Accessibility: \(AX.trusted ? "granted" : "missing"), screen locked: \(WindowQuery.screenLocked ? "yes" : "no")")
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    let match = list.first { w in
        let label = ((w[kCGWindowOwnerName as String] as? String) ?? "") + " " + ((w[kCGWindowName as String] as? String) ?? "")
        let visible = ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01 && ((w[kCGWindowLayer as String] as? Int) ?? 0) == 0
        let size = (w[kCGWindowBounds as String]).flatMap { CGRect(dictionaryRepresentation: $0 as! CFDictionary) } ?? .zero
        return visible && size.height > 80 && label.localizedCaseInsensitiveContains(name)
    }
    guard let w = match, let id = w[kCGWindowNumber as String] as? CGWindowID, let pid = w[kCGWindowOwnerPID as String] as? pid_t, let (frame, onScreen) = WindowQuery.frame(id) else {
        print("Window “\(name)” not found")
        exit(1)
    }
    print("Window \(id): \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)), on screen: \(onScreen ? "yes" : "no"), frontmost: \(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid ? "yes" : "no")")
    for (label, fx, fy) in [("center", 0.5, 0.5), ("top left", 0.1, 0.15), ("bottom right", 0.9, 0.9)] {
        let p = CGPoint(x: frame.minX + frame.width * fx, y: frame.minY + frame.height * fy)
        print("  click at \(label): \(WindowQuery.isTopmost(id, pid: pid, at: p) ? "reaches the window" : "the window is covered")")
    }
    exit(0)
}

while !args.isEmpty {
    let flag = args.removeFirst()
    switch flag {
    case "--fake": opts.fake = true
    case "--dry-input": opts.dryInput = true
    case "--no-open": opts.openPanel = false
    case "--public": opts.publicLink = true
    case "--view-only": opts.viewOnly = true
    case "--print-link": opts.printLink = true
    case "--admin-port": opts.adminPort = UInt16(value(flag)) ?? opts.adminPort
    case "--guest-port": opts.guestPort = UInt16(value(flag)) ?? opts.guestPort
    case "--token": opts.token = value(flag)
    case "--config": opts.configPath = value(flag)
    case "--input-log": opts.inputLog = value(flag)
    case "--window": opts.autoWindow = value(flag)
    case "--web": opts.webDir = value(flag)
    case "--check": check(value(flag))
    case "-h", "--help":
        print("partyportal [--fake] [--dry-input] [--window NAME] [--admin-port N] [--guest-port N] [--token T] [--config FILE] [--input-log FILE] [--web DIR] [--no-open]")
        exit(0)
    default:
        if flag.hasPrefix("-psn") { continue }  // Finder adds this when launching an .app
        FileHandle.standardError.write(Data("Unknown option: \(flag)\n".utf8))
        exit(2)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let core: Core
    var item: NSStatusItem?
    var signals: [DispatchSourceSignal] = []

    init(core: Core) { self.core = core }

    func applicationDidFinishLaunching(_ note: Notification) {
        do {
            try core.start()
        } catch {
            FileHandle.standardError.write(Data("Could not start: \(error.localizedDescription). PartyPortal may be running already.\n".utf8))
            exit(1)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "PartyPortal"
        let menu = NSMenu()
        menu.addItem(withTitle: "Open host panel", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit PartyPortal", action: #selector(quit), keyEquivalent: "").target = self
        item.menu = menu
        self.item = item

        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.quit() }
            src.resume()
            signals.append(src)
        }
    }

    @objc func openPanel() { core.openPanel() }

    @objc func quit() {
        core.shutdown()
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(core: Core(opts))
app.delegate = delegate
app.run()
