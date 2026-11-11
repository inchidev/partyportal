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

/// Experimental (`--background-input`): events are addressed to the app that owns the window instead of going
/// through the system, so the host's pointer does not move and the host's app keeps the focus.
///
/// The recipe follows cua-driver (MIT, https://github.com/trycua/cua), which worked it out for background
/// computer use: post through SkyLight's `SLEventPostToPid` (the public `CGEvent.postToPid` skips a step that
/// AppKit and Chromium need to treat the event as live input), stamp every mouse event with the window it is for,
/// lead each press with a mouse-moved event so the window's tracking state is fresh, and tell the app — only the
/// app — that the window is key. These are private system calls, looked up at run time; when one is missing the
/// backend falls back to the public call and says so.
final class BackgroundInput: InputBackend {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let pid: pid_t
    private let windowID: CGWindowID
    private var last = CGPoint.zero
    private var gesture: Int64 = 1
    private var lastKeyHint = 0.0
    private var lastPress = 0.0
    /// The window's frame in global points.
    var frame: () -> CGRect = { .zero }

    private typealias PostToPid = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias SetIntegerField = @convention(c) (CGEvent, UInt32, Int64) -> Void
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias PostEventRecord = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32
    private typealias MainConnection = @convention(c) () -> UInt32
    private typealias GetWindowOwner = @convention(c) (UInt32, UInt32, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias GetConnectionPSN = @convention(c) (UInt32, UnsafeMutableRawPointer) -> Int32

    private static let anyImage: UnsafeMutableRawPointer? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        return UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    }()
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(anyImage, name).map { unsafeBitCast($0, to: type) }
    }
    private static let postToPid = symbol("SLEventPostToPid", as: PostToPid.self)
    private static let setWindowLocation = symbol("CGEventSetWindowLocation", as: SetWindowLocation.self)
    private static let setIntegerField = symbol("SLEventSetIntegerValueField", as: SetIntegerField.self)
    private static let getProcessForPID = symbol("GetProcessForPID", as: GetProcessForPID.self)
    private static let postEventRecord = symbol("SLPSPostEventRecordTo", as: PostEventRecord.self)
    private static let mainConnection = symbol("CGSMainConnectionID", as: MainConnection.self)
    private static let getWindowOwner = symbol("SLSGetWindowOwner", as: GetWindowOwner.self)
    private static let getConnectionPSN = symbol("SLSGetConnectionPSN", as: GetConnectionPSN.self)
    /// From macOS 27 the window-location stamp is a point inside the window; before that, a screen point.
    private static let windowLocationIsLocal = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    /// Without the SkyLight post call only key presses reach a background window, not the mouse.
    static var available: Bool { postToPid != nil && setIntegerField != nil }

    init(pid: pid_t, windowID: CGWindowID) {
        self.pid = pid
        self.windowID = windowID
    }

    /// Tell the app, and only the app, that this window is the one with the keyboard and mouse.
    /// The system's own idea of which app is in front does not change, and neither does the host's key window.
    private func hintWindowIsKey(wait: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKeyHint > 1, let post = Self.postEventRecord else { return }
        lastKeyHint = now
        // The process serial number of whoever owns the window: asked of the window server first,
        // with the old Carbon call as a fallback.
        var psn = [UInt32](repeating: 0, count: 2)
        var how = "none"
        if let main = Self.mainConnection, let owner = Self.getWindowOwner, let toPSN = Self.getConnectionPSN {
            var connection: UInt32 = 0
            if owner(main(), windowID, &connection) == 0, connection != 0, toPSN(connection, &psn) == 0 { how = "window server" }
        }
        if how == "none", let getPSN = Self.getProcessForPID, getPSN(pid, &psn) == 0 { how = "carbon" }
        guard how != "none" else { return }
        var record = [UInt8](repeating: 0, count: 0xf8)
        record[0x04] = 0xf8
        record[0x08] = 0x0d
        record[0x8a] = 0x01
        withUnsafeBytes(of: windowID.littleEndian) { record.replaceSubrange(0x3c..<0x40, with: $0) }
        _ = post(&psn, &record)
        // Let AppKit update its key-window routing before a press arrives, or the press is spent on making
        // the window key (the "first click only activates" rule).
        if wait { usleep(60_000) }
    }

    private func set(_ e: CGEvent, _ field: UInt32, _ value: Int64) {
        if let f = Self.setIntegerField { f(e, field, value) } else if let known = CGEventField(rawValue: field) { e.setIntegerValueField(known, value: value) }
    }

    private func post(_ e: CGEvent) {
        if let post = Self.postToPid { post(pid, e) } else { e.postToPid(pid) }
    }

    private func sendMouse(_ e: CGEvent, at p: CGPoint, clicks: Int64, button: Int64, subtype: Int64) {
        if let stamp = Self.setWindowLocation {
            let f = frame()
            stamp(e, Self.windowLocationIsLocal ? CGPoint(x: p.x - f.minX, y: p.y - f.minY) : p)
        }
        let wid = Int64(windowID)
        set(e, 1, clicks)    // click state
        set(e, 3, button)    // button number
        set(e, 7, subtype)   // 3 marks a click the way a trackpad tap does
        set(e, 51, wid)      // window number
        set(e, 58, gesture)  // one id for a move, press and release that belong together
        set(e, 91, wid)      // window under the pointer
        set(e, 92, wid)      // window under the pointer that can handle the event
        set(e, 40, Int64(pid))  // target process
        post(e)
    }

    private func button(_ b: Int) -> CGMouseButton { b == 2 ? .right : b == 1 ? .center : .left }
    private func number(_ b: Int) -> Int64 { b == 2 ? 1 : b == 1 ? 2 : 0 }

    func mouseMove(to p: CGPoint, delta: CGPoint, dragging: Int?) {
        last = p
        if dragging == nil { hintWindowIsKey(wait: false) }  // the guest hovers before pressing: get the hint out early
        let type: CGEventType = dragging == nil ? .mouseMoved : dragging == 0 ? .leftMouseDragged : dragging == 2 ? .rightMouseDragged : .otherMouseDragged
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button(dragging ?? 0)) else { return }
        e.flags = []
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        sendMouse(e, at: p, clicks: dragging == nil ? 0 : 1, button: number(dragging ?? 0), subtype: dragging == nil ? 3 : 0)
    }

    func mouseButton(_ b: Int, down: Bool, at p: CGPoint, clicks: Int) {
        last = p
        if down {
            hintWindowIsKey(wait: true)
            gesture = Int64(DispatchTime.now().uptimeNanoseconds % 1_000_000_000)
            // An app that is not active spends the first press on a window on making it key ("first mouse").
            // Spend one ourselves, just outside the window's corner where there is nothing to hit.
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPress > 3 {
                let f = frame()
                let corner = CGPoint(x: f.minX - 1, y: f.minY - 1)
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    if let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: corner, mouseButton: .left) {
                        e.flags = []
                        sendMouse(e, at: corner, clicks: 1, button: 0, subtype: 3)
                        usleep(20_000)
                    }
                }
            }
            lastPress = now
            // A backgrounded window that has not seen the pointer lately hit-tests the press in the wrong place.
            if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
                move.flags = []
                sendMouse(move, at: p, clicks: 0, button: 0, subtype: 3)
                usleep(12_000)
            }
        }
        let type: CGEventType = b == 0 ? (down ? .leftMouseDown : .leftMouseUp) : b == 2 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button(b)) else { return }
        e.flags = []
        sendMouse(e, at: p, clicks: Int64(clicks), button: number(b), subtype: 3)
    }

    func scroll(dx: Int32, dy: Int32) {
        // The window's idea of where the pointer is decides which view scrolls, so refresh it first.
        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: last, mouseButton: .left) {
            move.flags = []
            sendMouse(move, at: last, clicks: 0, button: 0, subtype: 3)
            move.postToPid(pid)
            usleep(15_000)
        }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.location = last
        e.flags = []
        if let stamp = Self.setWindowLocation {
            let f = frame()
            stamp(e, Self.windowLocationIsLocal ? CGPoint(x: last.x - f.minX, y: last.y - f.minY) : last)
        }
        let wid = Int64(windowID)
        set(e, 51, wid)
        set(e, 91, wid)
        set(e, 92, wid)
        set(e, 40, Int64(pid))
        // Known gap: none of the apps tried so far reacts to a wheel event addressed this way.
        post(e)
        e.postToPid(pid)
    }

    func key(_ code: UInt16, down: Bool, flags: CGEventFlags) {
        if down { hintWindowIsKey(wait: true) }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        set(e, 40, Int64(pid))
        post(e)
    }

    func canClick(at p: CGPoint) -> Bool { true }  // the event cannot land in another app: it is addressed to this one
    func focus() {}
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
    /// Can be swapped while sharing (the host switches background mode on or off); call `releaseAll()` first.
    var backend: InputBackend
    var locks: () -> Locks = { Locks() }
    var zones: () -> [Zone] = { [] }
    /// Window frame in global points.
    var frame: () -> CGRect = { .zero }
    /// nil when input may flow; otherwise a reason code ("unfocused", "locked", …).
    var pauseReason: () -> String? = { nil }
    var onBlocked: (_ what: String, _ why: String) -> Void = { _, _ in }
    var onActivity: () -> Void = {}
    /// Ask the owner to work out `pauseReason` again right now instead of on its next tick.
    var refresh: () -> Void = {}

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
                // The window is behind something: bring it forward, then deliver this click as a whole click
                // once it is in front, so the guest does not have to click twice.
                if reason == "unfocused", locks().autoFocus {
                    backend.focus()
                    clickWhenFocused(m, button: b, attempt: 0)
                }
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

    private func clickWhenFocused(_ m: [String: Any], button b: Int, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, !self.buttonsDown.contains(b) else { return }
            self.refresh()
            if self.pauseReason() == nil {
                self.handle(m)
                // The guest's own release has usually arrived already and was ignored, so let go ourselves.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.handle(["t": "u", "b": b]) }
            } else if attempt < 4 {
                self.clickWhenFocused(m, button: b, attempt: attempt + 1)
            }
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
