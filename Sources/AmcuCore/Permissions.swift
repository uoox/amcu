import ApplicationServices
import CoreGraphics
import Foundation

public struct PermissionState: Codable, Sendable {
    public let id: String
    public let granted: Bool
    public let detail: String
}

public enum Permissions {
    public static var accessibility: PermissionState {
        let trusted = AXIsProcessTrusted()
        return PermissionState(
            id: "accessibility",
            granted: trusted,
            detail: trusted
                ? "reading and acting on user interfaces is permitted"
                : "System Settings > Privacy & Security > Accessibility — add and enable the application running amcu"
        )
    }

    public static var screenRecording: PermissionState {
        let granted = CGPreflightScreenCaptureAccess()
        return PermissionState(
            id: "screen_recording",
            granted: granted,
            detail: granted
                ? "window capture is permitted"
                : "System Settings > Privacy & Security > Screen Recording — required only for `amcu screenshot`"
        )
    }

    public static func all() -> [PermissionState] {
        [accessibility, screenRecording]
    }

    /// Asks the system to show its permission prompt. Only meaningful the first
    /// time; afterwards the user has to act in System Settings.
    public static func request() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        CGRequestScreenCaptureAccess()
    }

    public static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else { throw AmcuError.notTrusted() }
    }
}
