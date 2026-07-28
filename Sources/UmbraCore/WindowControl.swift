import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Window manipulation, kept behind its own command on purpose.
///
/// Raising, moving or resizing a window is exactly the kind of visible
/// disturbance the rest of umbra is built to avoid, so it is never something
/// another command does on your behalf to make its own job easier. If a window
/// needs to move, the caller says so.
public enum WindowControl {
    public static func raise(_ element: AXUIElement) throws {
        try AX.perform(element, "AXRaise")
    }

    public static func setPosition(_ element: AXUIElement, to point: CGPoint) throws {
        guard AX.isSettable(element, kAXPositionAttribute as String) else {
            throw UmbraError(.unsupported, "this window's position is not settable", nextSteps: [
                "Some windows are fixed by their application; nothing can move them."
            ])
        }
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else {
            throw UmbraError(.unsupported, "could not encode a position value")
        }
        try AX.setValue(element, kAXPositionAttribute as String, axValue)
    }

    public static func setSize(_ element: AXUIElement, to size: CGSize) throws {
        guard AX.isSettable(element, kAXSizeAttribute as String) else {
            throw UmbraError(.unsupported, "this window's size is not settable", nextSteps: [
                "Fixed-size windows, panels and sheets usually refuse resizing."
            ])
        }
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else {
            throw UmbraError(.unsupported, "could not encode a size value")
        }
        try AX.setValue(element, kAXSizeAttribute as String, axValue)
    }

    public static func setMinimized(_ element: AXUIElement, _ minimized: Bool) throws {
        guard AX.isSettable(element, kAXMinimizedAttribute as String) else {
            throw UmbraError(.unsupported, "this window cannot be minimized or restored", nextSteps: [
                "Panels and sheets have no minimize state."
            ])
        }
        try AX.setValue(element, kAXMinimizedAttribute as String, minimized as CFTypeRef)
    }
}

/// What currently has keyboard focus inside an application.
public struct FocusInfo: Codable, Sendable {
    public let role: String?
    public let label: String?
    public let value: String?
    public let frame: FrameJSON?

    public var summary: String {
        guard let role else { return "nothing is focused" }
        let name = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        var parts = [name]
        if let label, !label.isEmpty { parts.append("\"\(label)\"") }
        if let value, !value.isEmpty { parts.append("= \"\(value.prefix(40))\"") }
        return parts.joined(separator: " ")
    }

    public var isEmpty: Bool { role == nil }

    /// Loose containment check for `--expect-focus`: matches against the role,
    /// the label, or the value, case-insensitively.
    public func matches(_ needle: String) -> Bool {
        let candidates = [role, label, value].compactMap { $0?.lowercased() }
        let wanted = needle.lowercased()
        return candidates.contains { $0.contains(wanted) }
    }
}

/// Keyboard input goes wherever the target application's own focus happens to
/// be. That is the quietest way to fail in this whole tool: the text lands
/// somewhere unintended and the command still reports success. So every typing
/// command reads the focus first and says what it found.
public enum Focus {
    public static func current(of app: NSRunningApplication) -> FocusInfo {
        let appElement = Target.appElement(app)
        guard let focused = AX.element(appElement, kAXFocusedUIElementAttribute as String) else {
            return FocusInfo(role: nil, label: nil, value: nil, frame: nil)
        }
        return FocusInfo(
            role: AX.string(focused, kAXRoleAttribute as String),
            label: SnapshotBuilder.label(of: focused),
            value: AX.string(focused, kAXValueAttribute as String),
            frame: AX.frame(focused).map(FrameJSON.init)
        )
    }

    public static func require(_ expectation: String, of app: NSRunningApplication) throws -> FocusInfo {
        let focus = current(of: app)
        guard !focus.isEmpty else {
            throw UmbraError(.elementNotFound, "nothing is focused in '\(app.localizedName ?? "the target")', so typed input has nowhere to go", nextSteps: [
                "Focus a field first: `umbra click --element N` on it, or `umbra action --element N --action AXFocus`.",
                "Run `umbra focus --app <selector>` to see the current focus."
            ])
        }
        guard focus.matches(expectation) else {
            throw UmbraError(.elementNotFound, "focus is on \(focus.summary), which does not match '\(expectation)'", nextSteps: [
                "Focus the intended field before typing.",
                "Drop --expect-focus to type into whatever is focused."
            ])
        }
        return focus
    }
}
