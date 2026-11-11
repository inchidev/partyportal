// Minimal HTTP/1.1 + WebSocket server on Network.framework. No dependencies.
// One request per connection (Connection: close); a request may upgrade to a WebSocket.

import CryptoKit
import Foundation
import Network

struct HTTPRequest {
    var method = "GET"
    var path = "/"
    var query: [String: String] = [:]
    var headers: [String: String] = [:]  // lowercased names
    var body = Data()

    func json() -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
    }
}

struct HTTPResponse {
    var status = 200
    var contentType = "application/json; charset=utf-8"
    var body = Data()

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }

    static func fail(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    static func data(_ d: Data, type: String) -> HTTPResponse {
        HTTPResponse(contentType: type, body: d)
    }

    static let ok = json(["ok": true])
}

final class WebSocket {
    fileprivate let conn: NWConnection
    private let lock = NSLock()
    private var pending = 0
    private var closed = false

    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var remote = ""

    fileprivate init(conn: NWConnection) { self.conn = conn }

    /// Bytes handed to the socket but not yet written: the backpressure signal.
    var pendingBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    func send(text: String) { sendFrame(opcode: 0x1, payload: Data(text.utf8)) }
    func send(binary: Data) { sendFrame(opcode: 0x2, payload: binary) }

    func send(json: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: json) else { return }
        sendFrame(opcode: 0x1, payload: d)
    }

    func close(code: UInt16 = 1000) {
        sendFrame(opcode: 0x8, payload: Data([UInt8(code >> 8), UInt8(code & 0xff)]))
        lock.lock()
        closed = true
        lock.unlock()
        let c = conn
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { c.cancel() }
    }

    fileprivate func markClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    fileprivate func sendFrame(opcode: UInt8, payload: Data) {
        var frame = Data(capacity: payload.count + 10)
        frame.append(0x80 | opcode)
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(n >> 8))
            frame.append(UInt8(n & 0xff))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() { frame.append(UInt8((UInt64(n) >> (UInt64(i) * 8)) & 0xff)) }
        }
        frame.append(payload)
        let total = frame.count
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        pending += total
        lock.unlock()
        conn.send(content: frame, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.pending -= total
            self.lock.unlock()
        })
    }
}

final class HTTPServer {
    /// Plain request: call `reply` exactly once (may be async).
    var onRequest: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void = { _, reply in reply(.fail(404, "not found")) }
    /// Upgrade request: return nil to refuse, or a closure that receives the open socket.
    var onWebSocket: (HTTPRequest) -> ((WebSocket) -> Void)? = { _ in nil }

    /// The port could not be opened (usually: another copy is already running).
    var onFail: (String) -> Void = { _ in }

    let port: UInt16
    private let listener: NWListener
    private var connections: [ObjectIdentifier: ClientConnection] = [:]

    init(port: UInt16, host: String = "127.0.0.1") throws {
        self.port = port
        // No Nagle: input and video frames must leave immediately, not wait for the previous ACK.
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let c = ClientConnection(conn: conn, server: self)
            self.connections[ObjectIdentifier(c)] = c
            c.start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state { self?.onFail("\(err)") }
        }
        listener.start(queue: .main)
    }

    fileprivate func remove(_ c: ClientConnection) { connections[ObjectIdentifier(c)] = nil }
}

private final class ClientConnection {
    private static let maxHead = 32 * 1024
    private static let maxBody = 2 * 1024 * 1024
    private static let maxFrame = 1024 * 1024

    let conn: NWConnection
    unowned let server: HTTPServer
    var buffer = Data()
    var ws: WebSocket?
    var fragments = Data()
    var fragmentOpcode: UInt8 = 0
    var handling = false
    var done = false

    init(conn: NWConnection, server: HTTPServer) {
        self.conn = conn
        self.server = server
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        conn.start(queue: .main)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.done else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.ws != nil { self.parseFrames() } else if !self.handling { self.parseRequest() }
            }
            if isComplete || error != nil {
                self.conn.cancel()
                self.finish()
                return
            }
            self.receive()
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        if let ws {
            ws.markClosed()
            ws.onClose?()
        }
        server.remove(self)
    }

    private func drop() {
        conn.cancel()
        finish()
    }

    // MARK: HTTP

    private func parseRequest() {
        guard let sep = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHead { drop() }
            return
        }
        guard let head = String(data: buffer[buffer.startIndex..<sep.lowerBound], encoding: .utf8) else { return drop() }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return drop() }
        var req = HTTPRequest()
        req.method = String(first[0])
        let target = String(first[1])
        let parts = target.split(separator: "?", maxSplits: 1)
        req.path = (parts.first.map(String.init) ?? "/").removingPercentEncoding ?? "/"
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let k = String(kv[0]).removingPercentEncoding ?? ""
                req.query[k] = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? "") : ""
            }
        }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            req.headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(req.headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= Self.maxBody else { return drop() }
        let bodyStart = sep.upperBound
        guard buffer.endIndex - bodyStart >= length else { return }  // wait for the rest of the body
        req.body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer = Data(buffer[(bodyStart + length)...])

        if (req.headers["upgrade"] ?? "").lowercased() == "websocket" {
            upgrade(req)
            return
        }
        handling = true
        server.onRequest(req) { [weak self] response in
            DispatchQueue.main.async { self?.respond(response) }
        }
    }

    private func respond(_ r: HTTPResponse) {
        guard !done else { return }
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 409: "Conflict", 500: "Internal Server Error"][r.status] ?? "OK"
        var head = "HTTP/1.1 \(r.status) \(reason)\r\n"
        head += "Content-Type: \(r.contentType)\r\n"
        head += "Content-Length: \(r.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(r.body)
        conn.send(content: out, completion: .contentProcessed { [weak self] _ in
            self?.conn.cancel()
        })
    }

    private func upgrade(_ req: HTTPRequest) {
        guard let key = req.headers["sec-websocket-key"], let setup = server.onWebSocket(req) else {
            handling = true
            respond(.fail(403, "forbidden"))
            return
        }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let socket = WebSocket(conn: conn)
        socket.remote = req.headers["cf-connecting-ip"] ?? req.headers["x-forwarded-for"] ?? "this computer"
        ws = socket
        setup(socket)
        if !buffer.isEmpty { parseFrames() }
    }

    // MARK: WebSocket frames

    private func parseFrames() {
        while !done, let ws {
            guard buffer.count >= 2 else { return }
            let b = [UInt8](buffer.prefix(14))
            let fin = b[0] & 0x80 != 0
            let opcode = b[0] & 0x0F
            let masked = b[1] & 0x80 != 0
            var length = Int(b[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard b.count >= 4 else { return }
                length = Int(b[2]) << 8 | Int(b[3])
                offset = 4
            } else if length == 127 {
                guard b.count >= 10 else { return }
                var n: UInt64 = 0
                for i in 2..<10 { n = n << 8 | UInt64(b[i]) }
                guard n <= UInt64(Self.maxFrame) else { return drop() }
                length = Int(n)
                offset = 10
            }
            // Browsers always mask; anything else is not a browser talking to us.
            guard masked, length <= Self.maxFrame else { return drop() }
            guard b.count >= offset + 4, buffer.count >= offset + 4 + length else { return }
            let mask = Array(b[offset..<(offset + 4)])
            offset += 4
            var payload = [UInt8](buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + length)])
            for i in 0..<payload.count { payload[i] ^= mask[i & 3] }
            buffer = Data(buffer[(buffer.startIndex + offset + length)...])

            switch opcode {
            case 0x0:
                fragments.append(contentsOf: payload)
                guard fragments.count <= Self.maxFrame else { return drop() }
                if fin {
                    if fragmentOpcode == 0x1, let s = String(data: fragments, encoding: .utf8) { ws.onText?(s) }
                    fragments = Data()
                }
            case 0x1, 0x2:
                if fin {
                    if opcode == 0x1, let s = String(bytes: payload, encoding: .utf8) { ws.onText?(s) }
                } else {
                    fragmentOpcode = opcode
                    fragments = Data(payload)
                }
            case 0x8:
                ws.sendFrame(opcode: 0x8, payload: Data(payload.prefix(2)))
                return drop()
            case 0x9:
                ws.sendFrame(opcode: 0xA, payload: Data(payload))
            default:
                break
            }
        }
    }
}
