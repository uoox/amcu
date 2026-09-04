import ApplicationServices
import Foundation

/// Whether an input delivered "in the background" stayed there.
///
/// Background delivery posts events to the target process without touching
/// the user's focus — that is the whole promise. AppKit does not always
/// cooperate: a mouse-down arriving in a non-active application's window can
/// make that application active, exactly as a real click would, and a
/// keystroke posted to a process is occasionally answered with an activation
/// too. Nothing here can undo that after the fact (and putting focus back
/// would be a second disturbance), but the result must not pretend it did not
/// happen. The frontmost application is read before and after through the
/// accessibility API rather than NSWorkspace, whose properties only update as
/// this process's run loop spins.
public struct FocusGuard: Sendable {
    public let targetPID: pid_t
    public let targetWasFrontmost: Bool

    public init(targetPID: pid_t) {
        self.targetPID = targetPID
        self.targetWasFrontmost = FocusGuard.frontmostPID() == targetPID
    }

    /// The note for an action result, or nil when the promise held. Waits a
    /// beat for the activation to propagate; an activation that arrives later
    /// than that is indistinguishable from the user's own switching.
    public func note(settleMicroseconds: UInt32 = 60_000) -> String? {
        guard !targetWasFrontmost else { return nil }
        usleep(settleMicroseconds)
        return FocusGuard.verdict(targetWasFrontmost: targetWasFrontmost, targetIsFrontmostNow: FocusGuard.frontmostPID() == targetPID)
    }

    /// The pure decision, kept separate so it can be tested without a window
    /// server: only a background target that *became* frontmost is reported.
    public static func verdict(targetWasFrontmost: Bool, targetIsFrontmostNow: Bool) -> String? {
        guard !targetWasFrontmost, targetIsFrontmostNow else { return nil }
        return "warning: the target became the frontmost application — this input activated it; no focus was restored, tell the user"
    }

    static func frontmostPID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        AX.setMessagingTimeout(systemWide, seconds: 1.0)
        guard let app = AX.element(systemWide, kAXFocusedApplicationAttribute as String) else { return nil }
        return AX.pid(app)
    }
}
