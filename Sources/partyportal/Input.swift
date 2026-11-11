// Guest input: InputController applies the rules and keeps track of what is held down;
// a backend either posts real events (RealInput) or writes them to a log (DryInput).

import AppKit
import CoreGraphics
import Foundation

protocol InputBackend: AnyObject {
    func mouseMove(to p: CGPoint, delta: CGPoint, dragging: Int?)
    func mouseButton(_ button: Int, down: Bool, at p: CGPoint, clicks: Int)
    func scroll(dx: Int32, dy: Int32)
    func key(_ code: UInt16, down: Bool, flags: CGEventFlags)
    /// False when something else covers the window at this point.
    func canClick(at p: CGPoint) -> Bool
    func focus()
}

/// Posts events to the system. Needs the Accessibility permission.
final class RealInput: InputBackend {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let pid: pid_t
    private let windowID: CGWindowID

    init(pid: pid_t, windowID: CGWindowID) {
        self.pid = pid
        self.windowID = windowID
        source?.localEventsSuppressionInterval = 0
    }

    private func button(_ b: Int) -> CGMouseButton { b == 2 ? .right : b == 1 ? .center : .left }

    func mouseMove(to p: CGPoint, delta: CGPoint, dragging: Int?) {
        let type: CGEventType
        switch dragging {
        case nil: type = .mouseMoved
        case 0: type = .leftMouseDragged
        case 2: type = .rightMouseDragged
        default: type = .otherMouseDragged
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button(dragging ?? 0)) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        e.post(tap: .cghidEventTap)
    }

    func mouseButton(_ b: Int, down: Bool, at p: CGPoint, clicks: Int) {
        let type: CGEventType
        switch b {
        case 0: type = down ? .leftMouseDown : .leftMouseUp
        case 2: type = down ? .rightMouseDown : .rightMouseUp
        default: type = down ? .otherMouseDown : .otherMouseUp
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button(b)) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e.post(tap: .cghidEventTap)
    }

    func scroll(dx: Int32, dy: Int32) {
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    func key(_ code: UInt16, down: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    func canClick(at p: CGPoint) -> Bool {
        // The accessibility hit-test is trusted when it names a window of the shared app; otherwise fall back to window order.
        if let hit = AX.windowAt(p), hit.pid == pid, let window = hit.window { return window == windowID }
        return WindowQuery.isTopmost(windowID, pid: pid, at: p)
    }
    func focus() { AX.raise(pid: pid, id: windowID) }

    /// Why input is paused right now, or nil when it may flow.
    func pauseReason(onScreen: Bool) -> String? {
        if !AX.trusted { return "noaccess" }
        if WindowQuery.screenLocked { return "locked" }
        if !onScreen { return "hidden" }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { return "unfocused" }
        if let focused = AX.focusedWindowID(pid: pid), focused != windowID { return "unfocused" }
        return nil
    }
}

/// Writes what would have been posted, one JSON object per line. Used by `--fake` and `--dry-input`.
final class DryInput: InputBackend {
    private let handle: FileHandle?
    let path: String

    init(path: String) {
        self.path = path
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    private func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        handle?.write(data)
        handle?.write(Data("\n".utf8))
    }

    func mouseMove(to p: CGPoint, delta: CGPoint, dragging: Int?) {
        write(["e": "move", "x": Int(p.x.rounded()), "y": Int(p.y.rounded()), "drag": dragging ?? -1])
    }
    func mouseButton(_ b: Int, down: Bool, at p: CGPoint, clicks: Int) {
        write(["e": down ? "down" : "up", "b": b, "x": Int(p.x.rounded()), "y": Int(p.y.rounded()), "clicks": clicks])
    }
    func scroll(dx: Int32, dy: Int32) { write(["e": "scroll", "dx": dx, "dy": dy]) }
    func key(_ code: UInt16, down: Bool, flags: CGEventFlags) {
        write(["e": down ? "keydown" : "keyup", "vk": code, "cmd": flags.contains(.maskCommand), "shift": flags.contains(.maskShift)])
    }
    func canClick(at p: CGPoint) -> Bool { true }
    func focus() { write(["e": "focus"]) }
}

final class InputController {
    let backend: InputBackend
    var locks: () -> Locks = { Locks() }
    var zones: () -> [Zone] = { [] }
    /// Window frame in global points.
    var frame: () -> CGRect = { .zero }
    /// nil when input may flow; otherwise a reason code ("unfocused", "locked", …).
    var pauseReason: () -> String? = { nil }
    var onBlocked: (_ what: String, _ why: String) -> Void = { _, _ in }
    var onActivity: () -> Void = {}

    private var mods: Set<String> = []
    private var keysDown: [String: UInt16] = [:]
    private var buttonsDown: Set<Int> = []
    private var pos = CGPoint(x: 0.5, y: 0.5)  // window-relative
    private var lastGlobal: CGPoint?
    private var lastClick: (time: Double, at: CGPoint, button: Int, count: Int) = (0, .zero, -1, 0)

    var buttonHeld: Bool { !buttonsDown.isEmpty }

    init(backend: InputBackend) { self.backend = backend }

    private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    /// Window-relative → global, never outside the window (and off its resize edges while dragging).
    private func global(_ p: CGPoint) -> CGPoint {
        let f = frame()
        let inset: CGFloat = buttonHeld && locks().edges ? 6 : 1
        let x = min(max(f.minX + p.x * f.width, f.minX + inset), f.maxX - inset)
        let y = min(max(f.minY + p.y * f.height, f.minY + inset), f.maxY - inset)
        return CGPoint(x: x, y: y)
    }

    private func setPos(_ m: [String: Any]) {
        guard let x = num(m["x"]), let y = num(m["y"]), x.isFinite, y.isFinite else { return }
        pos = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    private func move() {
        let g = global(pos)
        let delta = lastGlobal.map { CGPoint(x: g.x - $0.x, y: g.y - $0.y) } ?? .zero
        lastGlobal = g
        backend.mouseMove(to: g, delta: delta, dragging: buttonsDown.min())
    }

    private var flags: CGEventFlags {
        var f: CGEventFlags = []
        if mods.contains("Shift") { f.insert(.maskShift) }
        if mods.contains("Control") { f.insert(.maskControl) }
        if mods.contains("Alt") { f.insert(.maskAlternate) }
        if mods.contains("Meta") { f.insert(.maskCommand) }
        return f
    }

    func handle(_ m: [String: Any]) {
        guard let type = m["t"] as? String else { return }
        if locks().viewOnly {
            if !keysDown.isEmpty || buttonHeld { releaseAll() }
            return
        }
        if ["d", "u", "k"].contains(type) { onActivity() }
        switch type {
        case "m":
            setPos(m)
            if pauseReason() == nil { move() }

        case "r":  // relative motion (pointer lock), in fractions of the window
            guard let dx = num(m["dx"]), let dy = num(m["dy"]), dx.isFinite, dy.isFinite else { return }
            pos = CGPoint(x: min(max(pos.x + dx, 0), 1), y: min(max(pos.y + dy, 0), 1))
            if pauseReason() == nil { move() }

        case "d":
            guard let b = (m["b"] as? NSNumber)?.intValue, (0...2).contains(b) else { return }
            setPos(m)
            if let reason = pauseReason() {
                if reason == "unfocused", locks().autoFocus { backend.focus() }
                return
            }
            if let why = InputPolicy.zoneVerdict(point: pos, zones: zones()) { return onBlocked("click", why) }
            let g = global(pos)
            guard backend.canClick(at: g) else { return onBlocked("click", "the window is covered by another one") }
            move()
            let now = ProcessInfo.processInfo.systemUptime
            let near = abs(g.x - lastClick.at.x) < 4 && abs(g.y - lastClick.at.y) < 4
            let count = (lastClick.button == b && now - lastClick.time < 0.4 && near) ? min(lastClick.count + 1, 3) : 1
            lastClick = (now, g, b, count)
            buttonsDown.insert(b)
            backend.mouseButton(b, down: true, at: g, clicks: count)

        case "u":
            guard let b = (m["b"] as? NSNumber)?.intValue, buttonsDown.contains(b) else { return }
            setPos(m)
            let g = global(pos)
            backend.mouseButton(b, down: false, at: g, clicks: lastClick.count)
            buttonsDown.remove(b)

        case "w":
            guard pauseReason() == nil, let dx = num(m["dx"]), let dy = num(m["dy"]), dx.isFinite, dy.isFinite else { return }
            setPos(m)
            guard backend.canClick(at: global(pos)) else { return }
            move()
            // Browser: positive deltaY scrolls down. CoreGraphics: positive wheel scrolls up.
            backend.scroll(dx: Int32(max(-2000, min(2000, -dx))), dy: Int32(max(-2000, min(2000, -dy))))

        case "k":
            guard let code = m["c"] as? String, let down = (m["d"] as? NSNumber)?.boolValue else { return }
            key(code, down)

        case "release":
            releaseAll()

        default:
            break
        }
    }

    private func key(_ code: String, _ down: Bool) {
        let modifier = InputPolicy.modifierCodes[code]
        if !down {
            if let modifier { mods.remove(modifier) }
            if let vk = keysDown.removeValue(forKey: code) { backend.key(vk, down: false, flags: flags) }
            // Browsers on macOS swallow the key-up of a letter while ⌘ is held: let go of everything with ⌘.
            if modifier == "Meta" {
                for (c, vk) in keysDown where InputPolicy.modifierCodes[c] == nil {
                    backend.key(vk, down: false, flags: flags)
                    keysDown[c] = nil
                }
            }
            return
        }
        guard pauseReason() == nil else { return }
        if let why = InputPolicy.keyVerdict(code: code, mods: mods, locks: locks()) {
            if keysDown[code] == nil { onBlocked(InputPolicy.label(code: code, mods: mods), why) }
            return
        }
        guard let vk = keyMap[code] else { return }
        if let modifier { mods.insert(modifier) }
        keysDown[code] = vk
        var f = flags
        if code.hasPrefix("Arrow") { f.insert([.maskNumericPad, .maskSecondaryFn]) }
        backend.key(vk, down: true, flags: f)
    }

    /// Let go of every key and button the guest holds: on disconnect, on losing control, on pause.
    func releaseAll() {
        for (code, vk) in keysDown where InputPolicy.modifierCodes[code] == nil { backend.key(vk, down: false, flags: flags) }
        mods.removeAll()
        for (code, vk) in keysDown where InputPolicy.modifierCodes[code] != nil { backend.key(vk, down: false, flags: []) }
        keysDown.removeAll()
        let g = global(pos)
        for b in buttonsDown { backend.mouseButton(b, down: false, at: g, clicks: 1) }
        buttonsDown.removeAll()
        lastGlobal = nil
    }
}
