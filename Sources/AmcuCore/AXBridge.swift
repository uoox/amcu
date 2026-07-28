import ApplicationServices
import CoreGraphics
import Foundation

/// Thin, allocation-conscious wrappers over the AXUIElement C API.
public enum AX {
    public static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    public static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        if let text = value as? String { return text }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return nil }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// The full set of attributes an element claims to support, fetched in a
    /// single IPC round-trip. Probing this once and consulting the set before
    /// each `attribute` call turns N speculative cross-process reads (most of
    /// which would fail with `.attributeUnsupported`) into one.
    ///
    /// Deliberately uncached: an element's attribute list changes as the app
    /// mutates its tree (a text field gaining AXSelectedText on focus, a web
    /// area publishing children after a Chromium activation), and a stale
    /// cache would silently hide attributes that just appeared — a worse
    /// failure than the IPC it saves. Callers that walk a tree should hold the
    /// returned set for the duration of a single element's reads and no longer.
    public static func attributeNames(_ element: AXUIElement) -> Set<String> {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let list = names as? [String] else { return [] }
        return Set(list)
    }

    public static func supportsAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        attributeNames(element).contains(name)
    }

    public static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        (attribute(element, name) as? NSNumber)?.boolValue
    }

    public static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    public static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else { return [] }
        return value
    }

    public static func windows(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, kAXWindowsAttribute as String) as? [AXUIElement] else { return [] }
        return value
    }

    public static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let list = names as? [String] else { return [] }
        return list
    }

    public static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    public static func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CGPoint.zero
        guard AXValueGetValue((value as! AXValue), .cgPoint, &result) else { return nil }
        return result
    }

    public static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue((value as! AXValue), .cgSize, &result) else { return nil }
        return result
    }

    /// Screen frame in Quartz coordinates (origin top-left), which is what the
    /// Accessibility API reports and what CGEvent consumes.
    public static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element, kAXPositionAttribute as String),
              let extent = size(element, kAXSizeAttribute as String) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    public static func pid(_ element: AXUIElement) -> pid_t? {
        var value: pid_t = 0
        guard AXUIElementGetPid(element, &value) == .success else { return nil }
        return value
    }

    public static func perform(_ element: AXUIElement, _ action: String) throws {
        let status = AXUIElementPerformAction(element, action as CFString)
        guard status == .success else {
            throw AmcuError(.accessibilityFailure, "action '\(action)' failed with AXError \(status.rawValue)", nextSteps: [
                "Re-run `amcu snapshot` — the element may have moved or been replaced.",
                "Check the element's Actions list in the snapshot; only listed actions are supported."
            ])
        }
    }

    public static func setValue(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) throws {
        let status = AXUIElementSetAttributeValue(element, name as CFString, value)
        guard status == .success else {
            throw AmcuError(.accessibilityFailure, "setting '\(name)' failed with AXError \(status.rawValue)", nextSteps: [
                "Confirm the attribute is settable — the snapshot marks read-only elements.",
                "For text fields, focus the element first or use `amcu type` instead."
            ])
        }
    }

    public static func setMessagingTimeout(_ element: AXUIElement, seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    /// `_AXUIElementGetWindow` maps an AX window element to the CGWindowID that
    /// ScreenCaptureKit and the window-routed event fields both speak. It is not
    /// in the public headers, so it is resolved at runtime and every caller must
    /// tolerate its absence.
    private static let getWindowFn: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
    }()

    public static var canResolveWindowID: Bool { getWindowFn != nil }

    public static func windowID(_ element: AXUIElement) -> CGWindowID? {
        guard let fn = getWindowFn else { return nil }
        var identifier: CGWindowID = 0
        guard fn(element, &identifier) == .success, identifier != 0 else { return nil }
        return identifier
    }
}
