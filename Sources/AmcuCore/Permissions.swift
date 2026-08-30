import ApplicationServices
import CoreGraphics
import Foundation

public struct PermissionState: Codable, Sendable {
    public let id: String
    public let granted: Bool
    public let detail: String

    public init(id: String, granted: Bool, detail: String) {
        self.id = id
        self.granted = granted
        self.detail = detail
    }
}

/// The raw answer a single TCC subject gives; what `__permission-probe`
/// prints and what `doctor` decodes back.
public struct PermissionProbe: Codable, Sendable {
    public let accessibility: Bool
    public let screenRecording: Bool

    enum CodingKeys: String, CodingKey {
        case accessibility
        case screenRecording = "screen_recording"
    }

    public init(accessibility: Bool, screenRecording: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }
}

public enum Permissions {
    /// Answers for whatever subject TCC attributes *this* process to — the
    /// hosting app in a terminal, amcu itself under launchd or a disclaimed
    /// spawn. This is the state every other amcu command runs with.
    public static func probeNow() -> PermissionProbe {
        PermissionProbe(
            accessibility: AXIsProcessTrusted(),
            screenRecording: CGPreflightScreenCaptureAccess()
        )
    }

    /// Answers for the amcu binary itself, regardless of who hosts this run,
    /// by re-running amcu with responsibility disclaimed. nil when the
    /// disclaim mechanism is unavailable or the child fails.
    public static func selfProbe(request: Bool = false) -> PermissionProbe? {
        var arguments = ["__permission-probe"]
        if request { arguments.append("--request") }
        guard let data = Responsibility.spawnSelfDisclaimed(arguments: arguments) else { return nil }
        return try? JSONDecoder().decode(PermissionProbe.self, from: data)
    }

    /// The runtime-effective states, with the grant target named when known:
    /// "enable dinotty" beats "enable the application running amcu" — the
    /// vague phrasing is exactly what sends people off to grant the amcu
    /// binary, which a terminal-hosted run never consults.
    public static func effective(hostName: String? = nil) -> [PermissionState] {
        let who = hostName.map { "\"\($0)\", the app running amcu" } ?? "the application running amcu"
        let probe = probeNow()
        return [
            PermissionState(
                id: "accessibility",
                granted: probe.accessibility,
                detail: probe.accessibility
                    ? "reading and acting on user interfaces is permitted"
                    : "System Settings > Privacy & Security > Accessibility — add and enable \(who)"
            ),
            PermissionState(
                id: "screen_recording",
                granted: probe.screenRecording,
                detail: probe.screenRecording
                    ? "window capture is permitted"
                    : "System Settings > Privacy & Security > Screen Recording — enable \(who); required only for `amcu screenshot`"
            ),
        ]
    }

    public static func all() -> [PermissionState] {
        effective()
    }

    /// Asks the system to show its permission prompt. Only meaningful the first
    /// time; afterwards the user has to act in System Settings. The prompt is
    /// attributed to the responsible process — the host — which is where the
    /// grant belongs for terminal-hosted runs.
    public static func request() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        CGRequestScreenCaptureAccess()
    }

    public static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else { throw AmcuError.notTrusted() }
    }
}
