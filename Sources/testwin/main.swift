// partyportal-testwin — a window made for trying PartyPortal out: known colours, a "secret" to mask,
// a dangerous button to block, and a line showing the last thing that happened to it.
// Everything is also appended to $TMPDIR/partyportal-testwin.log.

import AppKit
import AVFoundation

let logPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("partyportal-testwin.log")
FileManager.default.createFile(atPath: logPath, contents: nil)
let logHandle = FileHandle(forWritingAtPath: logPath)

func note(_ text: String) {
    logHandle?.write(Data((text + "\n").utf8))
    (NSApp.delegate as? TestApp)?.status.stringValue = text
}

final class Board: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// A bar that crosses the bottom edge every four seconds: something that always moves.
    private var started = Date()
    private var ticker: Timer?
    private var barRect: NSRect {
        let t = Date().timeIntervalSince(started).truncatingRemainder(dividingBy: 4) / 4
        return NSRect(x: CGFloat(t) * (bounds.width - 16), y: bounds.height - 18, width: 16, height: 18)
    }

    override func viewDidMoveToWindow() {
        ticker?.invalidate()
        guard window != nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.setNeedsDisplay(NSRect(x: 0, y: self.bounds.height - 18, width: self.bounds.width, height: 18))
        }
    }

    override func draw(_ dirty: NSRect) {
        defer {
            NSColor.white.setFill()
            barRect.fill()
        }
        let w = bounds.width / 2, h = bounds.height / 2
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(200, 40, 40), (40, 160, 60), (40, 80, 200), (220, 180, 40)]
        let rects = [NSRect(x: 0, y: 0, width: w, height: h), NSRect(x: w, y: 0, width: w, height: h), NSRect(x: 0, y: h, width: w, height: h), NSRect(x: w, y: h, width: w, height: h)]
        for (c, r) in zip(colors, rects) {
            NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1).setFill()
            r.fill()
        }
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        note(String(format: "click %.3f %.3f ×%d", p.x / bounds.width, p.y / bounds.height, e.clickCount))
    }

    override func rightMouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        note(String(format: "right click %.3f %.3f", p.x / bounds.width, p.y / bounds.height))
    }

    override func scrollWheel(with e: NSEvent) {
        note(String(format: "scroll %.0f %.0f", e.scrollingDeltaX, e.scrollingDeltaY))
    }

    override func keyDown(with e: NSEvent) {
        var mods = ""
        if e.modifierFlags.contains(.control) { mods += "⌃" }
        if e.modifierFlags.contains(.option) { mods += "⌥" }
        if e.modifierFlags.contains(.shift) { mods += "⇧" }
        if e.modifierFlags.contains(.command) { mods += "⌘" }
        note("key \(mods)\(e.charactersIgnoringModifiers ?? "?") (code \(e.keyCode))")
    }
}

/// A 440 Hz tone, so there is something for PartyPortal to carry as sound.
final class Tone {
    private let engine = AVAudioEngine()
    private var phase = 0.0
    private var amplitude: Float = 0
    private(set) var playing = false

    func toggle(amplitude a: Float) {
        if playing {
            engine.stop()
            playing = false
            return
        }
        amplitude = a
        if engine.attachedNodes.count <= 2, let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) {
            let node = AVAudioSourceNode { [unowned self] _, _, frames, list in
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                for i in 0..<Int(frames) {
                    let v = Float(sin(self.phase)) * self.amplitude
                    self.phase += 2 * .pi * 440 / 48000
                    for b in buffers { b.mData?.assumingMemoryBound(to: Float.self)[i] = v }
                }
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        playing = (try? engine.start()) != nil
    }
}

final class TestApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let tone = Tone()
    let soundButton = NSButton(title: "Sound: 440 Hz tone", target: nil, action: nil)
    var window: NSWindow!
    let status = NSTextField(labelWithString: "waiting for events")
    var presses = 0
    var signals: [DispatchSourceSignal] = []
    let danger = NSButton(title: "Delete character", target: nil, action: nil)

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.collectionBehavior = [.fullScreenPrimary]
        window.title = "PartyPortal Test"
        window.delegate = self
        let board = Board(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        board.autoresizingMask = [.width, .height]
        window.contentView = board

        let secret = NSTextField(labelWithString: "  Secret: alex@example.com · balance 12,345  ")
        secret.font = .systemFont(ofSize: 15, weight: .semibold)
        secret.drawsBackground = true
        secret.backgroundColor = .white
        secret.textColor = .black
        secret.frame = NSRect(x: 528, y: 60, width: 336, height: 72)
        secret.autoresizingMask = [.minXMargin, .maxYMargin]
        board.addSubview(secret)

        status.font = .monospacedSystemFont(ofSize: 20, weight: .medium)
        status.textColor = .white
        status.drawsBackground = true
        status.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        status.frame = NSRect(x: 40, y: 270, width: 620, height: 34)
        board.addSubview(status)

        danger.bezelColor = .systemRed
        danger.target = self
        danger.action = #selector(pressed)
        danger.frame = NSRect(x: 40, y: 500, width: 220, height: 40)
        danger.autoresizingMask = [.maxXMargin, .minYMargin]
        board.addSubview(danger)

        let field = NSTextField(string: "")
        field.placeholderString = "type here"
        field.frame = NSRect(x: 300, y: 505, width: 300, height: 28)
        field.autoresizingMask = [.maxXMargin, .minYMargin]
        board.addSubview(field)

        soundButton.target = self
        soundButton.action = #selector(sound)
        soundButton.frame = NSRect(x: 640, y: 500, width: 200, height: 40)
        soundButton.autoresizingMask = [.maxXMargin, .minYMargin]
        board.addSubview(soundButton)

        // Diagnostics (PP_TESTWIN_DUMP=1): every scroll event the app receives, with all its numeric fields,
        // whether or not a view ends up handling it. Used to compare a real wheel event with a synthetic one.
        if ProcessInfo.processInfo.environment["PP_TESTWIN_DUMP"] != nil {
            NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
                var fields: [String] = []
                if let cg = event.cgEvent {
                    for f in UInt32(0)..<200 {
                        let v = cg.getIntegerValueField(unsafeBitCast(f, to: CGEventField.self))
                        if v != 0 { fields.append("\(f)=\(v)") }
                    }
                    fields.append(String(format: "loc=%.0f,%.0f flags=%llx", cg.location.x, cg.location.y, cg.flags.rawValue))
                }
                let inWindow = event.locationInWindow
                let hit = event.window?.contentView?.superview?.hitTest(inWindow).map { String(describing: type(of: $0)) } ?? "nil"
                logHandle?.write(Data(("DUMP scroll win=\(event.windowNumber) inWindow=\(Int(inWindow.x)),\(Int(inWindow.y)) hit=\(hit) window=\(event.window != nil) " + fields.joined(separator: " ") + "\n").utf8))
                return event
            }
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(board)
        NSApp.activate(ignoringOtherApps: true)
        note("window opened")

        // For automated checks: SIGUSR1 resizes and moves the window, SIGUSR2 closes it, SIGHUP toggles full screen,
        // SIGALRM toggles a tone too quiet to hear (-48 dB) but easy to measure.
        for (sig, action) in [(SIGUSR1, { [unowned self] in self.window.setFrame(NSRect(x: 200, y: 200, width: 800, height: 500), display: true) }), (SIGUSR2, { [unowned self] in self.window.performClose(nil) }), (SIGHUP, { [unowned self] in self.window.toggleFullScreen(nil) }), (SIGALRM, { [unowned self] in self.tone.toggle(amplitude: 0.004); note(self.tone.playing ? "quiet tone on" : "tone off") })] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler(handler: action)
            src.resume()
            signals.append(src)
        }
    }

    @objc func sound() {
        tone.toggle(amplitude: 0.1)
        soundButton.title = tone.playing ? "Sound: turn off" : "Sound: 440 Hz tone"
        note(tone.playing ? "tone on" : "tone off")
    }

    @objc func pressed() {
        presses += 1
        danger.title = "PRESSED ×\(presses)"
        note("dangerous button pressed (\(presses))")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        note("window closed")
        return true
    }
    func windowDidResize(_ n: Notification) { note("resized: \(Int(window.frame.width))×\(Int(window.frame.height))") }
    func windowDidMove(_ n: Notification) { note("window moved: \(Int(window.frame.minX)) \(Int(window.frame.minY))") }
    func windowDidMiniaturize(_ n: Notification) { note("window minimized") }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        note("app quit")
        return .terminateNow
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = TestApp()
app.delegate = delegate
app.run()
