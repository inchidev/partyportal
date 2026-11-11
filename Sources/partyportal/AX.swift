// Accessibility helpers: find the shared window, its close/minimise/zoom buttons, focus and frame.

import AppKit
import ApplicationServices
import Foundation

// Private but long-stable call that maps an accessibility element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    private static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.25)  // never hang on a stuck app
        return el
    }

    private static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
    }

    private static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(el, &id) == .success ? id : nil
    }

    static func window(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        guard let list = copy(app(pid), kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        return list.first { windowID($0) == id }
    }

    static func focusedWindowID(pid: pid_t) -> CGWindowID? {
        guard let value = copy(app(pid), kAXFocusedWindowAttribute) else { return nil }
        return windowID(value as! AXUIElement)
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = copy(el, kAXPositionAttribute), let s = copy(el, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Global frames of the close, minimise, zoom and full-screen buttons.
    static func titleButtons(_ window: AXUIElement) -> [CGRect] {
        [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute, kAXFullScreenButtonAttribute].compactMap { attr in
            guard let button = copy(window, attr) else { return nil }
            return frame(button as! AXUIElement)
        }
    }

    static func isResizable(_ window: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
        if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) }
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
    }

    /// Which app and window the accessibility hit-test finds under `point`; nil when it cannot tell.
    static func windowAt(_ point: CGPoint) -> (pid: pid_t, window: CGWindowID?)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success, let el = found else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { return nil }
        var id = windowID(el)
        if id == nil, let w = copy(el, kAXWindowAttribute) { id = windowID(w as! AXUIElement) }
        return (pid, id)
    }

    static func unminimize(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    /// Bring the shared window to the front so the guest's input lands in it.
    static func raise(pid: pid_t, id: CGWindowID) {
        if let w = window(pid: pid, id: id) {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementSetAttributeValue(app(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}

enum WindowQuery {
    /// Live frame of a window (points, global, origin top-left) and whether it is on screen; nil when the window is gone.
    static func frame(_ id: CGWindowID) -> (CGRect, Bool)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]], let w = list.first,
            let bounds = w[kCGWindowBounds as String], let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary)
        else { return nil }
        return (rect, (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }

    static var screenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// True when the shared window is the topmost thing under `point`, so a click there cannot land anywhere else.
    /// `pid` is the app that owns the shared window.
    static func isTopmost(_ id: CGWindowID, pid: pid_t, at point: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {  // front to back
            if (w[kCGWindowNumber as String] as? CGWindowID) == id { return true }
            guard let bounds = w[kCGWindowBounds as String], let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary), rect.contains(point) else { continue }
            if ((w[kCGWindowAlpha as String] as? Double) ?? 1) < 0.01 { continue }
            // Click-through overlays (Notification Center, the screenshot UI, helper apps) span a whole display.
            // A real window of that size in front of ours would make its app the frontmost one, and then input is paused anyway.
            let owner = (w[kCGWindowOwnerPID as String] as? pid_t) ?? 0
            if owner != pid, NSScreen.screens.contains(where: { rect.width >= $0.frame.width && rect.height >= $0.frame.height - 1 }) { continue }
            return false
        }
        return false
    }
}
