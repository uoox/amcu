import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct AppInfo: Codable, Sendable {
    public let pid: pid_t
    public let name: String
    public let bundleID: String?
    public let active: Bool
    public let hasWindows: Bool

    public init(pid: pid_t, name: String, bundleID: String?, active: Bool, hasWindows: Bool) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.active = active
        self.hasWindows = hasWindows
    }
}

public struct WindowInfo: Codable, Sendable {
    public let windowID: CGWindowID?
    public let index: Int
    public let title: String?
    public let frame: FrameJSON
    public let minimized: Bool
    public let main: Bool

    public init(windowID: CGWindowID?, index: Int, title: String?, frame: FrameJSON, minimized: Bool, main: Bool) {
        self.windowID = windowID
        self.index = index
        self.title = title
        self.frame = frame
        self.minimized = minimized
        self.main = main
    }
}

public struct FrameJSON: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Resolves an `--app` selector to a running application.
///
/// Accepted forms, in priority order: `pid:1234`, a bundle identifier, an exact
/// localized or executable name, then a case-insensitive prefix match. Bundle id
/// and pid are the only forms stable across system languages, so ambiguity in
/// the name forms is reported rather than guessed at.
public enum Target {
    public static func runningApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .map { app in
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AX.setMessagingTimeout(element, seconds: 1.0)
                return AppInfo(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? "(unnamed)",
                    bundleID: app.bundleIdentifier,
                    active: app.isActive,
                    hasWindows: !AX.windows(element).isEmpty
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func resolveApp(_ selector: String) throws -> NSRunningApplication {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }

        if selector.hasPrefix("pid:") {
            let raw = String(selector.dropFirst(4))
            guard let value = pid_t(raw) else {
                throw UmbraError(.invalidArgument, "'\(selector)' is not a valid pid selector", nextSteps: ["Use pid:1234 with a decimal process id from `umbra apps`."])
            }
            guard let match = apps.first(where: { $0.processIdentifier == value }) else {
                throw UmbraError.appNotFound(selector)
            }
            return match
        }

        if let match = apps.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(selector) == .orderedSame }) {
            return match
        }
        if let match = apps.first(where: { $0.localizedName?.caseInsensitiveCompare(selector) == .orderedSame }) {
            return match
        }

        let prefixed = apps.filter {
            $0.localizedName?.lowercased().hasPrefix(selector.lowercased()) == true
                || $0.bundleIdentifier?.lowercased().contains(selector.lowercased()) == true
        }
        if prefixed.count == 1 { return prefixed[0] }
        if prefixed.count > 1 {
            let names = prefixed.compactMap { $0.bundleIdentifier ?? $0.localizedName }.joined(separator: ", ")
            throw UmbraError(.invalidArgument, "'\(selector)' is ambiguous: \(names)", nextSteps: [
                "Re-run with a full bundle id or pid:N to disambiguate."
            ])
        }
        throw UmbraError.appNotFound(selector)
    }

    public static func appElement(_ app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AX.setMessagingTimeout(element, seconds: 5.0)
        return element
    }

    public static func windows(of app: NSRunningApplication) throws -> [(element: AXUIElement, info: WindowInfo)] {
        let appElement = appElement(app)
        let windowElements = AX.windows(appElement)
        if windowElements.isEmpty {
            if !AXIsProcessTrusted() { throw UmbraError.notTrusted() }
            throw UmbraError(.windowNotFound, "'\(app.localizedName ?? "app")' exposes no accessibility windows", nextSteps: [
                "The application may have no open window, or it may not publish an accessibility hierarchy.",
                "If it clearly has visible windows, toggle Accessibility off and on for the host application in System Settings — macOS can hold a stale grant."
            ])
        }
        return windowElements.enumerated().map { index, element in
            let frame = AX.frame(element) ?? .zero
            let info = WindowInfo(
                windowID: AX.windowID(element),
                index: index,
                title: AX.string(element, kAXTitleAttribute as String),
                frame: FrameJSON(frame),
                minimized: AX.bool(element, kAXMinimizedAttribute as String) ?? false,
                main: AX.bool(element, kAXMainAttribute as String) ?? false
            )
            return (element, info)
        }
    }

    /// Picks the window a command should act on: an explicit id, else an explicit
    /// index, else the main window, else the first one.
    public static func selectWindow(
        of app: NSRunningApplication,
        windowID: CGWindowID?,
        windowIndex: Int?
    ) throws -> (element: AXUIElement, info: WindowInfo) {
        let all = try windows(of: app)
        if let windowID {
            guard let match = all.first(where: { $0.info.windowID == windowID }) else {
                throw UmbraError(.windowNotFound, "no window with id \(windowID) in '\(app.localizedName ?? "app")'", nextSteps: [
                    "Run `umbra windows --app <selector>` to list current window ids."
                ])
            }
            return match
        }
        if let windowIndex {
            guard windowIndex >= 0, windowIndex < all.count else {
                throw UmbraError(.windowNotFound, "window index \(windowIndex) out of range (0..\(all.count - 1))", nextSteps: [
                    "Run `umbra windows --app <selector>` to list current windows."
                ])
            }
            return all[windowIndex]
        }
        if let main = all.first(where: { $0.info.main }) { return main }
        guard let first = all.first else {
            throw UmbraError(.windowNotFound, "no windows available", nextSteps: ["Open a window in the target application first."])
        }
        return first
    }
}
