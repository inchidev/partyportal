// A TURN relay for guests whose network (or the host's) will not let a direct connection through:
// symmetric carrier NAT, phone hotspots, strict office firewalls. Media then goes host → relay → guest,
// still over UDP, instead of falling back to the tunnel's TCP.
//
// Bring your own key: Cloudflare Realtime TURN (dashboard → Realtime → TURN Server → Create).
// Put the two values in `turn.json` next to config.json:
//     {"keyId": "<Turn Token ID>", "apiToken": "<API Token>"}
// or in PP_TURN_KEY_ID / PP_TURN_API_TOKEN. The key never leaves this machine and is never shown in the
// panel; what the guest receives is a short-lived credential minted from it for the session.

import Foundation

final class TurnRelay {
    private struct Key: Decodable {
        let keyId: String
        let apiToken: String
    }

    static let stunOnly: [[String: Any]] = [["urls": ["stun:stun.l.google.com:19302", "stun:stun.cloudflare.com:3478"]]]
    private static let ttl = 12 * 3600

    private let key: Key?
    private var cached: [[String: Any]]?
    private var cachedAt = Date.distantPast
    private var waiting: [([[String: Any]]) -> Void] = []

    var configured: Bool { key != nil && ProcessInfo.processInfo.environment["PP_ICE"] != "local" }

    init(configDir: URL) {
        let env = ProcessInfo.processInfo.environment
        if let id = env["PP_TURN_KEY_ID"], let token = env["PP_TURN_API_TOKEN"], !id.isEmpty, !token.isEmpty {
            key = Key(keyId: id, apiToken: token)
        } else if let data = try? Data(contentsOf: configDir.appendingPathComponent("turn.json")),
                  let k = try? JSONDecoder().decode(Key.self, from: data), Self.plausible(k.keyId), Self.plausible(k.apiToken) {
            key = k
        } else {
            key = nil
        }
    }

    private static func plausible(_ s: String) -> Bool {
        !s.isEmpty && s.count < 200 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// What is known right now, without waiting: the last minted set while it is fresh, STUN alone otherwise.
    var current: [[String: Any]] {
        if ProcessInfo.processInfo.environment["PP_ICE"] == "local" { return [] }
        if let cached, Date().timeIntervalSince(cachedAt) < Double(Self.ttl) / 2 { return cached }
        return Self.stunOnly
    }

    /// ICE servers for a new guest. Calls back on the main queue, within a few seconds at worst;
    /// without a key, or when Cloudflare does not answer, that is STUN alone and `relay` is false.
    func servers(_ done: @escaping (_ servers: [[String: Any]], _ relay: Bool) -> Void) {
        // PP_ICE=local: no STUN, no relay — only addresses on this network. For testing the pipeline itself.
        if ProcessInfo.processInfo.environment["PP_ICE"] == "local" { return done([], false) }
        guard let key else { return done(Self.stunOnly, false) }
        // A credential lives 12 hours; a guest arriving within the first hour of it can share it.
        if let cached, Date().timeIntervalSince(cachedAt) < 3600 { return done(cached, true) }
        waiting.append { servers in done(servers, servers.count > 1 || servers.contains { $0["credential"] != nil }) }
        guard waiting.count == 1 else { return }

        var req = URLRequest(url: URL(string: "https://rtc.live.cloudflare.com/v1/turn/keys/\(key.keyId)/credentials/generate-ice-servers")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 4
        req.setValue("Bearer \(key.apiToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["ttl": Self.ttl])
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            var minted: [[String: Any]]?
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["iceServers"] as? [[String: Any]] {
                // Port 53 is blocked by browsers and only costs a timeout.
                let cleaned: [[String: Any]] = list.compactMap { server in
                    var s = server
                    let urls = (s["urls"] as? [String] ?? (s["urls"] as? String).map { [$0] } ?? []).filter { !$0.contains(":53") }
                    guard !urls.isEmpty else { return nil }
                    s["urls"] = urls
                    return s
                }
                if cleaned.contains(where: { $0["credential"] != nil }) {
                    minted = [["urls": ["stun:stun.l.google.com:19302"]]] + cleaned
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let minted { self.cached = minted; self.cachedAt = Date() }
                let result = minted ?? Self.stunOnly
                let callbacks = self.waiting
                self.waiting = []
                callbacks.forEach { $0(result) }
            }
        }.resume()
    }
}
