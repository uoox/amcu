import ApplicationServices
import CoreGraphics
import Foundation

/// Position-addressed semantic pressing.
///
/// The window-routed pointer path rides on a private CoreGraphics symbol, and
/// `SelfCheck` may find it broken after a macOS update. When that happens the
/// old answer was to move the user's real cursor (`--mode foreground`) — the
/// exact disturbance this tool exists to avoid. This is the intermediate step:
/// hit-test the accessibility tree at the target point and press the element
/// found there. No pointer event is synthesised at all, so it works with the
/// window occluded and the cursor untouched.
///
/// It is a fallback, not a replacement: a point inside a canvas or a custom-
/// drawn view resolves to a container with no press action, and pressing a
/// container would not be the click that was asked for. Callers get `nil` in
/// that case and must say so rather than act anyway.
public enum AXHitTest {
    public struct Pressed {
        public let action: String
        public let role: String?
        public let label: String?
    }

    /// Presses the deepest pressable element at a global (Quartz) point.
    ///
    /// The raw hit test often lands on decoration — the AXStaticText inside a
    /// button, the image inside a link — so the search walks up from the hit
    /// element looking for the named action, but only while the ancestor still
    /// contains the point: pressing an enclosing group whose frame extends past
    /// the target would be a different click than the one aimed.
    public static func press(pid: pid_t, at global: CGPoint, action: String = kAXPressAction as String) throws -> Pressed? {
        let app = AXUIElementCreateApplication(pid)
        AX.setMessagingTimeout(app, seconds: 2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(global.x), Float(global.y), &hit) == .success,
              var element = hit else { return nil }

        var hops = 0
        while hops < 6 {
            if AX.actions(element).contains(action) {
                if AX.bool(element, kAXEnabledAttribute as String) == false {
                    throw AmcuError(.unsupported, "the element at \(Int(global.x)),\(Int(global.y)) is currently disabled; the application would ignore the press", nextSteps: [
                        "A disabled control usually means a precondition is unmet: change the state it depends on first."
                    ])
                }
                try AX.perform(element, action)
                return Pressed(
                    action: action,
                    role: AX.string(element, kAXRoleAttribute as String),
                    label: AX.string(element, kAXTitleAttribute as String)
                        ?? AX.string(element, kAXDescriptionAttribute as String)
                )
            }
            guard let parent = AX.element(element, kAXParentAttribute as String),
                  let frame = AX.frame(parent), frame.contains(global) else { return nil }
            element = parent
            hops += 1
        }
        return nil
    }
}
