// The rules that decide what a guest may do are pure functions, so they are tested without any window or permission.

import XCTest

@testable import partyportal

final class InputPolicyTests: XCTestCase {
    private func verdict(_ code: String, _ mods: Set<String>, _ locks: Locks = Locks()) -> String? {
        InputPolicy.keyVerdict(code: code, mods: mods, locks: locks)
    }

    func testPlainKeysPass() {
        XCTAssertNil(verdict("KeyA", []))
        XCTAssertNil(verdict("Enter", []))
        XCTAssertNil(verdict("ArrowUp", []))
        XCTAssertNil(verdict("KeyC", ["Meta"]), "copy is allowed by default")
    }

    func testModifierKeysThemselvesPass() {
        for code in ["MetaLeft", "ShiftRight", "ControlLeft", "AltRight"] { XCTAssertNil(verdict(code, [])) }
    }

    func testWindowShortcutsAreBlockedByDefault() {
        for code in ["KeyQ", "KeyW", "KeyH", "KeyM"] { XCTAssertNotNil(verdict(code, ["Meta"]), "⌘\(code) must be blocked") }
        XCTAssertNotNil(verdict("KeyF", ["Control", "Meta"]), "full screen toggle")
        XCTAssertNotNil(verdict("KeyV", ["Meta"]), "pasting the host's clipboard")
    }

    func testExtraModifiersDoNotHelpTheGuest() {
        XCTAssertNotNil(verdict("KeyQ", ["Meta", "Shift"]))
        XCTAssertNotNil(verdict("KeyW", ["Meta", "Alt"]))
        XCTAssertNotNil(verdict("KeyQ", ["Meta", "Control", "Alt", "Shift"]))
    }

    func testSystemShortcutsAreBlockedInEveryMode() {
        for mode in ["list", "all", "none"] {
            var locks = Locks()
            locks.cmdMode = mode
            locks.blockedShortcuts = []
            XCTAssertNotNil(verdict("Tab", ["Meta"], locks), "⌘Tab in mode \(mode)")
            XCTAssertNotNil(verdict("Space", ["Meta"], locks), "Spotlight in mode \(mode)")
            XCTAssertNotNil(verdict("ArrowUp", ["Control"], locks), "Mission Control in mode \(mode)")
            XCTAssertNotNil(verdict("Digit4", ["Meta", "Shift"], locks), "screenshot in mode \(mode)")
        }
    }

    func testModes() {
        var locks = Locks()
        locks.cmdMode = "all"
        XCTAssertNotNil(verdict("KeyC", ["Meta"], locks))
        XCTAssertNil(verdict("KeyC", ["Control"], locks))

        locks.cmdMode = "none"
        XCTAssertNil(verdict("KeyQ", ["Meta"], locks), "only the system list applies")

        locks.cmdMode = "list"
        locks.blockedShortcuts = ["Meta+KeyK"]
        XCTAssertNotNil(verdict("KeyK", ["Meta"], locks))
        XCTAssertNil(verdict("KeyQ", ["Meta"], locks))
    }

    func testKeyboardOff() {
        var locks = Locks()
        locks.keyboard = false
        XCTAssertNotNil(verdict("KeyA", [], locks))
        XCTAssertNotNil(verdict("ShiftLeft", [], locks))
    }

    func testShortcutMatching() {
        XCTAssertTrue(InputPolicy.matches("Meta+KeyQ", code: "KeyQ", mods: ["Meta"]))
        XCTAssertTrue(InputPolicy.matches("Meta+KeyQ", code: "KeyQ", mods: ["Meta", "Shift"]))
        XCTAssertFalse(InputPolicy.matches("Meta+Shift+KeyQ", code: "KeyQ", mods: ["Meta"]))
        XCTAssertFalse(InputPolicy.matches("Meta+KeyQ", code: "KeyW", mods: ["Meta"]))
        XCTAssertTrue(InputPolicy.matches("F11", code: "F11", mods: []))
    }

    func testZones() {
        let zones = [Zone(rect: CGRect(x: 0.5, y: 0.1, width: 0.3, height: 0.2), why: "secret")]
        XCTAssertEqual(InputPolicy.zoneVerdict(point: CGPoint(x: 0.6, y: 0.2), zones: zones), "secret")
        XCTAssertNil(InputPolicy.zoneVerdict(point: CGPoint(x: 0.4, y: 0.2), zones: zones))
        XCTAssertNil(InputPolicy.zoneVerdict(point: CGPoint(x: 0.6, y: 0.31), zones: zones))
    }

    func testLabels() {
        XCTAssertEqual(InputPolicy.label(code: "KeyQ", mods: ["Meta"]), "⌘Q")
        XCTAssertEqual(InputPolicy.label(code: "Digit3", mods: ["Meta", "Shift"]), "⇧⌘3")
        XCTAssertEqual(InputPolicy.label(code: "ArrowUp", mods: ["Control"]), "⌃Up")
    }

    func testEveryMappedKeyHasAUniqueCode() {
        XCTAssertEqual(Set(keyMap.values).count, keyMap.count, "two browser keys map to the same macOS key code")
    }
}

final class SettingsTests: XCTestCase {
    func testOldConfigKeepsItsMasksAndGetsDefaultsForNewFields() throws {
        let old = #"{"locks":{"viewOnly":true},"video":{"kbps":4000},"masksByApp":{"com.example":[{"id":"a","name":"Secret","x":0.1,"y":0.2,"w":0.3,"h":0.4,"hide":true,"block":false}]}}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        XCTAssertTrue(s.locks.viewOnly)
        XCTAssertTrue(s.locks.titleButtons, "missing field takes its default")
        XCTAssertEqual(s.video.kbps, 4000)
        XCTAssertEqual(s.video.fps, VideoSettings().fps)
        XCTAssertTrue(s.video.direct)
        XCTAssertEqual(s.masksByApp["com.example"]?.first?.name, "Secret")
    }

    func testBackgroundIsTheDefaultAndOldOrOddValuesFallBackToIt() throws {
        XCTAssertEqual(Settings().background.mode, "background")
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"background":{"enabled":false,"park":false}}"#.utf8))
        XCTAssertEqual(old.background.mode, "background", "the old on/off flag is ignored")
        XCTAssertFalse(old.background.park)
        let odd = try JSONDecoder().decode(Settings.self, from: Data(#"{"background":{"mode":"sideways"}}"#.utf8))
        XCTAssertEqual(odd.background.mode, "background")
        let takeover = try JSONDecoder().decode(Settings.self, from: Data(#"{"background":{"mode":"takeover"}}"#.utf8))
        XCTAssertEqual(takeover.background.mode, "takeover")
    }

    func testEmptyObjectIsAllDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(s.locks, Locks())
        XCTAssertEqual(s.video, VideoSettings())
    }
}
