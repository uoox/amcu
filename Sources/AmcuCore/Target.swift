import AppKit
import CoreServices
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
                throw AmcuError(.invalidArgument, "'\(selector)' is not a valid pid selector", nextSteps: ["Use pid:1234 with a decimal process id from `amcu apps`."])
            }
            guard let match = apps.first(where: { $0.processIdentifier == value }) else {
                throw AmcuError.appNotFound(selector)
            }
            return match
        }

        // A bundle id can be running more than once: WeChat spawns one
        // WeChatAppEx process per mini-program batch, all with the same id.
        // When exactly one of them owns windows it is the one every window
        // command means; otherwise the choice is the caller's.
        let exactBundle = apps.filter { $0.bundleIdentifier?.caseInsensitiveCompare(selector) == .orderedSame }
        if exactBundle.count == 1 { return exactBundle[0] }
        if exactBundle.count > 1 {
            let withWindows = exactBundle.filter { app in
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AX.setMessagingTimeout(element, seconds: 1.0)
                return !AX.windows(element).isEmpty
            }
            if withWindows.count == 1 { return withWindows[0] }
            let names = exactBundle.map { app in
                "pid \(app.processIdentifier)\(withWindows.contains(app) ? " (has windows)" : "")"
            }.joined(separator: ", ")
            throw AmcuError(.invalidArgument, "'\(selector)' is running as \(exactBundle.count) processes: \(names)", nextSteps: [
                "Re-run with pid:N to pick one.",
                "`amcu windows --app pid:N` shows which process owns the window you are after."
            ])
        }
        // An exact display name can still be ambiguous: WeChat's mini-program
        // host (WeChatAppEx) calls itself 微信 just like the main process, and
        // they are different processes with different windows. Guessing here
        // sends every later event to the wrong pid, so ambiguity is reported.
        let exactName = apps.filter { $0.localizedName?.caseInsensitiveCompare(selector) == .orderedSame }
        if exactName.count == 1 { return exactName[0] }
        if exactName.count > 1 {
            let names = exactName.map { "\($0.bundleIdentifier ?? "?") (pid \($0.processIdentifier))" }.joined(separator: ", ")
            throw AmcuError(.invalidArgument, "'\(selector)' names \(exactName.count) running processes: \(names)", nextSteps: [
                "Re-run with a full bundle id or pid:N to disambiguate.",
                "They are different processes with different windows — check both if unsure which owns your target window."
            ])
        }

        let prefixed = apps.filter {
            $0.localizedName?.lowercased().hasPrefix(selector.lowercased()) == true
                || $0.bundleIdentifier?.lowercased().contains(selector.lowercased()) == true
        }
        if prefixed.count == 1 { return prefixed[0] }
        if prefixed.count > 1 {
            let names = prefixed.compactMap { $0.bundleIdentifier ?? $0.localizedName }.joined(separator: ", ")
            throw AmcuError(.invalidArgument, "'\(selector)' is ambiguous: \(names)", nextSteps: [
                "Re-run with a full bundle id or pid:N to disambiguate."
            ])
        }
        throw AmcuError.appNotFound(selector)
    }

    public static func appElement(_ app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AX.setMessagingTimeout(element, seconds: 5.0)
        // Chromium/Electron apps publish an empty tree until told otherwise;
        // activation is idempotent and whitelisted, so doing it on every
        // resolution is the cheapest way to guarantee it happened before any
        // read. Native apps are never touched — the flag degrades their trees.
        // The whitelist is backed by a look at the bundle itself, so an
        // Electron app nobody listed still gets its tree.
        if ChromiumAccessibility.requiresActivation(bundleID: app.bundleIdentifier)
            || ChromiumAccessibility.looksLikeChromiumHost(bundleURL: app.bundleURL) {
            ChromiumAccessibility.activate(pid: app.processIdentifier)
        }
        return element
    }

    public static func windows(of app: NSRunningApplication) throws -> [(element: AXUIElement, info: WindowInfo)] {
        let appElement = appElement(app)
        let windowElements = AX.windows(appElement)
        if windowElements.isEmpty {
            if !AXIsProcessTrusted() { throw AmcuError.notTrusted() }
            throw AmcuError(.windowNotFound, "'\(app.localizedName ?? "app")' exposes no accessibility windows", nextSteps: [
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
                throw AmcuError(.windowNotFound, "no window with id \(windowID) in '\(app.localizedName ?? "app")'", nextSteps: [
                    "Run `amcu windows --app <selector>` to list current window ids."
                ])
            }
            return match
        }
        if let windowIndex {
            guard windowIndex >= 0, windowIndex < all.count else {
                throw AmcuError(.windowNotFound, "window index \(windowIndex) out of range (0..\(all.count - 1))", nextSteps: [
                    "Run `amcu windows --app <selector>` to list current windows."
                ])
            }
            return all[windowIndex]
        }
        if let main = all.first(where: { $0.info.main }) { return main }
        guard let first = all.first else {
            throw AmcuError(.windowNotFound, "no windows available", nextSteps: ["Open a window in the target application first."])
        }
        return first
    }
}

/// An application on disk, whether or not it is running — from Spotlight's
/// last-used metadata, the way Sky's `list_apps` does it.
public struct InstalledApp: Codable, Sendable {
    public let name: String
    public let bundleID: String?
    public let path: String
    public let lastUsed: Date?
    public let useCount: Int?
    public let running: Bool
}

extension Target {
    /// Applications used within `days`, most recent first.
    public static func recentApps(days: Int = 14, limit: Int = 60) -> [InstalledApp] {
        let query = "kMDItemContentType == \"com.apple.application-bundle\" && kMDItemLastUsedDate >= $time.today(-\(days))"
        guard let q = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil) else { return [] }
        MDQuerySetMaxCount(q, limit * 3)
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }
        var out: [InstalledApp] = []
        for i in 0..<MDQueryGetResultCount(q) {
            let item = unsafeBitCast(MDQueryGetResultAtIndex(q, i), to: MDItem.self)
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let name = (MDItemCopyAttribute(item, kMDItemDisplayName) as? String).map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            out.append(InstalledApp(
                name: name,
                bundleID: MDItemCopyAttribute(item, kMDItemCFBundleIdentifier) as? String,
                path: path,
                lastUsed: MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date,
                useCount: (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue,
                running: running.contains(path)
            ))
        }
        return Array(out.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }.prefix(limit))
    }

    /// Finds an application bundle for a selector that names nothing running:
    /// a bundle id via Launch Services, else a display name via Spotlight.
    public static func installedApp(_ selector: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: selector) { return url }
        let escaped = selector.replacingOccurrences(of: "\"", with: "\\\"")
        let query = "kMDItemContentType == \"com.apple.application-bundle\" && (kMDItemDisplayName == \"\(escaped)\"c || kMDItemDisplayName == \"\(escaped).app\"c || kMDItemFSName == \"\(escaped).app\"c)"
        guard let q = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil) else { return nil }
        MDQuerySetMaxCount(q, 5)
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)), MDQueryGetResultCount(q) > 0 else { return nil }
        var candidates: [String] = []
        for i in 0..<MDQueryGetResultCount(q) {
            let item = unsafeBitCast(MDQueryGetResultAtIndex(q, i), to: MDItem.self)
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { candidates.append(path) }
        }
        // /Applications and /System/Applications before anything in a build
        // directory or a Time Machine copy.
        let preferred = candidates.sorted { a, b in
            func rank(_ p: String) -> Int { p.hasPrefix("/Applications/") ? 0 : p.hasPrefix("/System/Applications/") ? 1 : 2 }
            return rank(a) < rank(b)
        }
        return preferred.first.map { URL(fileURLWithPath: $0) }
    }

    public struct LaunchOutcome {
        public let app: NSRunningApplication
        public let wasRunning: Bool
        public let ready: Bool
        public let waited: Double
    }

    /// Launches without activating (the user's focus stays where it is) and
    /// waits until the application publishes a real window: one with a
    /// non-zero size, which is what distinguishes it from the placeholder a
    /// starting application exposes for its first second or two.
    public static func launch(_ selector: String, timeout: Double, waitForWindow: Bool) throws -> LaunchOutcome {
        let start = Date()
        if let running = try? resolveApp(selector) {
            let ready = waitForWindow ? waitForRealWindow(running, until: start.addingTimeInterval(timeout)) : true
            return LaunchOutcome(app: running, wasRunning: true, ready: ready, waited: Date().timeIntervalSince(start))
        }
        guard let url = installedApp(selector) else {
            throw AmcuError(.appNotFound, "no installed application matched '\(selector)'", nextSteps: [
                "Use a bundle id (com.apple.Notes) or the application's display name.",
                "`amcu apps --recent` lists recently used applications with their bundle ids."
            ])
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let semaphore = DispatchSemaphore(value: 0)
        var launched: NSRunningApplication?
        var failure: Error?
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            launched = app
            failure = error
            semaphore.signal()
        }
        // The completion handler arrives on a private queue; the main run loop
        // is spun so AppKit can do its own bookkeeping meanwhile.
        while semaphore.wait(timeout: .now()) != .success {
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
            if Date().timeIntervalSince(start) > timeout {
                throw AmcuError(.timeout, "launching \(url.lastPathComponent) did not complete within \(Int(timeout))s")
            }
        }
        guard let app = launched else {
            throw AmcuError(.unsupported, "could not launch \(url.lastPathComponent): \(failure?.localizedDescription ?? "unknown error")")
        }
        let ready = waitForWindow ? waitForRealWindow(app, until: start.addingTimeInterval(timeout)) : true
        return LaunchOutcome(app: app, wasRunning: false, ready: ready, waited: Date().timeIntervalSince(start))
    }

    static func waitForRealWindow(_ app: NSRunningApplication, until deadline: Date) -> Bool {
        while Date() < deadline {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AX.setMessagingTimeout(element, seconds: 1.0)
            let real = AX.windows(element).contains { window in
                guard let frame = AX.frame(window) else { return false }
                return frame.width > 1 && frame.height > 1
            }
            if real { return true }
            CFRunLoopRunInMode(.defaultMode, 0.1, false)
        }
        return false
    }
}
