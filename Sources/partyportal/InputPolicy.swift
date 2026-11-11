// What the guest may and may not do. Pure functions: no system calls, easy to test.
// Everything here runs on the host, so a guest who bypasses the page still hits the same rules.

import CoreGraphics
import Foundation

struct Zone {
    var rect: CGRect  // window-relative, 0…1
    var why: String
}

enum InputPolicy {
    static let modifierCodes: [String: String] = [
        "ShiftLeft": "Shift", "ShiftRight": "Shift", "ControlLeft": "Control", "ControlRight": "Control",
        "AltLeft": "Alt", "AltRight": "Alt", "MetaLeft": "Meta", "MetaRight": "Meta",
    ]

    /// System-wide shortcuts that would take the guest out of the window. Always blocked.
    static let systemShortcuts = [
        "Meta+Tab", "Meta+Space", "Meta+Backquote", "Meta+Alt+Escape", "Meta+Alt+KeyD", "Meta+Alt+KeyH", "Meta+Alt+KeyW",
        "Control+ArrowUp", "Control+ArrowDown", "Control+ArrowLeft", "Control+ArrowRight", "Control+Meta+KeyQ",
        "Meta+Shift+Digit3", "Meta+Shift+Digit4", "Meta+Shift+Digit5", "Meta+Shift+KeyQ", "Control+Meta+Space",
        "Control+F2", "Control+F3", "Control+F4", "Control+F7", "Control+F8", "F11", "Meta+F3", "Meta+Shift+Slash",
    ]

    /// "Meta+Shift+KeyW" → modifiers and key code.
    static func parse(_ shortcut: String) -> (mods: Set<String>, code: String) {
        var parts = shortcut.split(separator: "+").map(String.init)
        let code = parts.popLast() ?? ""
        return (Set(parts), code)
    }

    /// A shortcut matches when its key is pressed and all its modifiers are held; extra modifiers do not help the guest.
    static func matches(_ shortcut: String, code: String, mods: Set<String>) -> Bool {
        let s = parse(shortcut)
        return s.code == code && s.mods.isSubset(of: mods)
    }

    /// Reason the key press is refused, or nil when it may go through.
    static func keyVerdict(code: String, mods: Set<String>, locks: Locks) -> String? {
        if !locks.keyboard { return "keyboard is turned off by the host" }
        if modifierCodes[code] != nil { return nil }
        if systemShortcuts.contains(where: { matches($0, code: code, mods: mods) }) { return "system shortcut" }
        switch locks.cmdMode {
        case "all":
            if mods.contains("Meta") { return "⌘ shortcuts are blocked by the host" }
        case "list":
            if locks.blockedShortcuts.contains(where: { matches($0, code: code, mods: mods) }) { return "blocked by the host" }
        default:
            break
        }
        return nil
    }

    static func zoneVerdict(point: CGPoint, zones: [Zone]) -> String? {
        zones.first(where: { $0.rect.contains(point) })?.why
    }

    /// "⌘Q" for the guest's toast and the host's journal.
    static func label(code: String, mods: Set<String>) -> String {
        var s = ""
        if mods.contains("Control") { s += "⌃" }
        if mods.contains("Alt") { s += "⌥" }
        if mods.contains("Shift") { s += "⇧" }
        if mods.contains("Meta") { s += "⌘" }
        var key = code
        for prefix in ["Key", "Digit", "Arrow"] where key.hasPrefix(prefix) && key.count > prefix.count { key = String(key.dropFirst(prefix.count)) }
        return s + key
    }
}

/// KeyboardEvent.code → macOS virtual key code (physical position, layout independent).
let keyMap: [String: UInt16] = [
    "KeyA": 0x00, "KeyS": 0x01, "KeyD": 0x02, "KeyF": 0x03, "KeyH": 0x04, "KeyG": 0x05, "KeyZ": 0x06, "KeyX": 0x07,
    "KeyC": 0x08, "KeyV": 0x09, "IntlBackslash": 0x0A, "KeyB": 0x0B, "KeyQ": 0x0C, "KeyW": 0x0D, "KeyE": 0x0E, "KeyR": 0x0F,
    "KeyY": 0x10, "KeyT": 0x11, "Digit1": 0x12, "Digit2": 0x13, "Digit3": 0x14, "Digit4": 0x15, "Digit6": 0x16, "Digit5": 0x17,
    "Equal": 0x18, "Digit9": 0x19, "Digit7": 0x1A, "Minus": 0x1B, "Digit8": 0x1C, "Digit0": 0x1D, "BracketRight": 0x1E,
    "KeyO": 0x1F, "KeyU": 0x20, "BracketLeft": 0x21, "KeyI": 0x22, "KeyP": 0x23, "Enter": 0x24, "KeyL": 0x25, "KeyJ": 0x26,
    "Quote": 0x27, "KeyK": 0x28, "Semicolon": 0x29, "Backslash": 0x2A, "Comma": 0x2B, "Slash": 0x2C, "KeyN": 0x2D, "KeyM": 0x2E,
    "Period": 0x2F, "Tab": 0x30, "Space": 0x31, "Backquote": 0x32, "Backspace": 0x33, "Escape": 0x35, "MetaRight": 0x36,
    "MetaLeft": 0x37, "ShiftLeft": 0x38, "CapsLock": 0x39, "AltLeft": 0x3A, "ControlLeft": 0x3B, "ShiftRight": 0x3C,
    "AltRight": 0x3D, "ControlRight": 0x3E, "NumpadDecimal": 0x41, "NumpadMultiply": 0x43, "NumpadAdd": 0x45, "NumLock": 0x47,
    "NumpadDivide": 0x4B, "NumpadEnter": 0x4C, "NumpadSubtract": 0x4E, "NumpadEqual": 0x51, "Numpad0": 0x52, "Numpad1": 0x53,
    "Numpad2": 0x54, "Numpad3": 0x55, "Numpad4": 0x56, "Numpad5": 0x57, "Numpad6": 0x58, "Numpad7": 0x59, "Numpad8": 0x5B,
    "Numpad9": 0x5C, "F5": 0x60, "F6": 0x61, "F7": 0x62, "F3": 0x63, "F8": 0x64, "F9": 0x65, "F11": 0x67, "F13": 0x69,
    "F14": 0x6B, "F10": 0x6D, "F12": 0x6F, "F15": 0x71, "Insert": 0x72, "Home": 0x73, "PageUp": 0x74, "Delete": 0x75,
    "F4": 0x76, "End": 0x77, "F2": 0x78, "PageDown": 0x79, "F1": 0x7A, "ArrowLeft": 0x7B, "ArrowRight": 0x7C,
    "ArrowDown": 0x7D, "ArrowUp": 0x7E,
]
