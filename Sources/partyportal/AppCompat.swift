// What we know about an app before the guest touches it.

import AppKit
import Foundation

enum AppCompat {
    /// The name of the engine when the app is built on one known to ask the system where the pointer is instead
    /// of taking it from the events it receives. Such an app cannot be given a pointer of its own from outside,
    /// so in background mode the guest's mouse does not work in it (the keyboard does).
    ///
    /// The list is what has actually been observed, not a guess: add an engine only after seeing it happen.
    static func pointerPollingEngine(pid: pid_t) -> String? {
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return nil }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        if FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("UnityPlayer.dylib").path) { return "Unity" }
        return nil
    }
}
