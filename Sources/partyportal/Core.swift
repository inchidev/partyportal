// Ties everything together: one shared window, one guest — or, through a portal that speaks relay protocol v2,
// several viewers of whom one at a time may control — and the host panel API.
// All state lives on the main queue; frames are handled on `videoQ`; the few values both touch sit behind `lock`.

import AppKit
import CoreMedia
import CoreVideo
import Foundation

private func orNull(_ value: String?) -> Any { value ?? NSNull() }

struct Options {
    var adminPort: UInt16 = 7373
    var guestPort: UInt16 = 7374
    var fake = false
    var dryInput = false
    var token: String?
    var configPath: String?
    var inputLog: String?
    var autoWindow: String?
    var openPanel = true
    var webDir: String?
    /// For scripts and agents: open the public link right away, start view-only, and print the link as one JSON line.
    var publicLink = false
    var viewOnly = false
    var printLink = false
    /// Force the input mode for this run: "background" or "takeover" (same as the choice in the host panel).
    var inputMode: String?
    /// A portal on an L4 Server instead of the tunnel: its page (https://…/portal/<id>) and this Mac's key there.
    /// The guest's key is `token`.
    var portalURL: String?
    var portalKey: String?
    /// Where a portal is opened when there is no Server of your own (POST <origin>/api/portals, no account).
    var rendezvous = "https://llll.gg"
}

final class Core {
    private final class Guest {
        let ws: GuestSocket
        let since = Date().timeIntervalSince1970
        var control = false
        /// What the guest's page says it shows, once a second.
        var fps = -1, late = 0, behind = 0, warned = false
        /// A viewer of a v2 portal: the portal's name for it, its number in the journal and panel, and whether it
        /// is waiting for the host to give it control.
        var id: String?
        var n = 0
        var asked = false
        init(ws: GuestSocket) { self.ws = ws }
        var name: String { id == nil ? "Guest" : "Viewer \(n)" }
    }

    let opts: Options
    private let store: ConfigStore
    private var settings: Settings
    private let webDir: URL?
    private var admin: HTTPServer!
    private var guestServer: HTTPServer!
    private let tunnel = Tunnel()
    /// Portal mode: the guest's page and socket live on an L4 Server and this Mac dials out to it.
    private var portal: PortalLink?
    private let videoQ = DispatchQueue(label: "partyportal.video", qos: .userInteractive)

    // Main queue
    private var target: WindowInfo?
    private var source: FrameSource?
    private var input: InputController?
    private var realInput: RealInput?
    /// The one guest of v1: a local page, or one relayed by a v1 portal.
    private var guest: Guest?
    /// The viewers of a v2 portal, oldest first. Each has passed its own token check; their picture comes from the
    /// portal's SFU, which the bridge publishes to once, and only `controller` may give input.
    private var viewers: [Guest] = []
    private var viewersSeen = 0
    /// SFU publications of the bridge that are connected ("" for the portal's SFU; a viewer's name on a stand-in
    /// that has none and gets one publication per viewer).
    private var sfuLive: Set<String> = []
    private var sfuInfo: [String: Any] = [:]
    private var sfuRetry: DispatchWorkItem?
    private var sfuBackoff = 2.0
    private var token: String
    private var log: [[String: Any]] = []
    private var windowFrame = CGRect.zero
    private var lockedFrame: CGRect?
    private var lastGuestAction = 0.0
    private var lastGuardNote = 0.0
    private var lastResizeNote = 0.0
    private var lastBlockNote = 0.0
    private var lastBlockText = ""
    private var pauseReason: String?
    private var titleZones: [CGRect] = []
    private var resizable = true
    private var tickCount = 0
    private var linkPrinted = false
    private var missingTicks = 0
    private var timer: Timer?
    private var fps = 0
    private var kbps = 0
    private var thumbs: [UInt32: (Double, Data)] = [:]
    private var awake: NSObjectProtocol?
    private var noNap: NSObjectProtocol?
    private var virtualDisplay: VirtualDisplay?
    private var parkedFrom: CGRect?
    private var ownMoveUntil = 0.0

    // Direct connection (WebRTC through the bridge page in an invisible web view)
    private let turn: TurnRelay
    private var turnWarned = false
    /// The portal came from the rendezvous (llll.gg): when it ends, "Open public access" makes a new one.
    private var portalFromRendezvous = false
    private var portalExpires: Double?
    private var rendezvousBusy = false
    private var rendezvousError: String?
    private let bridgeHost = BridgeHost()
    private let bridgeSecret = Core.newToken()
    private var bridgeWS: WebSocket?
    private var rtcUp = false
    /// The bridge sends video as a WebRTC media track: it re-encodes what we give it and steers the bitrate itself.
    private var trackMode = false
    /// For the hop to the bridge inside this Mac, bandwidth is free: encode well above what will be sent on.
    private var localKbps: Int { trackMode ? min(40_000, max(12_000, settings.video.kbps * 2)) : settings.video.kbps }
    private var rtcPath = ""
    private var bridgeDiag: [String: Any] = [:]
    private var liveKbps = 0
    private var lastSqueeze = 0.0

    // Shared with the video queue and the encoder's callback thread
    private let lock = NSLock()
    private var hideRects: [CGRect] = []
    private var viewer: GuestSocket?
    private var keyRequested = false
    private var statFrames = 0
    private var statBytes = 0
    private var videoSize = (0, 0)
    private var audioOn = true
    private var generation = 0

    // Video queue
    private var encoder: H264Encoder?
    private let masker = Masker()
    private var lastRaw: CVPixelBuffer?
    private var lastPts: Int64 = 0
    private var dropping = false  // encoder callback thread only

    // Written on the main queue under `lock`, used on the source's audio queue
    private var opus: OpusEncoder?

    init(_ opts: Options) {
        self.opts = opts
        store = ConfigStore(path: opts.configPath)
        turn = TurnRelay(configDir: store.url.deletingLastPathComponent())
        settings = store.load()
        token = opts.token ?? Core.newToken()
        webDir = Core.findWebDir(opts.webDir)
        audioOn = settings.video.audio
        liveKbps = settings.video.kbps
        if let mode = opts.inputMode { settings.background.mode = mode }
    }

    private var uptime: Double { ProcessInfo.processInfo.systemUptime }

    private var allGuests: [Guest] { (guest.map { [$0] } ?? []) + viewers }
    /// Whoever may give input right now: the v1 guest or one viewer, never two.
    private var controller: Guest? { allGuests.first { $0.control } }
    /// Connected to a portal that speaks v2: several viewers through its SFU.
    private var portalV2: Bool { portal?.status == .ready && portal?.version == 2 }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func findWebDir(_ explicit: String?) -> URL? {
        var candidates: [URL] = []
        if let explicit { candidates.append(URL(fileURLWithPath: explicit)) }
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("web")) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("web"))
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("web"))
            dir = dir.deletingLastPathComponent()
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("guest.html").path) }
    }

    private func page(_ name: String) -> HTTPResponse {
        guard let webDir, let data = try? Data(contentsOf: webDir.appendingPathComponent(name)) else {
            return HTTPResponse(status: 500, contentType: "text/plain; charset=utf-8", body: Data("The web folder was not found next to the program".utf8))
        }
        return .data(data, type: "text/html; charset=utf-8")
    }

    private func addLog(_ kind: String, _ text: String) {
        log.append(["t": Int(Date().timeIntervalSince1970 * 1000), "kind": kind, "text": text])
        if log.count > 200 { log.removeFirst(log.count - 200) }
        // The journal goes to stderr: stdout is kept for the single machine-readable line of --print-link.
        FileHandle.standardError.write(Data("[\(kind)] \(text)\n".utf8))
    }

    // MARK: Start / stop

    func start() throws {
        admin = try HTTPServer(port: opts.adminPort)
        guestServer = try HTTPServer(port: opts.guestPort)
        admin.onRequest = { [unowned self] req, reply in self.adminRequest(req, reply) }
        guestServer.onRequest = { [unowned self] req, reply in
            reply(req.method == "GET" && req.path == "/" ? self.page("guest.html") : .fail(404, "not found"))
        }
        guestServer.onWebSocket = { [unowned self] req in
            req.path == "/ws" ? { ws in self.guestOpened(ws) } : nil
        }
        // The bridge page lives on the panel's port, which never leaves this Mac, and needs the per-launch secret.
        admin.onWebSocket = { [unowned self] req in
            guard req.path == "/bridge", self.adminAllowed(req), req.query["k"] == self.bridgeSecret else { return nil }
            return { ws in self.bridgeOpened(ws) }
        }
        // A windowless app is a prime App Nap target, and throttled timers mean late input and frames.
        noNap = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "PartyPortal: sharing a window")
        for server in [admin!, guestServer!] {
            server.onFail = { [unowned self] _ in
                // Most likely PartyPortal is already running: show its panel instead of starting a second copy.
                FileHandle.standardError.write(Data("Port \(server.port) is in use — PartyPortal seems to be running already.\n".utf8))
                if self.opts.openPanel || self.opts.portalURL != nil || self.pendingPortal != nil { self.wakeRunningCopy() }
                exit(1)
            }
        }
        admin.start()
        guestServer.start()
        tunnel.onChange = { [unowned self] in
            if let url = self.tunnel.url { self.addLog("info", "Public link is ready: \(url)") }
            self.printLinkIfReady()
        }
        if opts.viewOnly { settings.locks.viewOnly = true }
        if let page = opts.portalURL {
            // Not before the ports are surely ours: a second copy that dialled the portal before finding them taken
            // would push the running copy out of it (4409, final). A busy port exits within this delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let error = self.usePortal(page: page, key: self.opts.portalKey ?? "", token: self.opts.token ?? "") {
                    FileHandle.standardError.write(Data("--portal: \(error)\n".utf8))
                    exit(2)
                }
            }
        } else if opts.publicLink {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openPublicLink { _ in } }  // after the ports are ours, as above
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [unowned self] _ in self.tick() }
        if let url = URL(string: "http://127.0.0.1:\(opts.adminPort)/bridge.html?k=\(bridgeSecret)") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.bridgeHost.start(url: url) }
        }
        addLog("info", "Host panel: http://127.0.0.1:\(opts.adminPort)")
        if turn.configured { addLog("info", "TURN relay is set up: guests behind strict networks connect through it") }
        if opts.fake {
            startFake()
        } else if let wanted = opts.autoWindow {
            Task { @MainActor in
                let match = (try? await WindowCapture.list())?.first { $0.title.localizedCaseInsensitiveContains(wanted) || $0.app.localizedCaseInsensitiveContains(wanted) }
                if let match { self.share(windowID: match.id) { _ in } } else { self.addLog("warn", "Window “\(wanted)” not found") }
            }
        }
        // Give a failed bind a moment to report before opening the panel.
        if opts.openPanel { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.openPanel() } }
    }

    func shutdown() {
        unpark(wait: true)
        input?.releaseAll()
        tunnel.stop()
        portal?.stop()
        source?.stop()
    }

    /// Set by the app: shows the host's window. Without it (a bare binary, tests) the panel opens in the browser.
    var showPanel: (() -> Void)?

    func openPanel() {
        if let showPanel { return showPanel() }
        if let url = URL(string: "http://127.0.0.1:\(opts.adminPort)") { NSWorkspace.shared.open(url) }
    }

    /// The menu bar's shortcuts for what the panel's buttons do.
    func hostAction(_ name: String) {
        switch name {
        case "stop":
            stopShare(note: nil)
        case "kick":
            if let g = guest {
                g.ws.send(json: ["type": "bye", "final": true, "reason": "The host closed access."])
                g.ws.close(code: 4002)
                dropGuest(note: "Guest removed by the host")
            }
            for v in viewers { kickViewer(v) }
        case "revoke":
            revokeControl(note: "You took control back")
        default:
            break
        }
    }

    /// A portal this copy was asked to open (`partyportal://portal?…` or `--portal`) before it knew whether it
    /// is the copy that keeps running. `ask`: it came from a link, so the host confirms it first.
    var pendingPortal: (page: String, key: String, token: String, ask: Bool)?

    /// PartyPortal is already running (its ports are taken): ask that copy to show its window — or to switch
    /// to the portal this copy was given — then leave.
    private func wakeRunningCopy() {
        var path = "/api/show", body: [String: Any] = [:]
        if let p = pendingPortal ?? opts.portalURL.map({ ($0, opts.portalKey ?? "", opts.token ?? "", false) }) {
            path = "/api/portal"
            body = ["url": p.0, "key": p.1, "t": p.2, "ask": p.3]
        }
        guard let url = URL(string: "http://127.0.0.1:\(opts.adminPort)\(path)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1.5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 2)
    }

    /// Frames carry the generation they were captured for; anything from a stopped source is ignored.
    private func nextGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        return generation
    }

    private func startFake() {
        stopShare(note: nil)
        let src = FakeSource(queue: videoQ, video: settings.video)
        begin(FakeSource.windowInfo, source: src, generation: nextGeneration())
        src.start()
    }

    private func share(windowID: UInt32, done: @escaping (String?) -> Void) {
        stopShare(note: nil)
        let capture = WindowCapture(queue: videoQ, video: settings.video)
        let gen = nextGeneration()
        Task { @MainActor in
            do {
                let info = try await capture.start(windowID: windowID)
                guard self.currentGeneration == gen else { return capture.stop() }  // another share started meanwhile
                self.begin(info, source: capture, generation: gen)
                done(nil)
            } catch {
                capture.stop()
                self.addLog("warn", "Could not share the window: \(error.localizedDescription)")
                done(error.localizedDescription)
            }
        }
    }

    private var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func begin(_ info: WindowInfo, source src: FrameSource, generation gen: Int) {
        target = info
        source = src
        windowFrame = info.frame
        lockedFrame = info.frame
        pauseReason = nil
        missingTicks = 0
        // Masks go in before the encoder exists, so no frame of this window can be encoded without them.
        lock.lock()
        hideRects = masks.filter { $0.hide }.map { $0.rect }
        lock.unlock()
        let enc = H264Encoder(kbps: liveKbps, fps: settings.video.fps)
        enc.onConfig = { [weak self] codec, avcC, w, h in self?.videoConfig(codec, avcC, w, h) }
        enc.onFrame = { [weak self] data, isKey, micros in self?.videoFrame(data, isKey, micros) }
        videoQ.sync { self.encoder = enc }
        let audio = OpusEncoder()
        audio?.onPacket = { [weak self] packet, micros in self?.audioPacket(packet, micros) }
        lock.lock()
        opus = audio
        lock.unlock()
        attach(src, generation: gen)

        let ctl = InputController(backend: makeBackend(for: info))
        ctl.locks = { [unowned self] in self.settings.locks }
        ctl.zones = { [unowned self] in self.zones() }
        ctl.frame = { [unowned self] in self.windowFrame }
        ctl.pauseReason = { [unowned self] in self.pauseReason }
        ctl.onActivity = { [unowned self] in self.lastGuestAction = self.uptime }
        ctl.onBlocked = { [unowned self] what, why in self.blocked(what, why) }
        ctl.refresh = { [unowned self] in
            guard let t = self.target, let real = self.realInput, let (_, onScreen) = WindowQuery.frame(t.id) else { return }
            self.setPause(real.pauseReason(onScreen: onScreen))
        }
        input = ctl

        pointerPollingEngine = opts.fake ? nil : AppCompat.pointerPollingEngine(pid: info.pid)
        warnAboutPointerPolling()
        refreshZones()
        publishMasks()
        printLinkIfReady()
        if backgroundActive, settings.background.park { park(info) }
        addLog("info", "Sharing window “\(info.title.isEmpty ? info.app : info.title)”")
        sendState()
    }

    /// Connect a frame source to the video and audio pipelines of the current share.
    private func attach(_ src: FrameSource, generation gen: Int) {
        src.onFrame = { [weak self] pb, pts in self?.handleFrame(pb, pts, gen) }
        src.onAudio = { [weak self] l, r in
            guard let self, gen == self.currentGeneration, self.wantsAudio else { return }
            self.lock.lock()
            let encoder = self.opus
            self.lock.unlock()
            encoder?.append(l, r)
        }
        // A capture that stops is not always a closed window: going full screen or changing Space can end the
        // stream while the window lives on. Look again a moment later and pick it back up if it is still there.
        src.onStop = { [weak self] why in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let self, self.currentGeneration == gen, let t = self.target else { return }
                if t.id != 0, WindowQuery.frame(t.id) != nil { self.restartCapture() } else { self.stopShare(note: "Window closed — sharing stopped") }
            }
        }
    }

    private func restartCapture() {
        guard let t = target, !opts.fake else { return }
        source?.stop()
        let capture = WindowCapture(queue: videoQ, video: settings.video)
        let gen = nextGeneration()
        Task { @MainActor in
            do {
                _ = try await capture.start(windowID: t.id)
                guard self.currentGeneration == gen, self.target?.id == t.id else { return capture.stop() }
                self.source = capture
                self.attach(capture, generation: gen)
                self.addLog("info", "Window capture restarted")
                self.kickVideo()
            } catch {
                guard self.currentGeneration == gen else { return }
                self.stopShare(note: "Sharing was interrupted: \(error.localizedDescription)")
            }
        }
    }

    /// `--print-link`: one JSON line on stdout as soon as there is a window to show and a link to give out.
    private func printLinkIfReady() {
        guard opts.printLink, !linkPrinted, let t = target else { return }
        if portal == nil {
            if opts.portalURL != nil { return }  // the portal starts a moment after launch
            if opts.publicLink, tunnel.url == nil { return }
        }
        linkPrinted = true
        var line: [String: Any] = ["type": "link", "window": t.title.isEmpty ? t.app : t.title, "local": "http://127.0.0.1:\(opts.guestPort)/#t=\(token)"]
        if let url = publicLink { line["url"] = url }
        if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    /// Background mode applies to real windows with real input, and needs the system calls that carry the mouse.
    /// Without them the guest gets the host's pointer instead, which always works.
    private var backgroundActive: Bool {
        settings.background.mode != "takeover" && BackgroundInput.available && !opts.fake && !opts.dryInput
    }

    /// Set when the shared app is built on an engine known to read the pointer from the system, not from events:
    /// in the background its mouse will not follow the guest.
    private var pointerPollingEngine: String?

    private func makeBackend(for info: WindowInfo) -> InputBackend {
        if opts.fake || opts.dryInput {
            realInput = nil
            return DryInput(path: opts.inputLog ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("partyportal-input.log"))
        }
        if backgroundActive {
            let background = BackgroundInput(pid: info.pid, windowID: info.id)
            background.frame = { [unowned self] in self.windowFrame }
            realInput = nil
            return background
        }
        if settings.background.mode != "takeover" {
            addLog("warn", "This macOS lacks what background mode needs: the guest will use your pointer instead")
        }
        let real = RealInput(pid: info.pid, windowID: info.id)
        realInput = real
        return real
    }

    private func warnAboutPointerPolling() {
        guard backgroundActive, let engine = pointerPollingEngine else { return }
        addLog("warn", "This app is built on \(engine), which reads the pointer from the system: in the background the guest's keyboard works in it, the mouse does not. Switch to “guest uses my pointer” to give them the mouse.")
    }

    /// The host switched background mode or parking while a window is shared.
    private func switchBackground() {
        guard let info = target, let input, !opts.fake, !opts.dryInput else { return }
        input.releaseAll()
        input.backend = makeBackend(for: info)
        if backgroundActive, settings.background.park {
            if virtualDisplay == nil { park(info) }
        } else {
            unpark()
        }
        addLog("info", backgroundActive ? "The guest works in the background: your pointer and front app are left alone" : "The guest uses your pointer: keep the shared window in front")
        warnAboutPointerPolling()
        pauseReason = nil
        sendState()
    }

    /// Move the shared window onto a monitor that exists only in software: nothing can cover it there,
    /// so its app keeps drawing, and it is out of the host's way.
    private func park(_ info: WindowInfo) {
        guard AX.trusted else { return addLog("warn", "Virtual display needs the Accessibility permission") }
        // A window on another Space (a game in full screen, for one) is not among the ones Accessibility can move.
        // It is not covered there either, so it is left where it is.
        guard let window = AX.window(pid: info.pid, id: info.id) else { return }
        // A window in full screen already lives on a Space of its own: it is not covered there, and it cannot be moved.
        if AX.isFullScreen(window) { return addLog("info", "The window is in full screen on its own Space: left where it is") }
        let wide = (max(Int(info.frame.width), 640) + 1) & ~1, high = (max(Int(info.frame.height) + 60, 480) + 1) & ~1
        guard let display = VirtualDisplay(name: "PartyPortal", pointsWide: wide, pointsHigh: high) else { return addLog("warn", "Virtual display is not available: \(VirtualDisplay.lastFailure)") }
        virtualDisplay = display
        parkedFrom = info.frame
        func place(_ attempt: Int) {
            guard self.virtualDisplay === display, self.target?.id == info.id else { return }
            let b = display.bounds
            if CGDisplayIsActive(display.displayID) != 0, b.width > 0 {
                display.moveOutOfTheWay()
                let b = display.bounds
                self.ownMoveUntil = self.uptime + 2
                AX.setFrame(window, CGRect(x: b.minX, y: b.minY + 40, width: info.frame.width, height: info.frame.height))
                self.addLog("info", "Window parked on a virtual display (\(Int(b.width))×\(Int(b.height)) at \(Int(b.minX)),\(Int(b.minY)))")
            } else if attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { place(attempt + 1) }
            } else {
                self.addLog("warn", "Virtual display did not come up")
            }
        }
        place(0)
    }

    /// Let the virtual monitor go and bring the window back to where it was.
    /// The order matters: when a monitor disappears macOS re-fits the windows that were on it (a 960×628 window
    /// came back as 286×188), so the old frame is restored only after that has happened.
    private func unpark(wait: Bool = false) {
        guard let display = virtualDisplay else { return }
        let from = parkedFrom
        let owner = target.map { ($0.pid, $0.id) }
        parkedFrom = nil
        virtualDisplay = nil
        ownMoveUntil = uptime + 3
        display.remove()
        let restore = { [weak self] in
            guard let from, let owner, AX.trusted, let window = AX.window(pid: owner.0, id: owner.1) else { return }
            self?.ownMoveUntil = (self?.uptime ?? 0) + 2
            AX.setFrame(window, from)
        }
        if wait {  // on the way out of the app there is no later
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            restore()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restore)
        }
    }

    private func stopShare(note: String?) {
        guard target != nil else { return }
        unpark()
        input?.releaseAll()
        input = nil
        realInput = nil
        lock.lock()
        opus = nil
        lock.unlock()
        source?.stop()
        source = nil
        target = nil
        for g in allGuests {
            g.control = false
            g.asked = false
        }
        _ = nextGeneration()
        lock.lock()
        hideRects = []
        lock.unlock()
        videoQ.sync {
            self.encoder?.invalidate()
            self.encoder = nil
            self.lastRaw = nil
        }
        addLog("info", note ?? "Sharing stopped")
        sendState()
    }

    // MARK: Video (video queue)

    private func handleFrame(_ pb: CVPixelBuffer, _ pts: CMTime, _ gen: Int) {
        guard gen == currentGeneration else { return }
        lastRaw = pb
        encodeFrame(pb, pts, forceKey: false)
    }

    private func encodeFrame(_ pb: CVPixelBuffer, _ pts: CMTime, forceKey: Bool) {
        lock.lock()
        let rects = hideRects
        let watched = viewer != nil
        let key = keyRequested || forceKey
        if watched { keyRequested = false }
        lock.unlock()
        guard watched, let encoder else { return }
        var frame = pb
        if !rects.isEmpty {
            // No masked copy, no frame: an unmasked picture must never be sent.
            guard let copy = masker.masked(pb, rects: rects) else { return }
            frame = copy
        }
        let micros = max(Int64(CMTimeGetSeconds(pts) * 1_000_000), lastPts + 1)
        lastPts = micros
        encoder.encode(frame, pts: CMTime(value: micros, timescale: 1_000_000), forceKey: key)
    }

    /// A fresh keyframe from the last picture: for a guest who just joined, or after the masks changed on a still window.
    private func reencodeLast() {
        if let raw = lastRaw { encodeFrame(raw, hostTimeNow(), forceKey: true) }
    }

    private func requestKey() {
        lock.lock()
        keyRequested = true
        lock.unlock()
        videoQ.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let still = self.keyRequested
            self.lock.unlock()
            if still { self.reencodeLast() }
        }
    }

    private func videoConfig(_ codec: String, _ avcC: Data, _ w: Int, _ h: Int) {
        lock.lock()
        videoSize = (w, h)
        let v = viewer
        lock.unlock()
        v?.send(json: ["type": "video", "codec": codec, "description": avcC.base64EncodedString(), "width": w, "height": h])
    }

    private func videoFrame(_ data: Data, _ isKey: Bool, _ micros: Int64) {
        lock.lock()
        statFrames += 1
        statBytes += data.count
        let v = viewer
        lock.unlock()
        guard let ws = v else { return }
        // A slow link: stop feeding it, then resume from a keyframe once the queue has drained.
        if dropping {
            if ws.pendingBytes > 200_000 { return }
            if !isKey { return requestKey() }
            dropping = false
        } else if ws.pendingBytes > 1_500_000 {
            dropping = true
            DispatchQueue.main.async { [weak self] in self?.squeeze() }
            return
        }
        var msg = Data(capacity: data.count + 10)
        msg.append(1)
        msg.append(isKey ? 1 : 0)
        for i in (0..<8).reversed() { msg.append(UInt8((UInt64(bitPattern: micros) >> (UInt64(i) * 8)) & 0xff)) }
        msg.append(data)
        ws.send(binary: msg)
    }

    // MARK: Audio

    /// Someone is listening and the host has not switched sound off.
    private var wantsAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return viewer != nil && audioOn
    }

    private func audioPacket(_ packet: Data, _ micros: Int64) {
        lock.lock()
        let v = viewer
        lock.unlock()
        // Sound is the first thing to go on a slow link: it must never queue up behind video.
        guard let ws = v, ws.pendingBytes < 300_000 else { return }
        var msg = Data(capacity: packet.count + 10)
        msg.append(2)
        msg.append(0)
        for i in (0..<8).reversed() { msg.append(UInt8((UInt64(bitPattern: micros) >> (UInt64(i) * 8)) & 0xff)) }
        msg.append(packet)
        ws.send(binary: msg)
    }

    /// Start (or restart) the picture for the current viewer: config first, then a keyframe.
    private func kickVideo() {
        videoQ.async { [weak self] in
            guard let self else { return }
            self.encoder?.announceConfig()
            self.reencodeLast()
        }
    }

    // MARK: Masks and zones

    private var masks: [MaskRect] { target.flatMap { settings.masksByApp[$0.appKey] } ?? [] }

    private func publishMasks() {
        let rects = masks.filter { $0.hide }.map { $0.rect }
        lock.lock()
        hideRects = rects
        lock.unlock()
        videoQ.async { [weak self] in self?.reencodeLast() }
    }

    private func refreshZones() {
        guard let t = target, windowFrame.width > 1, windowFrame.height > 1 else { return }
        let f = windowFrame
        var buttons: [CGRect]? = nil
        if !opts.fake, AX.trusted, let el = AX.window(pid: t.pid, id: t.id) {
            buttons = AX.titleButtons(el)
            resizable = AX.isResizable(el)
        }
        // Without accessibility data, assume the usual traffic lights in the top-left corner.
        let global = buttons ?? [CGRect(x: f.minX, y: f.minY, width: 78, height: 32)]
        titleZones = global.map { b in
            let r = b.insetBy(dx: -6, dy: -6)
            return CGRect(x: (r.minX - f.minX) / f.width, y: (r.minY - f.minY) / f.height, width: r.width / f.width, height: r.height / f.height)
        }
    }

    private func zones() -> [Zone] {
        var z = masks.filter { $0.block }.map { Zone(rect: $0.rect, why: "area “\($0.name)” is blocked by the host") }
        let l = settings.locks
        if l.titleButtons { z += titleZones.map { Zone(rect: $0, why: "window buttons") } }
        if l.edges, resizable, windowFrame.width > 20, windowFrame.height > 20 {
            let ex = 5 / windowFrame.width, ey = 5 / windowFrame.height
            for r in [CGRect(x: 0, y: 0, width: ex, height: 1), CGRect(x: 1 - ex, y: 0, width: ex, height: 1), CGRect(x: 0, y: 0, width: 1, height: ey), CGRect(x: 0, y: 1 - ey, width: 1, height: ey)] {
                z.append(Zone(rect: r, why: "window edge"))
            }
        }
        return z
    }

    private func blocked(_ what: String, _ why: String) {
        let text = "Guest: \(what) — \(why)"
        let now = uptime
        if text == lastBlockText, now - lastBlockNote < 2 { return }
        lastBlockText = text
        lastBlockNote = now
        addLog("block", text)
        (controller ?? guest)?.ws.send(json: ["type": "blocked", "what": what, "why": why])
    }

    // MARK: Monitor

    private func tick() {
        tickCount += 1
        if tickCount % 10 == 0 {
            lock.lock()
            fps = statFrames
            kbps = statBytes * 8 / 1000
            statFrames = 0
            statBytes = 0
            lock.unlock()
            bridgeWS?.send(json: ["s": "tick", "kbps": trackMode ? settings.video.kbps : liveKbps])
            // The link has been keeping up for a while: creep back towards the bitrate the host asked for.
            if !trackMode, liveKbps < settings.video.kbps, uptime - lastSqueeze > 8 {
                lastSqueeze = uptime - 4
                setLiveKbps(min(settings.video.kbps, liveKbps * 115 / 100 + 50))
            }
        }
        guard let t = target, !opts.fake else { return }
        guard let (frame, onScreen) = WindowQuery.frame(t.id) else {
            // macOS hides a window from the list for a moment while it animates into or out of full screen.
            missingTicks += 1
            if missingTicks > 25 { stopShare(note: "Window closed — sharing stopped") }
            return
        }
        missingTicks = 0
        if frame.size != windowFrame.size {
            source?.resize(points: frame.size)
            // Masks are stored as fractions of the window, and a resized window may lay its content out differently.
            if !masks.isEmpty, uptime - lastResizeNote > 5 {
                lastResizeNote = uptime
                addLog("warn", "The window was resized — check that the masks still cover what they should")
            }
        }
        windowFrame = frame
        target?.frame = frame
        guardFrame(frame, t)
        if !onScreen, settings.locks.frameGuard, controller != nil, uptime - lastGuestAction < 1.5, AX.trusted, let el = AX.window(pid: t.pid, id: t.id) {
            AX.unminimize(el)
            blocked("window", "minimizing is not allowed — restored")
        }
        if tickCount % 5 == 0 { refreshZones() }
        setPause(realInput?.pauseReason(onScreen: onScreen))
    }

    private func setPause(_ reason: String?) {
        guard reason != pauseReason else { return }
        pauseReason = reason
        if reason != nil { input?.releaseAll() }
        sendState()
    }

    /// Soft lock on the window's position and size: if it changed right after the guest acted, put it back.
    private func guardFrame(_ frame: CGRect, _ t: WindowInfo) {
        guard let locked = lockedFrame, frame != locked else { return }
        // We are moving the window ourselves (to or from the virtual display): wherever it lands is its place.
        if uptime < ownMoveUntil {
            lockedFrame = frame
            return
        }
        let guestDriven = controller != nil && (input?.buttonHeld == true || uptime - lastGuestAction < 1.0)
        guard settings.locks.frameGuard, guestDriven, AX.trusted, let el = AX.window(pid: t.pid, id: t.id) else {
            lockedFrame = frame  // the host moved it: that is the new place
            return
        }
        AX.setFrame(el, locked)
        if uptime - lastGuardNote > 2 {
            lastGuardNote = uptime
            blocked("window", "moving and resizing is not allowed — put back")
        }
    }

    // MARK: Guest

    private func sendState() {
        for g in allGuests { sendState(g) }
    }

    private func sendState(_ g: Guest) {
        var state: [String: Any] = [
            "type": "state", "sharing": target != nil, "title": target?.app ?? "", "control": g.control,
            "viewOnly": settings.locks.viewOnly, "paused": orNull(pauseReason),
            "background": target != nil && backgroundActive, "mouse": !(target != nil && backgroundActive && pointerPollingEngine != nil),
            "audio": target != nil && opus != nil && settings.video.audio
                ? ["codec": "opus", "sampleRate": Int(OpusEncoder.sampleRate), "channels": 2] as [String: Any] : NSNull() as Any,
        ]
        if g.id != nil {
            // A viewer asks for control and the host gives it; its sound comes as a track from the SFU, not as packets.
            state["ask"] = true
            state["asked"] = g.asked
            state["viewers"] = viewers.count
            state["audio"] = NSNull()
        }
        g.ws.send(json: state)
    }

    private func tokenMatches(_ candidate: String) -> Bool {
        let a = Array(candidate.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    private func guestOpened(_ ws: GuestSocket) {
        ws.onText = { [weak self, weak ws] text in
            guard let self, let ws else { return }
            self.guestMessage(ws, text)
        }
        ws.onClose = { [weak self, weak ws] in
            guard let self, let ws else { return }
            if let v = self.viewers.first(where: { $0.ws === ws }) { return self.dropViewer(v, note: "\(v.name) left") }
            guard self.guest?.ws === ws else { return }
            self.dropGuest(note: "Guest disconnected")
        }
        // No valid token within five seconds: hang up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak ws] in
            guard let self, let ws, self.guest?.ws !== ws, !self.viewers.contains(where: { $0.ws === ws }) else { return }
            ws.close(code: 4001)
        }
    }

    private func dropGuest(note: String) {
        guard guest != nil else { return }
        input?.releaseAll()
        guest = nil
        rtcUp = false
        rtcPath = ""
        if trackMode {
            trackMode = false
            liveKbps = 0
            setLiveKbps(localKbps)
        }
        bridgeWS?.send(json: ["s": "reset"])
        lock.lock()
        viewer = nil
        lock.unlock()
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        addLog("info", note)
    }

    private func guestMessage(_ ws: GuestSocket, _ text: String) {
        guard let m = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let type = m["t"] as? String else { return }
        if let v = viewers.first(where: { $0.ws === ws }) { return viewerMessage(v, m, type) }
        guard let g = guest, g.ws === ws else {
            guard type == "auth", let candidate = m["token"] as? String, tokenMatches(candidate) else {
                ws.send(json: ["type": "bye", "final": true, "reason": "This link does not work. Ask the host for a new one."])
                return ws.close(code: 4003)
            }
            // A v2 portal's guest: one viewer among several, with its own state and its picture from the SFU.
            if let relayed = ws as? RelayedGuest, relayed.g != nil { return viewerJoined(relayed) }
            if portalV2 {
                // The picture goes to the portal's SFU now; a page on this Mac's own port would have none.
                ws.send(json: ["type": "bye", "final": true, "reason": "This share has several viewers through its portal: open the portal's link instead."])
                return ws.close(code: 4005)
            }
            if let old = guest {  // the same link opened again: the newer page wins
                old.ws.send(json: ["type": "bye", "final": true, "reason": "This link was opened somewhere else."])
                old.ws.close(code: 4000)
                dropGuest(note: "Guest reconnected")
            }
            guest = Guest(ws: ws)
            lock.lock()
            viewer = ws
            lock.unlock()
            // A guest is watching: do not let the display or the Mac fall asleep under them.
            awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "PartyPortal: a guest is connected")
            addLog("info", "Guest connected (\(ws.remote))")
            sendState()
            kickVideo()
            // The invitation to connect directly waits for the relay credential (a moment, a few seconds at worst);
            // video already flows over this socket meanwhile. A portal that handed out its own servers needs no wait.
            let invited = guest
            if let servers = iceOverride {
                let direct = bridgeWS != nil && settings.video.direct
                ws.send(json: ["type": "hello", "rtc": direct ? ["iceServers": servers] as [String: Any] : NSNull() as Any])
                return
            }
            turn.servers { [weak self] servers, relay in
                guard let self, let g = self.guest, g === invited else { return }
                if self.turn.configured, !relay, !self.turnWarned {
                    self.turnWarned = true
                    self.addLog("warn", "TURN relay did not answer — trying a direct connection without it")
                }
                let direct = self.bridgeWS != nil && self.settings.video.direct
                g.ws.send(json: ["type": "hello", "rtc": direct ? ["iceServers": servers] as [String: Any] : NSNull() as Any])
            }
            return
        }
        switch type {
        case "rtc-offer":
            guard let sdp = m["sdp"] as? String, sdp.count < 20000, settings.video.direct, let bridge = bridgeWS else { return }
            rtcDown(note: nil)
            bridge.send(json: ["s": "offer", "sdp": sdp, "ice": iceServers])
        case "rtc-cand":
            if let c = m["c"] as? [String: Any] { bridgeWS?.send(json: ["s": "cand", "c": c]) }
        case "rtc-off":
            let slow = (m["why"] as? String) == "slow"
            rtcDown(note: slow ? "The UDP path to the guest loses too much — video goes via the tunnel instead" : "Direct connection failed — video goes via relay")
            bridgeWS?.send(json: ["s": "reset"])
        case "ping":
            ws.send(json: ["type": "pong", "n": m["n"] ?? 0])
        default:
            guestCommand(g, m, type)
        }
    }

    /// What an authenticated guest may ask for; arrives over the WebSocket or, when direct, through the bridge.
    private func guestCommand(_ g: Guest, _ m: [String: Any], _ type: String) {
        switch type {
        case "control" where g.id != nil:
            // A viewer asks, and waits for the host; giving it up needs nobody's leave.
            if (m["ask"] as? Bool) == true || (m["on"] as? Bool) == true {
                guard !g.control, !g.asked else { break }
                g.asked = !settings.locks.viewOnly && target != nil
                if g.asked { addLog("info", "\(g.name) asks for control — give it on the Share page") }
            } else {
                if g.control {
                    g.control = false
                    input?.releaseAll()
                    addLog("info", "\(g.name) gave control back")
                }
                g.asked = false
            }
            sendState(g)
        case "control":
            let on = (m["on"] as? Bool) ?? false
            g.control = on && !settings.locks.viewOnly && target != nil
            if !g.control { input?.releaseAll() }
            if g.control, pauseReason == "unfocused", settings.locks.autoFocus { input?.backend.focus() }
            sendState()
        case "kf":
            requestKey()
        case "stat":
            guestStat(g, fps: (m["fps"] as? NSNumber)?.intValue ?? -1, late: (m["late"] as? NSNumber)?.intValue ?? 0, skipped: (m["skipped"] as? NSNumber)?.intValue ?? 0)
        case "auth", "ping", "rtc-offer", "rtc-cand", "rtc-off":
            break
        default:
            if g.control { input?.handle(m) }
        }
    }

    // MARK: Viewers (relay protocol v2)

    private func viewerJoined(_ ws: RelayedGuest) {
        guard let id = ws.g else { return }
        let v = Guest(ws: ws)
        v.id = id
        viewersSeen += 1
        v.n = viewersSeen
        viewers.append(v)
        if awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "PartyPortal: a guest is connected")
        }
        addLog("info", "\(v.name) joined through the portal (\(viewers.count) watching)")
        // No direct connection to offer: the picture comes from the portal's SFU once the portal is told to give it.
        ws.send(json: ["type": "hello", "rtc": NSNull(), "sfu": true])
        sendState(v)
        portal?.send(json: ["t": "pp.admit", "g": id])
        if portal?.p2p == true {
            bridgeWS?.send(json: ["s": "sfu-publish", "key": id, "ice": iceServers, "simulcast": false, "kbps": settings.video.kbps])
        }
        updateSfuSink()
        for other in viewers where other !== v { sendState(other) }
    }

    private func viewerMessage(_ v: Guest, _ m: [String: Any], _ type: String) {
        switch type {
        case "ping":
            v.ws.send(json: ["type": "pong", "n": m["n"] ?? 0])
        case "auth", "rtc-offer", "rtc-cand", "rtc-off":
            break  // a viewer's picture comes from the SFU: there is no direct connection to set up
        default:
            guestCommand(v, m, type)
        }
    }

    private func dropViewer(_ v: Guest, note: String) {
        guard let i = viewers.firstIndex(where: { $0 === v }) else { return }
        viewers.remove(at: i)
        if v.control { input?.releaseAll() }
        if let id = v.id, portal?.p2p == true {
            bridgeWS?.send(json: ["s": "sfu-stop", "key": id])
            sfuLive.remove(id)
        }
        if viewers.isEmpty, guest == nil, let awake {
            ProcessInfo.processInfo.endActivity(awake)
            self.awake = nil
        }
        addLog("info", note)
        updateSfuSink()
        for other in viewers { sendState(other) }
    }

    private func kickViewer(_ v: Guest) {
        v.ws.send(json: ["type": "bye", "final": true, "reason": "The host closed access."])
        v.ws.close(code: 4002)
        dropViewer(v, note: "\(v.name) removed by the host")
    }

    /// The host gives control to one viewer; whoever had it loses it.
    private func grantControl(_ v: Guest) -> String? {
        guard !settings.locks.viewOnly else { return "View only is on: switch it off on the Control page first" }
        guard target != nil else { return "Share a window first" }
        for other in allGuests where other !== v && other.control {
            other.control = false
            input?.releaseAll()
            sendState(other)
        }
        v.control = true
        v.asked = false
        if pauseReason == "unfocused", settings.locks.autoFocus { input?.backend.focus() }
        addLog("info", "\(v.name) has control")
        sendState(v)
        return nil
    }

    /// Nobody controls any more: the host's own key, the menu bar, or the panel.
    func revokeControl(note: String?) {
        let had = allGuests.filter { $0.control || $0.asked }
        guard !had.isEmpty else { return }
        input?.releaseAll()
        for g in had {
            g.control = false
            g.asked = false
            sendState(g)
        }
        if let note { addLog("info", note) }
    }

    /// Video goes to the bridge, and from there to the SFU, while a publication is up and someone watches.
    private func updateSfuSink() {
        guard guest == nil else { return }  // a v1 guest owns the sink
        let want = !sfuLive.isEmpty && !viewers.isEmpty && bridgeWS != nil
        lock.lock()
        let had = viewer != nil
        viewer = want ? bridgeWS : nil
        lock.unlock()
        guard want != had else { return }
        trackMode = want
        liveKbps = 0
        setLiveKbps(localKbps)
        if want { kickVideo() }
    }

    /// The portal speaks v2: publish the picture to its SFU (on a stand-in without one, per viewer instead).
    private func startSfu() {
        sfuRetry?.cancel()
        sfuRetry = nil
        guard portalV2, let bridge = bridgeWS else { return }
        if portal?.p2p == true {
            for v in viewers { if let id = v.id { bridge.send(json: ["s": "sfu-publish", "key": id, "ice": iceServers, "simulcast": false, "kbps": settings.video.kbps]) } }
            return
        }
        bridge.send(json: ["s": "sfu-publish", "key": "", "ice": iceServers, "simulcast": true, "kbps": settings.video.kbps])
    }

    private func retrySfu() {
        guard portalV2, portal?.p2p != true, sfuRetry == nil else { return }
        let wait = sfuBackoff
        sfuBackoff = min(30, sfuBackoff * 2)
        let item = DispatchWorkItem { [weak self] in
            self?.sfuRetry = nil
            self?.startSfu()
        }
        sfuRetry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    /// The portal connection that published is gone: so is the publication.
    private func stopSfu() {
        sfuRetry?.cancel()
        sfuRetry = nil
        sfuBackoff = 2
        sfuInfo = [:]
        if !sfuLive.isEmpty || bridgeWS != nil { bridgeWS?.send(json: ["s": "sfu-stop"]) }
        sfuLive = []
        updateSfuSink()
    }

    /// What the portal says about the SFU: its answer goes to the bridge, an error is logged and retried.
    private func portalSfuMessage(_ m: [String: Any]) {
        let key = (portal?.p2p == true ? m["g"] as? String : nil) ?? ""
        switch m["t"] as? String {
        case "pp.sfu.answer":
            guard let sdp = m["sdp"] as? String else { return }
            bridgeWS?.send(json: ["s": "sfu-answer", "key": key, "sdp": sdp])
        case "pp.sfu.error":
            let why = String((m["why"] as? String ?? "").prefix(120))
            if let g = m["g"] as? String, let v = viewers.first(where: { $0.id == g }) {
                addLog("warn", "The portal's SFU could not give \(v.name) the picture: \(why)")
            } else {
                addLog("warn", "The portal's SFU did not take the picture: \(why) — trying again")
                bridgeWS?.send(json: ["s": "sfu-stop", "key": key])
                sfuLive.remove(key)
                updateSfuSink()
                retrySfu()
            }
        default:
            break
        }
    }

    // MARK: Direct connection

    private func bridgeOpened(_ ws: WebSocket) {
        bridgeWS = ws
        // A reloaded bridge has lost its SFU publication: make it again.
        sfuLive = []
        updateSfuSink()
        if portalV2 { DispatchQueue.main.async { [weak self] in self?.startSfu() } }
        // A guest who connected before the bridge was ready (or while it was reloading) gets the invitation now.
        if settings.video.direct { guest?.ws.send(json: ["type": "hello", "rtc": ["iceServers": iceServers]]) }
        ws.onText = { [weak self, weak ws] text in
            guard let self, let ws, self.bridgeWS === ws else { return }
            self.bridgeMessage(text)
        }
        ws.onClose = { [weak self, weak ws] in
            guard let self, let ws, self.bridgeWS === ws else { return }
            self.bridgeWS = nil
            self.rtcDown(note: "Direct connection dropped — video goes via relay")
            self.sfuLive = []
            self.updateSfuSink()
        }
    }

    private func bridgeMessage(_ text: String) {
        guard let m = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        if let type = m["t"] as? String {  // the guest's own message, relayed from the data channel
            if rtcUp, let g = guest { guestCommand(g, m, type) }
            return
        }
        switch m["b"] as? String {
        case "sig":
            if let signal = m["m"] as? [String: Any] { guest?.ws.send(json: signal) }
        case "open":
            guard let g = guest, let bridge = bridgeWS else { return }
            rtcUp = true
            trackMode = (m["track"] as? Bool) ?? false
            liveKbps = 0
            setLiveKbps(localKbps)
            lock.lock()
            viewer = bridge
            lock.unlock()
            addLog("info", "Direct connection to the guest is up" + (trackMode ? " (video as a media track)" : " (video in a data channel)"))
            g.ws.send(json: ["type": "rtc-up"])
            kickVideo()
        case "closed":
            if let why = m["why"] as? String, !why.isEmpty { addLog("warn", "Direct connection could not be set up: \(why.prefix(200))") }
            rtcDown(note: "Direct connection dropped — video goes via relay")
        case "sfu-offer":
            // The bridge's offer for its publication: the portal makes the SFU calls and answers.
            guard portalV2, let sdp = m["sdp"] as? String, let tracks = m["tracks"] as? [[String: Any]] else { return }
            let key = m["key"] as? String ?? ""
            var publish: [String: Any] = ["t": "pp.sfu.publish", "sdp": sdp, "tracks": tracks]
            if !key.isEmpty { publish["g"] = key }
            if key.isEmpty {
                sfuInfo = ["simulcast": m["simulcast"] ?? false, "audio": m["audio"] ?? false, "why": m["why"] ?? ""]
                var notes: [String] = []
                if (m["simulcast"] as? Bool) != true { notes.append("one size only (simulcast refused: \(m["why"] as? String ?? "no reason"))") }
                if (m["audio"] as? Bool) != true { notes.append("no sound (\(m["soundWhy"] as? String ?? "no audio track"))") }
                if !notes.isEmpty { addLog("warn", "Publishing the picture with " + notes.joined(separator: " and ")) }
            }
            portal?.send(json: publish)
        case "sfu-up":
            let key = m["key"] as? String ?? ""
            sfuLive.insert(key)
            if key.isEmpty {
                sfuBackoff = 2
                addLog("info", "The picture is published to the portal's SFU" + ((sfuInfo["simulcast"] as? Bool) == true ? " in three sizes" : ""))
            }
            updateSfuSink()
        case "sfu-down":
            let key = m["key"] as? String ?? ""
            guard sfuLive.remove(key) != nil || (m["why"] as? String) != nil else { return }
            if let why = m["why"] as? String, !why.isEmpty { addLog("warn", "SFU connection: \(why.prefix(200))") }
            updateSfuSink()
            if key.isEmpty { retrySfu() }
        case "kf":
            requestKey()
        case "drop":
            squeeze()
        case "stats":
            bridgeDiag = ["inGap": m["inGap"] ?? 0, "buffered": m["buffered"] ?? 0, "canTrack": m["canTrack"] ?? false,
                          "trackWhy": m["trackWhy"] ?? "", "track": m["track"] ?? NSNull(), "sfu": m["sfu"] ?? NSNull(),
                          "sound": m["sound"] ?? NSNull(), "simulcastProbe": m["simulcastProbe"] ?? NSNull()]
            if let path = m["path"] as? [String: Any] {
                // "host" is the guest's own address: the same network, or a public (often IPv6) address anywhere.
                let names = ["host": "direct", "srflx": "direct, through NAT", "prflx": "direct, through NAT", "relay": "via TURN relay"]
                let kind = [path["local"], path["remote"]].compactMap { $0 as? String }.contains("relay") ? "relay" : (path["remote"] as? String) ?? ""
                rtcPath = "\((path["protocol"] as? String ?? "udp").uppercased()), \(names[kind] ?? kind)"
            }
        default:
            break
        }
    }

    /// Back to sending media over the guest's WebSocket.
    private func rtcDown(note: String?) {
        guard rtcUp else { return }
        rtcUp = false
        rtcPath = ""
        if trackMode {
            trackMode = false
            liveKbps = 0
            setLiveKbps(localKbps)
        }
        lock.lock()
        viewer = guest?.ws
        lock.unlock()
        if let note { addLog("warn", note) }
        guest?.ws.send(json: ["type": "rtc-down"])
        if guest != nil { kickVideo() }
    }

    /// The guest's own count of what it shows. Behind the tunnel our socket never backs up — Cloudflare buffers
    /// for us — so this is the only way to learn that frames arrive late or get thrown away over there.
    private func guestStat(_ g: Guest, fps guestFps: Int, late: Int, skipped: Int) {
        g.fps = max(-1, min(guestFps, 240))
        g.late = max(0, min(late, 60_000))
        // One late second is ordinary jitter on a mobile link; frames thrown away, or lateness that stays, is not.
        let slow = skipped > 0 || late > 300
        g.behind = slow ? g.behind + 1 : 0
        // With a media track WebRTC does the adapting; our encoder only feeds the bridge next door.
        if !trackMode, skipped > 0 || g.behind >= 2 { squeeze() }
        if g.behind >= 3, !g.warned {
            g.warned = true
            addLog("warn", "The guest sees \(g.fps) of \(fps) fps: their link or computer is not keeping up\(rtcUp ? "" : " (video goes via relay)")")
        }
        if g.behind == 0, g.fps * 10 >= fps * 8 { g.warned = false }
    }

    /// The link is not keeping up: lower the bitrate now, creep back up later.
    private func squeeze() {
        // PP_FIXED_KBPS=1 holds the bitrate still, to measure what a path carries.
        guard !trackMode, uptime - lastSqueeze > 1, ProcessInfo.processInfo.environment["PP_FIXED_KBPS"] == nil else { return }
        lastSqueeze = uptime
        setLiveKbps(max(800, liveKbps * 7 / 10))
    }

    private func setLiveKbps(_ value: Int) {
        guard value != liveKbps else { return }
        liveKbps = value
        let fps = settings.video.fps
        videoQ.async { [weak self] in self?.encoder?.update(kbps: value, fps: fps) }
    }

    // MARK: Host panel API

    private func adminAllowed(_ req: HTTPRequest) -> Bool {
        // The panel is for this Mac's own browser only: refuse other sites and DNS-rebinding tricks.
        let port = opts.adminPort
        guard ["127.0.0.1:\(port)", "localhost:\(port)"].contains(req.headers["host"] ?? "") else { return false }
        if let origin = req.headers["origin"], !["http://127.0.0.1:\(port)", "http://localhost:\(port)"].contains(origin) { return false }
        if let site = req.headers["sec-fetch-site"], !["same-origin", "none"].contains(site) { return false }
        return true
    }

    func stateJSON() -> [String: Any] {
        lock.lock()
        let size = videoSize
        lock.unlock()
        var s: [String: Any] = [
            "fake": opts.fake,
            "dryInput": opts.fake || opts.dryInput,
            "permissions": ["screen": CGPreflightScreenCaptureAccess(), "accessibility": AX.trusted],
            "settings": ["locks": jsonObject(settings.locks), "video": jsonObject(settings.video), "background": jsonObject(settings.background)],
            "background": [
                "available": BackgroundInput.available, "parked": virtualDisplay != nil, "active": backgroundActive,
                "engine": orNull(target == nil ? nil : pointerPollingEngine),
            ],
            "link": ["local": "http://127.0.0.1:\(opts.guestPort)/#t=\(token)", "public": orNull(publicLink)],
            "tunnel": ["available": Tunnel.binary != nil, "running": tunnel.running, "url": orNull(tunnel.url), "error": orNull(tunnel.error)],
            "log": Array(log.suffix(80)),
            "testwin": testwinPath != nil,
        ]
        if let t = target {
            let auto = zones().filter { !$0.why.hasPrefix("area") }.map { ["x": $0.rect.minX, "y": $0.rect.minY, "w": $0.rect.width, "h": $0.rect.height, "why": $0.why] }
            s["sharing"] = [
                "window": t.json, "fps": fps, "kbps": kbps, "width": size.0, "height": size.1, "masks": jsonObject(masks), "zones": auto,
                "paused": orNull(pauseReason),
            ]
        }
        if let g = guest { s["guest"] = ["since": g.since, "control": g.control, "addr": g.ws.remote, "direct": rtcUp, "path": rtcPath, "track": trackMode, "fps": g.fps, "late": g.late] }
        s["viewers"] = viewers.map {
            ["g": $0.id ?? "", "n": $0.n, "name": $0.name, "since": $0.since, "control": $0.control, "asked": $0.asked, "fps": $0.fps, "late": $0.late] as [String: Any]
        }
        s["sfu"] = portalV2
            ? ["up": sfuLive.contains("") || (portal?.p2p == true && !sfuLive.isEmpty), "p2p": portal?.p2p == true, "simulcast": sfuInfo["simulcast"] ?? NSNull(),
               "audio": sfuInfo["audio"] ?? NSNull(), "why": sfuInfo["why"] ?? NSNull()] as [String: Any]
            : NSNull()
        s["liveKbps"] = liveKbps
        s["turn"] = turn.configured
        s["bridge"] = bridgeWS != nil
        s["bridgeDiag"] = bridgeDiag
        s["portal"] = portal.map {
            ["page": $0.page.absoluteString, "status": $0.status.rawValue, "error": orNull($0.error), "rendezvous": portalFromRendezvous, "version": $0.version,
             "expiresAt": portalExpires ?? NSNull(), "relay": $0.iceServers?.contains { $0["credential"] != nil } == true] as [String: Any]
        } ?? NSNull()
        s["share"] = ["via": settings.publicLinkMode, "rendezvous": URL(string: opts.rendezvous)?.host ?? opts.rendezvous,
                      "busy": rendezvousBusy, "error": orNull(rendezvousError)]
        return s
    }

    /// ICE servers a connected portal handed out (`pp.ready`); they replace TurnRelay's while that connection lasts.
    private var iceOverride: [[String: Any]]? {
        if ProcessInfo.processInfo.environment["PP_ICE"] == "local" { return nil }
        return portal?.iceServers
    }

    /// What the bridge and the guest use right now, without waiting.
    private var iceServers: [[String: Any]] { iceOverride ?? turn.current }

    /// "Open public access": a portal on the rendezvous (llll.gg) or the tunnel, as the host chose.
    private func openPublicLink(_ done: @escaping (String?) -> Void) {
        if let p = portal {
            guard p.status == .stopped else { return done("The guest's link comes from the portal: leave it first") }
            leavePortal()
        }
        guard settings.publicLinkMode == "rendezvous" else {
            tunnel.start(port: opts.guestPort)
            return done(nil)
        }
        openRendezvous(done)
    }

    /// No Server of your own: ask the rendezvous for a portal (POST <origin>/api/portals, no account, no body) and
    /// join it as a `partyportal://` link would, without asking — the host started it.
    private func openRendezvous(_ done: @escaping (String?) -> Void) {
        guard !rendezvousBusy else { return done(nil) }
        guard let origin = PortalLink.addresses(page: opts.rendezvous + "/x")?.page.deletingLastPathComponent(),
              let url = URL(string: "api/portals", relativeTo: origin)?.absoluteURL else {
            return done("--rendezvous needs an https origin")
        }
        rendezvousBusy = true
        rendezvousError = nil
        tunnel.stop()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        addLog("info", "Opening a portal on \(origin.host ?? "the rendezvous")…")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                self.rendezvousBusy = false
                let result = self.joinRendezvous(origin: origin, status: status, json: json, error: error)
                if let result { self.rendezvousError = result; self.addLog("warn", "No portal: \(result)") }
                done(result)
            }
        }.resume()
    }

    private func joinRendezvous(origin: URL, status: Int, json: [String: Any]?, error: Error?) -> String? {
        if let error { return error.localizedDescription }
        guard (200..<300).contains(status), let json else {
            if status == 429 { return "\(origin.host ?? "The rendezvous") has opened enough portals for this network for now: try again later" }
            return (json?["error"] as? String).map { String($0.prefix(200)) } ?? "\(origin.host ?? "The rendezvous") answered \(status)"
        }
        guard let hostLink = json["hostLink"] as? String, let items = URLComponents(string: hostLink)?.queryItems else { return "The answer had no host link" }
        let q = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let page = q["url"] ?? (json["url"] as? String ?? "")
        // The portal must live on the rendezvous itself (or under it): an answer cannot send this Mac elsewhere.
        guard let pageHost = PortalLink.addresses(page: page)?.page.host?.lowercased(), let originHost = origin.host?.lowercased(),
              pageHost == originHost || pageHost.hasSuffix("." + originHost) else { return "The portal is not on \(origin.host ?? "the rendezvous")" }
        if let error = usePortal(page: page, key: q["key"] ?? "", token: q["t"] ?? "") { return error }
        portalFromRendezvous = true
        if let at = json["expiresAt"] as? Double { portalExpires = at > 1e11 ? at / 1000 : at }
        else if let at = json["expiresAt"] as? String {
            let iso = ISO8601DateFormatter(), precise = ISO8601DateFormatter()
            precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            portalExpires = (precise.date(from: at) ?? iso.date(from: at))?.timeIntervalSince1970
        }
        return nil
    }

    /// The link a guest outside this Mac uses: the portal's page, or the tunnel's address.
    private var publicLink: String? {
        if let portal { return portal.guestLink(token: token) }
        return tunnel.url.map { "\($0)/#t=\(token)" }
    }

    // MARK: Portal

    /// Switch to a portal on an L4 Server: the tunnel goes, this Mac dials out, and the guest's key becomes `token`
    /// (the portal checks it too). Returns what is wrong, or nil.
    @discardableResult
    func usePortal(page: String, key: String, token guestKey: String) -> String? {
        guard !guestKey.isEmpty, guestKey.count <= 512 else { return "the guest's key (--token / t) is missing" }
        // Only a key the guest page can read back from its link (#t=…).
        guard guestKey.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return "the guest's key may only hold letters, digits, - and _"
        }
        if let current = portal, current.same(page: page, key: key), guestKey == token { return nil }
        guard key.count <= 512, let link = PortalLink(page: page, key: key) else {
            return "needs an https address of the portal's page and this Mac's key"
        }
        tunnel.stop()
        portal?.stop()
        stopSfu()
        portal = link
        portalFromRendezvous = false
        portalExpires = nil
        if token != guestKey {
            token = guestKey
            linkPrinted = false
        }
        link.log = { [weak self] kind, text in self?.addLog(kind, text) }
        link.onGuest = { [weak self] ws in self?.guestOpened(ws) }
        link.onChange = { [weak self] in
            guard let self else { return }
            self.printLinkIfReady()
            if self.portal === link, link.status != .ready { self.stopSfu() }
        }
        // v2 needs a video track to publish; a bridge that cannot make one keeps to one guest (v1).
        link.wantsV2 = { [weak self] in
            guard let self else { return false }
            return (self.bridgeDiag["canTrack"] as? Bool) != false || (self.bridgeDiag["trackWhy"] as? String ?? "starting") == "starting"
        }
        link.onReady = { [weak self] in
            guard let self, self.portal === link else { return }
            self.stopSfu()
            self.startSfu()
        }
        link.onSfu = { [weak self] m in
            guard let self, self.portal === link else { return }
            self.portalSfuMessage(m)
        }
        link.start()
        addLog("info", "Portal: \(link.page.absoluteString) — connecting")
        printLinkIfReady()
        return nil
    }

    func leavePortal() {
        guard let link = portal else { return }
        link.stop()
        portal = nil
        stopSfu()
        portalFromRendezvous = false
        portalExpires = nil
        addLog("info", "Portal closed: the guest's link no longer reaches this Mac")
    }

    /// Set by the app: asks the host before a link from outside (partyportal://portal?…) switches the portal.
    var confirmPortal: ((URL, @escaping (Bool) -> Void) -> Void)?

    /// A portal handed over from a link or a second copy. `ask`: the host confirms it first.
    func requestPortal(page: String, key: String, token guestKey: String, ask: Bool, done: @escaping (String?) -> Void) {
        guard let (pageURL, _) = PortalLink.addresses(page: page), !key.isEmpty, !guestKey.isEmpty else { return done("Not a portal address with both keys") }
        guard ask else { return done(usePortal(page: page, key: key, token: guestKey)) }
        guard let confirm = confirmPortal else { return done("Nobody here to confirm the portal") }
        confirm(pageURL) { [weak self] ok in
            guard let self, ok else { return done("The host said no") }
            done(self.usePortal(page: page, key: key, token: guestKey))
        }
    }

    private var testwinPath: String? {
        let path = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("partyportal-testwin").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private func adminRequest(_ req: HTTPRequest, _ reply: @escaping (HTTPResponse) -> Void) {
        guard adminAllowed(req) else { return reply(.fail(403, "The host panel only opens from this computer")) }
        let body = req.json()
        switch (req.method, req.path) {
        case ("GET", "/"):
            reply(page("host.html"))

        case ("GET", "/bridge.html"):
            reply(page("bridge.html"))

        case ("GET", "/api/state"):
            reply(.json(stateJSON()))

        case ("GET", "/api/windows"):
            if opts.fake { return reply(.json(["windows": [FakeSource.windowInfo.json]])) }
            guard CGPreflightScreenCaptureAccess() else { return reply(.fail(403, "Grant PartyPortal the Screen Recording permission first")) }
            Task { @MainActor in
                do { reply(.json(["windows": try await WindowCapture.list().map { $0.json }])) } catch {
                    reply(.fail(500, "No screen recording access: \(error.localizedDescription)"))
                }
            }

        case ("GET", "/api/thumb"):
            guard let id = UInt32(req.query["id"] ?? ""), CGPreflightScreenCaptureAccess() else { return reply(.fail(400, "id")) }
            if let (at, data) = thumbs[id], uptime - at < 5 { return reply(.data(data, type: "image/jpeg")) }
            Task { @MainActor in
                guard let data = await WindowCapture.thumbnail(windowID: id) else { return reply(.fail(404, "no picture")) }
                self.thumbs[id] = (self.uptime, data)
                reply(.data(data, type: "image/jpeg"))
            }

        case ("GET", "/api/preview.jpg"):
            videoQ.async { [weak self] in
                guard let raw = self?.lastRaw else { return reply(.fail(404, "no frame yet")) }
                Preview.jpeg(raw) { data in
                    reply(data.map { .data($0, type: "image/jpeg") } ?? .fail(503, "preview is busy"))
                }
            }

        case ("POST", "/api/share"):
            if opts.fake {
                startFake()
                return reply(.ok)
            }
            guard let id = (body["id"] as? NSNumber)?.uint32Value else { return reply(.fail(400, "No window selected")) }
            guard CGPreflightScreenCaptureAccess() else { return reply(.fail(403, "Grant PartyPortal the Screen Recording permission first")) }
            share(windowID: id) { error in reply(error.map { .fail(500, $0) } ?? .ok) }

        case ("POST", "/api/stop"):
            stopShare(note: nil)
            reply(.ok)

        case ("POST", "/api/settings"):
            applySettings(body)
            reply(.json(stateJSON()))

        // Give control to one viewer ({g, on: true}), or take it back from everyone ({on: false}).
        case ("POST", "/api/control"):
            if (body["on"] as? Bool) == true {
                guard let v = viewers.first(where: { $0.id == (body["g"] as? String) }) else { return reply(.fail(404, "That viewer has left")) }
                if let error = grantControl(v) { return reply(.fail(409, error)) }
            } else {
                revokeControl(note: "You took control back")
            }
            reply(.json(stateJSON()))

        case ("POST", "/api/kick"):
            // One viewer of a v2 portal ({g}); without it, everyone.
            if let id = body["g"] as? String {
                if let v = viewers.first(where: { $0.id == id }) { kickViewer(v) }
                return reply(.json(stateJSON()))
            }
            for v in viewers { kickViewer(v) }
            if let g = guest {
                g.ws.send(json: ["type": "bye", "final": true, "reason": "The host closed access."])
                g.ws.close(code: 4002)
                dropGuest(note: "Guest removed by the host, link replaced")
            }
            // A portal's guest key is set by the portal: the link stays, only this guest goes.
            if portal == nil { token = Core.newToken() }
            reply(.json(stateJSON()))

        case ("POST", "/api/token"):
            if portal != nil { return reply(.fail(409, "The portal sets the link: make a new portal to replace it")) }
            token = Core.newToken()
            addLog("info", "Link replaced: the old one no longer works")
            reply(.json(stateJSON()))

        case ("POST", "/api/tunnel"):
            // "Open public access" (on) and "Close public access" (off), whichever way the link is made.
            if (body["on"] as? Bool) ?? false {
                openPublicLink { [weak self] error in
                    guard let self else { return }
                    reply(error.map { .fail(409, $0) } ?? .json(self.stateJSON()))
                }
            } else {
                tunnel.stop()
                if portalFromRendezvous { leavePortal() }
                reply(.json(stateJSON()))
            }

        // A portal on an L4 Server: {url, key, t} switches to it (from a second copy or a link), {off: true} leaves it.
        case ("POST", "/api/portal"):
            if (body["off"] as? Bool) == true {
                leavePortal()
                return reply(.json(stateJSON()))
            }
            // From a link (`ask`, the default) the host confirms first: answer now, switch when they say yes.
            let ask = (body["ask"] as? Bool) ?? true
            var answered = false
            requestPortal(page: body["url"] as? String ?? "", key: body["key"] as? String ?? "", token: body["t"] as? String ?? "", ask: ask) { [weak self] error in
                guard let self else { return }
                if let error { self.addLog("warn", "Portal not opened: \(error)") }
                guard !answered else { return }
                answered = true
                if let error { return reply(.fail(400, error)) }
                self.openPanel()
                reply(.json(self.stateJSON()))
            }
            if ask, !answered {
                answered = true
                reply(.json(["asked": true]))
            }

        case ("POST", "/api/permission"):
            let kind = body["kind"] as? String
            if kind == "screen" {
                if !CGRequestScreenCaptureAccess(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            } else if kind == "accessibility" {
                let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                if !AXIsProcessTrustedWithOptions(prompt), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            reply(.ok)

        case ("POST", "/api/show"):
            openPanel()
            reply(.ok)

        case ("POST", "/api/focus"):
            input?.backend.focus()
            reply(.ok)

        case ("POST", "/api/testwin"):
            guard let path = testwinPath else { return reply(.fail(404, "The test window is not built")) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            do {
                try p.run()
                reply(.ok)
            } catch { reply(.fail(500, error.localizedDescription)) }

        case ("POST", "/api/quit"):
            reply(.ok)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.shutdown()
                exit(0)
            }

        default:
            reply(.fail(404, "not found"))
        }
    }

    private func applySettings(_ body: [String: Any]) {
        if let l = decode(Locks.self, from: body["locks"]) {
            var locks = l
            if !["list", "all", "none"].contains(locks.cmdMode) { locks.cmdMode = "list" }
            locks.blockedShortcuts = Array(locks.blockedShortcuts.prefix(100))
            settings.locks = locks
            if locks.viewOnly {
                for g in allGuests {
                    g.control = false
                    g.asked = false
                }
                input?.releaseAll()
            }
        }
        if let b = decode(BackgroundSettings.self, from: body["background"]), b != settings.background {
            settings.background = b
            switchBackground()
        }
        if let v = decode(VideoSettings.self, from: body["video"]) {
            var video = v
            video.maxDim = min(max(video.maxDim, 640), 3840)
            video.fps = min(max(video.fps, 10), 120)
            video.kbps = min(max(video.kbps, 500), 50000)
            let wasDirect = settings.video.direct
            settings.video = video
            lock.lock()
            audioOn = video.audio
            lock.unlock()
            source?.apply(video: video)
            liveKbps = 0
            setLiveKbps(localKbps)
            if wasDirect, !video.direct {
                rtcDown(note: "Direct connection turned off by the host")
                bridgeWS?.send(json: ["s": "reset"])
            } else if !wasDirect, video.direct, bridgeWS != nil {
                guest?.ws.send(json: ["type": "hello", "rtc": ["iceServers": iceServers]])  // invite the guest to try again
            }
        }
        if let via = (body["share"] as? [String: Any])?["via"] as? String, Settings.publicLinkModes.contains(via) {
            settings.publicLink = via
            rendezvousError = nil
        }
        if let list = decode([MaskRect].self, from: body["masks"]), let t = target {
            settings.masksByApp[t.appKey] = list.prefix(50).map { m in
                var m = m
                m.x = min(max(m.x, 0), 1)
                m.y = min(max(m.y, 0), 1)
                m.w = min(max(m.w, 0), 1 - m.x)
                m.h = min(max(m.h, 0), 1 - m.y)
                m.name = String(m.name.prefix(40))
                return m
            }
            publishMasks()
        }
        store.save(settings)
        sendState()
    }
}
