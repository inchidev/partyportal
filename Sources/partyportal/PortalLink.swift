// A portal on an L4 Server: the guest's page and WebSocket live there, and this Mac dials out to it.
//
// Relay protocol v1, the host's side (wss://<origin>/portal/<id>/host):
//   → {"t":"host","key":<hostKey>,"v":1}            once, when the socket opens
//   ← {"t":"pp.ready"[,"iceServers":[…]]}           the portal accepted us; it may hand out ICE servers (its TURN)
//   ← {"t":"pp.guest","open":true|false}            a guest authenticated / that guest left
//   ↔ anything else, text or binary                 the guest's own frames, verbatim, both ways
//   → "ping" every 20 s, ← "pong"                   keepalive, answered by the Server itself
// Close 4401 (bad key), 4404 (portal ended), 4409 (another host took over), 4426 (protocol version) and 4429
// (llll.gg: the portal's relay limit) are final; anything else is
// retried with backoff (1 s, doubling, at most 30 s) and counts as the guest leaving.
//
// Relay protocol v2 (several viewers through the Server's Realtime SFU). The Mac offers it with "v":2; a Server
// that has an SFU answers {"t":"pp.ready","v":2,"sfu":true,…}, any other answers as v1 — and an older one closes
// with 4426, after which this link says v1 from then on. In v2:
//   ← {"t":"pp.guest","open":…,"g":<id>}           guests have names; frames are wrapped:
//   ← {"t":"pp.from","g":<id>,"f":{…}}             a guest's frame
//   → {"t":"pp.to","g":<id>,"f":{…}}               a frame for one guest ({"t":"pp.all","f":{…}} for all)
//   → {"t":"pp.close","g":<id>}                    close that guest (after its bye)
//   → {"t":"pp.admit","g":<id>}                    Core checked that guest's key: give it the picture
//   → {"t":"pp.sfu.publish","sdp":…,"tracks":[…]}  the bridge's offer for the picture (and sound), once
//   ← {"t":"pp.sfu.answer","sdp":…}                the SFU's answer; {"t":"pp.sfu.error","why":…[,"g":…]} if not
// No binary frame goes through a v2 portal: the picture travels only through the SFU.
// tools/portal-relay.mjs --v2 fakes the SFU with "p2p":true in pp.ready: the bridge then publishes once per guest
// ("g" in pp.sfu.publish and pp.sfu.answer) and the stand-in passes offer and answer between bridge and guest.
//
// Core sees a relayed guest exactly like a local one (`GuestSocket`): it checks the token in the first frame,
// sends hello, state and media, and closes it. A close from Core cannot reach the guest's own socket (v1 has no
// message for that); it only stops this Mac from talking to that guest until the Server reports a new one.

import Foundation

final class PortalLink: NSObject, URLSessionWebSocketDelegate {
    enum Status: String { case connecting, ready, stopped }

    /// The portal's page, without key or fragment: https://<origin>/portal/<id>
    let page: URL
    /// Where the host connects: wss://<origin>/portal/<id>/host
    let hostURL: URL
    private let key: String

    /// A guest authenticated at the portal (main queue). Its first frame is the guest's own auth message.
    var onGuest: ((GuestSocket) -> Void)?
    /// Status or error changed (main queue).
    var onChange: (() -> Void)?
    var log: (String, String) -> Void = { _, _ in }

    // Main queue
    private(set) var status = Status.connecting
    private(set) var error: String?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var guest: RelayedGuest?
    private var backoff = 1.0
    private var retry: DispatchWorkItem?
    private var pinger: Timer?
    private var lastHeard = 0.0
    private var stopped = false

    private static let pingEvery = 20.0
    private static let finalCodes: [Int: String] = [
        4401: "The portal refused this Mac's key",
        4404: "The portal has ended",
        4409: "Another PartyPortal connected to this portal",
        4426: "Update PartyPortal or this Server: they do not speak the same protocol",
        4429: "This portal reached its relay limit",
    ]

    /// ICE servers the portal handed out in `pp.ready` (usually with its TURN relay), for as long as this host
    /// connection lasts. nil: the portal gave none, and Core uses its own (TurnRelay).
    private(set) var iceServers: [[String: Any]]?

    /// The relay protocol of this connection, from `pp.ready`: 2 means several viewers through the portal's SFU.
    private(set) var version = 1
    /// v2 on a stand-in without an SFU (tools/portal-relay.mjs --v2): publish once per guest, peer to peer.
    private(set) var p2p = false
    /// Asked before each connection: offer v2? (Core says no when its bridge cannot make a video track.)
    var wantsV2: () -> Bool = { true }
    /// This portal closed a v2 hello with 4426: it speaks v1 only, so say v1 from now on.
    private var v1Only = false
    private var offeredV2 = false
    /// The version the next hello says; read on URLSession's queue.
    private let helloLock = NSLock()
    private var helloVersion = 1
    /// `pp.ready` arrived (main queue): Core sets up the picture for v2 then.
    var onReady: (() -> Void)?
    /// The portal's SFU messages (`pp.sfu.answer`, `pp.sfu.error`), main queue.
    var onSfu: (([String: Any]) -> Void)?
    /// v2: the guests the portal has introduced, by name.
    private var viewers: [String: RelayedGuest] = [:]

    /// Only what a browser's RTCPeerConnection takes, and nothing a Server should not send: stun/turn/turns URLs,
    /// string credentials, a handful of entries. Port 53 is dropped as TurnRelay does (browsers block it).
    static func cleanIceServers(_ raw: Any?) -> [[String: Any]]? {
        guard let list = raw as? [[String: Any]] else { return nil }
        let cleaned: [[String: Any]] = list.prefix(8).compactMap { server in
            let urls = (server["urls"] as? [String] ?? (server["urls"] as? String).map { [$0] } ?? []).filter { url in
                let u = url.lowercased()
                return url.count < 512 && ["stun:", "turn:", "turns:"].contains { u.hasPrefix($0) } && !u.contains(":53?") && !u.hasSuffix(":53")
            }
            guard !urls.isEmpty else { return nil }
            var out: [String: Any] = ["urls": Array(urls.prefix(8))]
            for field in ["username", "credential"] {
                if let v = server[field] as? String, v.count < 1024 { out[field] = v } else if server[field] != nil { return nil }
            }
            return out
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The portal's page and the host socket next to it. `page` must be https; plain http is accepted only for
    /// this Mac (a local stand-in such as tools/portal-relay.mjs).
    static func addresses(page raw: String) -> (page: URL, host: URL)? {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        let local = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return nil }
        parts.percentEncodedPath = path
        guard let pageURL = parts.url else { return nil }
        parts.scheme = scheme == "https" ? "wss" : "ws"
        parts.percentEncodedPath = path + "/host"
        guard let hostURL = parts.url else { return nil }
        return (pageURL, hostURL)
    }

    init?(page raw: String, key: String) {
        guard !key.isEmpty, let (pageURL, hostURL) = Self.addresses(page: raw) else { return nil }
        self.page = pageURL
        self.hostURL = hostURL
        self.key = key
        super.init()
        // Our own serial queue for URLSession's callbacks: send completions must not wait behind the main queue,
        // or a busy main thread would look like a slow relay.
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "partyportal.portal"
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config, delegate: self, delegateQueue: q)
    }

    /// The same portal and key: switching to it again would only drop a working connection.
    func same(page raw: String, key other: String) -> Bool {
        Self.addresses(page: raw)?.host == hostURL && other == key && status != .stopped
    }

    /// The link the guest gets: the portal's page with the guest's key in the fragment (never sent to a server).
    func guestLink(token: String) -> String { "\(page.absoluteString)#t=\(token)" }

    /// Once per link: after `stop()` make a new one.
    func start() {
        connect()
        pinger?.invalidate()
        pinger = Timer.scheduledTimer(withTimeInterval: Self.pingEvery, repeats: true) { [weak self] _ in self?.keepAlive() }
    }

    func stop() {
        stopped = true
        retry?.cancel()
        retry = nil
        pinger?.invalidate()
        pinger = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        iceServers = nil
        guestLeft()
        set(.stopped, error)
        session.invalidateAndCancel()
    }

    private func set(_ s: Status, _ e: String?) {
        guard s != status || e != error else { return }
        status = s
        error = e
        onChange?()
    }

    private func connect() {
        guard !stopped else { return }
        retry = nil
        var req = URLRequest(url: hostURL)
        req.timeoutInterval = 15
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 4 * 1024 * 1024
        task = t
        offeredV2 = !v1Only && ProcessInfo.processInfo.environment["PP_PORTAL_V"] != "1" && wantsV2()
        helloLock.lock()
        helloVersion = offeredV2 ? 2 : 1
        helloLock.unlock()
        version = 1
        p2p = false
        lastHeard = ProcessInfo.processInfo.systemUptime
        set(.connecting, error)
        t.resume()
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                DispatchQueue.main.async { self.handle(message, from: t) }
                self.receive(t)
            case .failure:
                // The close code may arrive a moment after the failure (didCloseWith): look again shortly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.ended(t, code: t.closeCode.rawValue) }
            }
        }
    }

    // MARK: URLSessionWebSocketDelegate (delegate queue)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        helloLock.lock()
        let v = helloVersion
        helloLock.unlock()
        let hello: [String: Any] = ["t": "host", "key": key, "v": v]
        guard let d = try? JSONSerialization.data(withJSONObject: hello) else { return }
        webSocketTask.send(.string(String(decoding: d, as: UTF8.self))) { _ in }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async { self.ended(webSocketTask, code: closeCode.rawValue) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let t = task as? URLSessionWebSocketTask else { return }
        let why = error?.localizedDescription
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.ended(t, code: t.closeCode.rawValue, why: why) }
    }

    // MARK: Main queue

    private func handle(_ message: URLSessionWebSocketTask.Message, from t: URLSessionWebSocketTask) {
        guard t === task, !stopped else { return }
        lastHeard = ProcessInfo.processInfo.systemUptime
        switch message {
        case .string(let text):
            if text == "pong" { return }
            // The portal's own messages; everything else belongs to the guest.
            if text.contains("\"pp."), let m = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
               let type = m["t"] as? String, type.hasPrefix("pp.") {
                portalMessage(type, m, t)
                return
            }
            guest?.received(text)
        case .data:
            break  // the guest page sends only text; a local socket ignores binary from a guest too
        @unknown default:
            break
        }
    }

    private func portalMessage(_ type: String, _ m: [String: Any], _ t: URLSessionWebSocketTask) {
        switch type {
        case "pp.ready":
            backoff = 1
            iceServers = Self.cleanIceServers(m["iceServers"])
            version = offeredV2 && (m["v"] as? Int) == 2 && (m["sfu"] as? Bool) == true ? 2 : 1
            p2p = version == 2 && (m["p2p"] as? Bool) == true
            set(.ready, nil)
            let relay = iceServers?.contains { $0["credential"] != nil } == true
            let how = version == 2 ? (p2p ? " — several viewers, peer to peer (a stand-in without an SFU)" : " — several viewers through its SFU") : ""
            log("info", "Connected to the portal: \(page.absoluteString)\(how)" + (relay ? " (its TURN relay is offered to the guest)" : ""))
            onReady?()
        case "pp.guest" where version == 2:
            guard let g = m["g"] as? String, !g.isEmpty, g.count <= 64 else { return }
            viewers.removeValue(forKey: g)?.left()
            if (m["open"] as? Bool) == true {
                let guest = RelayedGuest(task: t, g: g)
                viewers[g] = guest
                onGuest?(guest)
            }
        case "pp.guest":
            // One guest at a time: whatever was there before is gone either way.
            guestLeft()
            if (m["open"] as? Bool) == true {
                let g = RelayedGuest(task: t)
                guest = g
                onGuest?(g)
            }
        case "pp.from" where version == 2:
            guard let g = m["g"] as? String, let f = m["f"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: f) else { return }
            viewers[g]?.received(String(decoding: data, as: UTF8.self))
        case "pp.sfu.answer", "pp.sfu.error":
            if version == 2 { onSfu?(m) }
        default:
            break
        }
    }

    private func guestLeft() {
        let g = guest
        guest = nil
        g?.left()
        let all = viewers.values
        viewers = [:]
        for v in all { v.left() }
    }

    /// A message of our own to the portal (v2: `pp.admit`, `pp.sfu.publish`). Dropped while not connected.
    func send(json: [String: Any]) {
        guard let t = task, status == .ready, let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        t.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    /// The host socket is gone. Final codes stop for good; anything else reconnects with backoff.
    private func ended(_ t: URLSessionWebSocketTask, code: Int, why: String? = nil) {
        guard t === task, !stopped else { return }
        task = nil
        iceServers = nil
        t.cancel()
        guestLeft()
        // No WebSocket at all, and the Server says the portal is not there: it ended (or never was).
        var code = code
        if code == 0, let status = (t.response as? HTTPURLResponse)?.statusCode, [404, 410].contains(status) { code = 4404 }
        // A Server from before v2 refuses the version we offered: not final, it takes v1 at once.
        if code == 4426, offeredV2, !v1Only {
            v1Only = true
            log("info", "This portal speaks relay protocol v1 only: one guest at a time")
            connect()
            return
        }
        if let final = Self.finalCodes[code] {
            log("warn", "\(final) — the portal link is off")
            stopped = true
            pinger?.invalidate()
            pinger = nil
            set(.stopped, final)
            return
        }
        let wait = backoff
        backoff = min(30, backoff * 2)
        let reason = why ?? (code > 0 ? "closed (\(code))" : "connection lost")
        if status == .ready { log("warn", "Lost the portal (\(reason)) — reconnecting") }
        set(.connecting, "\(reason); trying again in \(Int(wait)) s")
        let item = DispatchWorkItem { [weak self] in self?.connect() }
        retry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    private func keepAlive() {
        guard let t = task, !stopped else { return }
        // Pongs come every 20 s on a live socket: silence for much longer means the path is dead without a close.
        if ProcessInfo.processInfo.systemUptime - lastHeard > Self.pingEvery * 2.5 {
            ended(t, code: 0, why: "the portal stopped answering")
            return
        }
        t.send(.string("ping")) { _ in }
    }
}

/// A guest whose WebSocket ends at the portal. Sends go straight into the host socket and never block: there is
/// no buffer signal in URLSessionWebSocketTask, so we count what is in flight and report it as `pendingBytes`.
/// Core's sinks then drop video (and resume on a keyframe) and audio exactly as they do for a local socket.
/// In v2 (`g` set) every frame is wrapped for that guest and nothing binary is sent: its picture comes from the SFU.
final class RelayedGuest: GuestSocket {
    let remote = "through the portal"
    /// v2: the portal's name for this guest.
    let g: String?
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var bytes = 0
    private var binaryInFlight = 0
    private var closed = false

    /// More binary messages than this waiting for the relay counts as a full queue.
    private static let maxBinaryInFlight = 8

    init(task: URLSessionWebSocketTask, g: String? = nil) {
        self.task = task
        self.g = g
    }

    var pendingBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        // Above the video sink's 1.5 MB threshold: stop and wait for a keyframe once the queue drains.
        return binaryInFlight >= Self.maxBinaryInFlight ? max(bytes, 2_000_000) : bytes
    }

    func send(text: String) {
        // Core's frames are JSON objects already: wrapping is a matter of text, not of parsing them again.
        guard let g else { return enqueue(.string(text), size: text.utf8.count, binary: false) }
        let wrapped = Self.wrap(text, for: g)
        enqueue(.string(wrapped), size: wrapped.utf8.count, binary: false)
    }

    func send(binary: Data) {
        guard g == nil else { return }
        // A Worker's WebSocket takes messages up to 1 MiB, and llll.gg ends the portal for a bigger one (4429).
        // A frame that large is dropped here; the guest's decoder then asks for a keyframe.
        guard binary.count <= Self.maxMessage else { return }
        enqueue(.data(binary), size: binary.count, binary: true)
    }

    static let maxMessage = 1024 * 1024 - 64

    /// v2: one of Core's JSON frames, for one guest.
    static func wrap(_ text: String, for g: String) -> String { "{\"t\":\"pp.to\",\"g\":" + quoted(g) + ",\"f\":" + text + "}" }

    /// What asks the portal to close a guest: v1's one guest, or v2's guest `g`.
    static func closeFrame(g: String?) -> String { g.map { "{\"t\":\"pp.close\",\"g\":" + quoted($0) + "}" } ?? #"{"t":"pp.close"}"# }

    /// `s` as a JSON string, quotes included.
    private static func quoted(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private func enqueue(_ message: URLSessionWebSocketTask.Message, size: Int, binary: Bool) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        bytes += size
        if binary { binaryInFlight += 1 }
        lock.unlock()
        task.send(message) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.bytes -= size
            if binary { self.binaryInFlight -= 1 }
            self.lock.unlock()
        }
    }

    /// Core is done with this guest (bad token, kicked). Whatever Core sent last (its `bye`) goes first, then
    /// `pp.close` asks the portal to close the guest's socket there; L4 Servers since ADR 0014's first release do.
    /// A guest the portal already replaced has left through `left()`, not here, so `pp.close` names the current one.
    func close(code: UInt16) {
        guard markClosed() else { return }
        task.send(.string(Self.closeFrame(g: g))) { _ in }
        DispatchQueue.main.async { self.onClose?() }
    }

    /// Main queue: a frame from the guest.
    fileprivate func received(_ text: String) {
        lock.lock()
        let open = !closed
        lock.unlock()
        if open { onText?(text) }
    }

    /// Main queue: the portal says the guest left, or the host socket is gone.
    fileprivate func left() {
        if markClosed() { onClose?() }
    }

    private func markClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        closed = true
        return true
    }
}
