// A portal on an L4 Server: the guest's page and WebSocket live there, and this Mac dials out to it.
//
// Relay protocol v1, the host's side (wss://<origin>/portal/<id>/host):
//   → {"t":"host","key":<hostKey>,"v":1}            once, when the socket opens
//   ← {"t":"pp.ready"}                              the portal accepted us
//   ← {"t":"pp.guest","open":true|false}            a guest authenticated / that guest left
//   ↔ anything else, text or binary                 the guest's own frames, verbatim, both ways
//   → "ping" every 20 s, ← "pong"                   keepalive, answered by the Server itself
// Close 4401 (bad key), 4404 (portal ended) and 4409 (another host took over) are final; anything else is
// retried with backoff (1 s, doubling, at most 30 s) and counts as the guest leaving.
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
    ]

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
        let hello: [String: Any] = ["t": "host", "key": key, "v": 1]
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
            set(.ready, nil)
            log("info", "Connected to the portal: \(page.absoluteString)")
        case "pp.guest":
            // One guest at a time: whatever was there before is gone either way.
            guestLeft()
            if (m["open"] as? Bool) == true {
                let g = RelayedGuest(task: t)
                guest = g
                onGuest?(g)
            }
        default:
            break
        }
    }

    private func guestLeft() {
        let g = guest
        guest = nil
        g?.left()
    }

    /// The host socket is gone. Final codes stop for good; anything else reconnects with backoff.
    private func ended(_ t: URLSessionWebSocketTask, code: Int, why: String? = nil) {
        guard t === task, !stopped else { return }
        task = nil
        t.cancel()
        guestLeft()
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
final class RelayedGuest: GuestSocket {
    let remote = "through the portal"
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var bytes = 0
    private var binaryInFlight = 0
    private var closed = false

    /// More binary messages than this waiting for the relay counts as a full queue.
    private static let maxBinaryInFlight = 8

    init(task: URLSessionWebSocketTask) { self.task = task }

    var pendingBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        // Above the video sink's 1.5 MB threshold: stop and wait for a keyframe once the queue drains.
        return binaryInFlight >= Self.maxBinaryInFlight ? max(bytes, 2_000_000) : bytes
    }

    func send(text: String) { enqueue(.string(text), size: text.utf8.count, binary: false) }
    func send(binary: Data) { enqueue(.data(binary), size: binary.count, binary: true) }

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
        task.send(.string(#"{"t":"pp.close"}"#)) { _ in }
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
