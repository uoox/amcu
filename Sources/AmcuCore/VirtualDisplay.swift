import CoreGraphics
import Foundation
import ObjectiveC

/// An extra display with no panel behind it, through CoreGraphics' private
/// `CGVirtualDisplay` (the class behind DeskPad's and BetterDisplay's virtual
/// screens). No public header declares it — the classes are exported from
/// CoreGraphics but undocumented — so every class and selector is looked up at
/// runtime and checked before it is sent: a macOS without them answers
/// `unsupported` instead of failing to launch or raising an Objective-C
/// exception. The display exists for as long as this object does.
public final class VirtualDisplay {
    public struct Identity: Sendable {
        public let name: String
        public let vendorID: UInt32
        public let productID: UInt32
        public let serial: UInt32

        public init(name: String, vendorID: UInt32, productID: UInt32, serial: UInt32) {
            self.name = name
            self.vendorID = vendorID
            self.productID = productID
            self.serial = serial
        }

        /// The public CoreGraphics getters report the descriptor's numbers back
        /// (measured on 27.2), so any process can recognise the display.
        public func matches(_ id: CGDirectDisplayID) -> Bool {
            CGDisplayVendorNumber(id) == vendorID && CGDisplayModelNumber(id) == productID && CGDisplaySerialNumber(id) == serial
        }
    }

    public let displayID: CGDirectDisplayID
    private var object: NSObject?

    private static let msgSend: UnsafeMutableRawPointer? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")

    private static let requiredSelectors: [(className: String, selectors: [String])] = [
        ("CGVirtualDisplayDescriptor", ["init", "setQueue:", "setName:", "setMaxPixelsWide:", "setMaxPixelsHigh:", "setSizeInMillimeters:", "setVendorID:", "setProductID:", "setSerialNum:", "setTerminationHandler:"]),
        ("CGVirtualDisplaySettings", ["init", "setHiDPI:", "setModes:"]),
        ("CGVirtualDisplayMode", ["initWithWidth:height:refreshRate:"]),
        ("CGVirtualDisplay", ["initWithDescriptor:", "applySettings:", "displayID"])
    ]

    /// Why this system cannot make a virtual display, or nil when it can.
    public static let unavailableReason: String? = {
        guard msgSend != nil else { return "objc_msgSend is not resolvable" }
        for (className, selectors) in requiredSelectors {
            guard let cls = NSClassFromString(className) else { return "CoreGraphics has no \(className) class" }
            for selector in selectors where !class_respondsToSelector(cls, NSSelectorFromString(selector)) {
                return "\(className) does not answer \(selector)"
            }
        }
        return nil
    }()

    private typealias AllocFn = @convention(c) (UnsafeRawPointer, Selector) -> UnsafeMutableRawPointer?
    private typealias InitModeFn = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double) -> UnsafeMutableRawPointer?
    private typealias InitWithObjectFn = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeRawPointer) -> UnsafeMutableRawPointer?
    private typealias ApplyFn = @convention(c) (UnsafeRawPointer, Selector, UnsafeRawPointer) -> Bool

    /// `pointSize` is the resolution in points; with `scale` 2 the display is
    /// HiDPI like a Retina panel. Measured on 27.2: the mode must be given in
    /// points with `hiDPI` set and the pixel maximum at twice that — a mode
    /// given in pixels comes up as an unrelated low-resolution mode.
    /// `onTermination` runs on the main queue if the system ends the display.
    public init(identity: Identity, pointSize: CGSize, scale: Int, refreshRate: Double = 60, onTermination: @escaping () -> Void) throws {
        if let reason = VirtualDisplay.unavailableReason {
            throw AmcuError(.unsupported, "this macOS cannot create a virtual display: \(reason)", nextSteps: [
                "The stage depends on CoreGraphics' private CGVirtualDisplay, which this system no longer provides as amcu knows it.",
                "Work without the stage: windows on another desktop are still driven in the background."
            ])
        }
        guard let msgSend = VirtualDisplay.msgSend,
              let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode"),
              let displayClass = NSClassFromString("CGVirtualDisplay") else {
            throw AmcuError(.unsupported, "CGVirtualDisplay could not be resolved")
        }
        let width = UInt32(max(1, pointSize.width.rounded()))
        let height = UInt32(max(1, pointSize.height.rounded()))
        let pixelScale = UInt32(scale >= 2 ? 2 : 1)

        let descriptor = descriptorClass.init()
        descriptor.setValue(DispatchQueue.main, forKey: "queue")
        descriptor.setValue(identity.name, forKey: "name")
        descriptor.setValue(NSNumber(value: width * pixelScale), forKey: "maxPixelsWide")
        descriptor.setValue(NSNumber(value: height * pixelScale), forKey: "maxPixelsHigh")
        // The system derives the display's density from its physical size;
        // 108 points per inch is an ordinary desktop panel.
        descriptor.setValue(NSValue(size: NSSize(width: Double(width) * 25.4 / 108, height: Double(height) * 25.4 / 108)), forKey: "sizeInMillimeters")
        descriptor.setValue(NSNumber(value: identity.vendorID), forKey: "vendorID")
        descriptor.setValue(NSNumber(value: identity.productID), forKey: "productID")
        descriptor.setValue(NSNumber(value: identity.serial), forKey: "serialNum")
        let handler: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in
            DispatchQueue.main.async { onTermination() }
        }
        descriptor.setValue(unsafeBitCast(handler, to: AnyObject.self), forKey: "terminationHandler")

        let alloc = unsafeBitCast(msgSend, to: AllocFn.self)
        let allocSelector = NSSelectorFromString("alloc")
        // A Swift metatype of an Objective-C class points at Swift's wrapper
        // metadata, not at the class object; bridging through AnyObject gives
        // the class object a message can be sent to.
        func receiver(_ cls: AnyClass) -> UnsafeRawPointer {
            UnsafeRawPointer(Unmanaged.passUnretained(cls as AnyObject).toOpaque())
        }

        guard let rawMode = alloc(receiver(modeClass), allocSelector),
              let initializedMode = unsafeBitCast(msgSend, to: InitModeFn.self)(rawMode, NSSelectorFromString("initWithWidth:height:refreshRate:"), width, height, refreshRate) else {
            throw AmcuError(.unsupported, "CGVirtualDisplayMode refused \(width)x\(height)")
        }
        let mode = Unmanaged<NSObject>.fromOpaque(initializedMode).takeRetainedValue()

        let settings = settingsClass.init()
        settings.setValue(NSNumber(value: pixelScale > 1 ? 1 : 0), forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")

        let display: NSObject = try withExtendedLifetime(descriptor) {
            guard let rawDisplay = alloc(receiver(displayClass), allocSelector),
                  let initialized = unsafeBitCast(msgSend, to: InitWithObjectFn.self)(rawDisplay, NSSelectorFromString("initWithDescriptor:"), Unmanaged.passUnretained(descriptor).toOpaque()) else {
                throw AmcuError(.unsupported, "the system refused to create a virtual display", nextSteps: [
                    "See `amcu stage status` and the stage log; another tool holding many virtual displays can exhaust the system's limit."
                ])
            }
            return Unmanaged<NSObject>.fromOpaque(initialized).takeRetainedValue()
        }

        let applied = withExtendedLifetime(settings) {
            unsafeBitCast(msgSend, to: ApplyFn.self)(Unmanaged.passUnretained(display).toOpaque(), NSSelectorFromString("applySettings:"), Unmanaged.passUnretained(settings).toOpaque())
        }
        guard applied, let number = display.value(forKey: "displayID") as? NSNumber, number.uint32Value != 0 else {
            throw AmcuError(.unsupported, "the virtual display did not accept a \(width)x\(height)\(pixelScale > 1 ? " HiDPI" : "") mode", nextSteps: [
                "Try a smaller --size, or --scale 1."
            ])
        }
        self.object = display
        self.displayID = number.uint32Value
    }

    /// Removes the display now. macOS moves whatever was on it to the
    /// remaining displays (measured: back where each window was before).
    public func invalidate() {
        object = nil
    }

    public var isValid: Bool { object != nil }
}
