// Portal mode's pure parts: where the host socket is, what a portal may hand out as ICE servers, the link setting.

import XCTest

@testable import partyportal

final class PortalTests: XCTestCase {
    func testAddresses() {
        let a = PortalLink.addresses(page: "https://acme.llll.gg/portal/abc123/?x=1#t=secret")
        XCTAssertEqual(a?.page.absoluteString, "https://acme.llll.gg/portal/abc123")
        XCTAssertEqual(a?.host.absoluteString, "wss://acme.llll.gg/portal/abc123/host")
        XCTAssertEqual(PortalLink.addresses(page: "https://llll.gg/p/Zz_9")?.host.absoluteString, "wss://llll.gg/p/Zz_9/host")
        XCTAssertEqual(PortalLink.addresses(page: "http://127.0.0.1:8787/portal/test")?.host.absoluteString, "ws://127.0.0.1:8787/portal/test/host")
        XCTAssertNil(PortalLink.addresses(page: "http://llll.gg/p/abc"), "plain http only for this Mac")
        XCTAssertNil(PortalLink.addresses(page: "https://llll.gg"), "a portal is a page, not an origin")
        XCTAssertNil(PortalLink.addresses(page: "ftp://llll.gg/p/abc"))
    }

    func testIceServersFromAPortal() {
        let raw: [[String: Any]] = [
            ["urls": ["stun:stun.cloudflare.com:3478", "turn:turn.cloudflare.com:53?transport=udp", "turn:turn.cloudflare.com:3478?transport=udp"],
             "username": "u", "credential": "c"],
            ["urls": "turns:turn.cloudflare.com:443?transport=tcp", "username": "u", "credential": "c"],
            ["urls": ["https://evil.example/"]],
            ["urls": ["turn:x:3478"], "credential": 42],
        ]
        let clean = PortalLink.cleanIceServers(raw)
        XCTAssertEqual(clean?.count, 2)
        XCTAssertEqual(clean?[0]["urls"] as? [String], ["stun:stun.cloudflare.com:3478", "turn:turn.cloudflare.com:3478?transport=udp"])
        XCTAssertEqual(clean?[1]["urls"] as? [String], ["turns:turn.cloudflare.com:443?transport=tcp"])
        XCTAssertEqual(clean?[1]["credential"] as? String, "c")
        XCTAssertNil(PortalLink.cleanIceServers(nil))
        XCTAssertNil(PortalLink.cleanIceServers([["urls": ["http://x"]]]))
    }

    func testPublicLinkSetting() throws {
        let unset = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertNil(unset.publicLink)
        XCTAssertEqual(unset.publicLinkMode, Settings.defaultPublicLink)
        let chosen = try JSONDecoder().decode(Settings.self, from: Data(#"{"publicLink":"rendezvous"}"#.utf8))
        XCTAssertEqual(chosen.publicLinkMode, "rendezvous")
        let odd = try JSONDecoder().decode(Settings.self, from: Data(#"{"publicLink":"carrier pigeon"}"#.utf8))
        XCTAssertNil(odd.publicLink)
    }
}
