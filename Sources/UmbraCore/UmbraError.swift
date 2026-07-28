import Foundation

/// Every failure carries a machine-readable code plus, where we know one, a
/// concrete next step. The next step is written for an agent driving this CLI:
/// it says what to do instead, not merely what went wrong.
public struct UmbraError: Error, CustomStringConvertible {
    public enum Code: String {
        case appNotFound = "app_not_found"
        case windowNotFound = "window_not_found"
        case elementNotFound = "element_not_found"
        case staleSnapshot = "stale_snapshot"
        case permissionDenied = "permission_denied"
        case unsupported = "unsupported"
        case invalidArgument = "invalid_argument"
        case accessibilityFailure = "accessibility_failure"
        case captureFailure = "capture_failure"
        case timeout = "timeout"
    }

    public let code: Code
    public let message: String
    public let nextSteps: [String]

    public init(_ code: Code, _ message: String, nextSteps: [String] = []) {
        self.code = code
        self.message = message
        self.nextSteps = nextSteps
    }

    public var description: String { "\(code.rawValue): \(message)" }

    public static func appNotFound(_ selector: String) -> UmbraError {
        UmbraError(.appNotFound, "no running application matched '\(selector)'", nextSteps: [
            "Run `umbra apps` to list running applications with their pid and bundle id.",
            "Prefer a bundle id (com.apple.finder) or pid:1234 over a display name — display names are localized and differ per system language.",
            "If the target is a website, select the browser application that shows it; selectors address desktop applications, not web pages.",
            "Do not retry the same selector unchanged."
        ])
    }

    public static func notTrusted() -> UmbraError {
        UmbraError(.permissionDenied, "this process is not trusted for Accessibility", nextSteps: [
            "Grant Accessibility to the application running umbra in System Settings > Privacy & Security > Accessibility.",
            "If it is already listed as enabled, toggle it off and on again — macOS caches a stale grant after a binary is rebuilt.",
            "Run `umbra doctor` to re-check."
        ])
    }
}
