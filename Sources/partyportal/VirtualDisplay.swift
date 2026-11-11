// Experimental (`--virtual-display`): a monitor that exists only in software. A window parked on it is not
// covered by anything, so its app keeps drawing at full rate, and it is not in the host's way.
//
// CGVirtualDisplay is a private CoreGraphics class (the one display utilities such as BetterDisplay build on),
// reached through the Objective-C runtime so that a macOS without it simply reports "not available".

import AppKit
import CoreGraphics
import Foundation

final class VirtualDisplay {
    private var display: NSObject?
    private static var serial = Int(Date().timeIntervalSince1970) % 100_000
    /// Why the last attempt failed, for the journal.
    static var lastFailure = ""
    private(set) var displayID: CGDirectDisplayID = 0

    /// Bounds of the virtual monitor in global points, once it exists.
    var bounds: CGRect { CGDisplayBounds(displayID) }

    init?(name: String, pointsWide: Int, pointsHigh: Int) {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
            let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
            let modeClass = NSClassFromString("CGVirtualDisplayMode"), let displayClass = NSClassFromString("CGVirtualDisplay")
        else {
            Self.lastFailure = "the CGVirtualDisplay classes are missing"
            return nil
        }

        let descriptor = descriptorClass.init()
        descriptor.setValue(name, forKey: "name")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")
        descriptor.setValue(pointsWide * 2, forKey: "maxPixelsWide")
        descriptor.setValue(pointsHigh * 2, forKey: "maxPixelsHigh")
        // A plausible physical size, so macOS picks a sane scale: about 110 points per inch.
        descriptor.setValue(NSValue(size: NSSize(width: Double(pointsWide) / 110 * 25.4, height: Double(pointsHigh) / 110 * 25.4)), forKey: "sizeInMillimeters")
        descriptor.setValue(0x5050, forKey: "vendorID")
        descriptor.setValue(0x5054, forKey: "productID")
        // A fresh serial number each time: macOS refuses a second monitor that looks identical to one it just lost.
        Self.serial += 1
        descriptor.setValue(Self.serial, forKey: "serialNum")

        // -[CGVirtualDisplay initWithDescriptor:]
        // The init family hands back an object we own. Declared as Unmanaged so Swift does not add a retain of
        // its own: with one too many the display object is never released, and the monitor never goes away.
        typealias InitWithDescriptor = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
        let initSel = NSSelectorFromString("initWithDescriptor:")
        guard let allocated = (displayClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
            let initIMP = class_getMethodImplementation(displayClass, initSel)
        else { return nil }
        guard let made = unsafeBitCast(initIMP, to: InitWithDescriptor.self)(allocated, initSel, descriptor)?.takeRetainedValue() as? NSObject else {
            Self.lastFailure = "the system refused to create the display"
            return nil
        }

        // -[CGVirtualDisplayMode initWithWidth:height:refreshRate:]
        typealias InitMode = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<AnyObject>?
        let modeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let modeAlloc = (modeClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
            let modeIMP = class_getMethodImplementation(modeClass, modeSel),
            let mode = unsafeBitCast(modeIMP, to: InitMode.self)(modeAlloc, modeSel, UInt(pointsWide), UInt(pointsHigh), 60)?.takeRetainedValue()
        else { return nil }

        let settings = settingsClass.init()
        settings.setValue(1, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let applySel = NSSelectorFromString("applySettings:")
        guard let applyIMP = class_getMethodImplementation(displayClass, applySel), unsafeBitCast(applyIMP, to: Apply.self)(made, applySel, settings) else {
            Self.lastFailure = "the system refused the display mode \(pointsWide)×\(pointsHigh)"
            return nil
        }

        display = made
        displayID = (made.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
        if displayID == 0 {
            Self.lastFailure = "the display has no id"
            return nil
        }
    }

    /// macOS puts a new monitor beside the main one, sharing a whole edge, so the host's pointer slides onto it
    /// and disappears. Move it so that only a corner touches: below and to the left of the main screen.
    func moveOutOfTheWay() {
        let main = CGDisplayBounds(CGMainDisplayID())
        let mine = bounds
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayOrigin(config, displayID, Int32(main.minX - mine.width), Int32(main.maxY))
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    /// Let go of the monitor: macOS removes it and moves any windows left on it back to a real screen.
    func remove() {
        display = nil
        displayID = 0
    }
}
