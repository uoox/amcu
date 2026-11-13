import Foundation
import AppKit

public struct BrowserLaunchReport: Encodable {
    public var ok: Bool { connected }
    private enum CodingKeys: String, CodingKey { case ok, identity, state, launched, connected, loginVerification }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(ok, forKey: .ok)
        try values.encode(identity, forKey: .identity)
        try values.encode(state, forKey: .state)
        try values.encode(launched, forKey: .launched)
        try values.encode(connected, forKey: .connected)
        try values.encode(loginVerification, forKey: .loginVerification)
    }
    public let identity: BrowserProfileIdentity
    public let state: String
    public let launched: Bool
    public let connected: Bool
    public let loginVerification = "unverified: bridge connection does not verify website login"
}

public enum BrowserRecovery {
    public typealias Discover = () throws -> [BrowserEndpoint]
    public typealias Launcher = (BrowserRegistryRecord, TimeInterval) throws -> Void

    public static func connected(_ identity: BrowserProfileIdentity, among endpoints: [BrowserEndpoint]) throws -> BrowserEndpoint? {
        let sameID = endpoints.filter { $0.ready && $0.instanceId == identity.instanceId }
        guard sameID.count <= 1 else { throw AmcuError(.ambiguousBrowser, "multiple live connections carry the same instance identity") }
        if let endpoint = sameID.first {
            guard identity.matches(endpoint) else {
                throw AmcuError(.ambiguousBrowser, "live instance identity has a different or unknown root/profile; refusing recovery")
            }
            return endpoint
        }
        return nil
    }

    /// Exactly one launch attempt. No installation, login, or fallback profile.
    public static func launch(_ record: BrowserRegistryRecord, timeout: TimeInterval = 30,
                              discover: Discover = { BrowserClient.discover() },
                              launcher: Launcher = workspaceLaunch,
                              now: () -> Date = Date.init,
                              wait: (TimeInterval) -> Void = { RunLoop.current.run(until: Date().addingTimeInterval($0)) }) throws -> BrowserLaunchReport {
        guard timeout.isFinite, timeout > 0, timeout <= 600 else { throw AmcuError(.invalidArgument, "timeout must be between 0 and 600 seconds") }
        if try connected(record.identity, among: discover()) != nil {
            return BrowserLaunchReport(identity: record.identity, state: "already_connected", launched: false, connected: true)
        }
        try record.identity.validateOnDisk()
        let deadline = now().addingTimeInterval(timeout)
        try launcher(record, timeout)
        repeat {
            if try connected(record.identity, among: discover()) != nil {
                return BrowserLaunchReport(identity: record.identity, state: "connected", launched: true, connected: true)
            }
            if now() >= deadline { break }
            wait(min(0.2, max(0, deadline.timeIntervalSince(now()))))
        } while now() < deadline
        return BrowserLaunchReport(identity: record.identity, state: "launched_not_connected", launched: true, connected: false)
    }

    /// Unlike Target.launch, this sends arguments even when the application already runs.
    public static func workspaceLaunch(_ record: BrowserRegistryRecord, _ timeout: TimeInterval) throws {
        guard record.identity.browser != SafariBridge.browserName,
              let path = record.applicationPath, path.hasPrefix("/"), path.hasSuffix(".app"),
              let bundleID = record.applicationBundleID,
              let bundle = Bundle(path: path), bundle.bundleIdentifier == bundleID else {
            throw AmcuError(.unsupported, "recorded Chromium application path/bundle is missing or no longer matches; refusing launch")
        }
        let priorPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let existingPID = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
        let guardFocus = existingPID.map { FocusGuard(targetPID: $0) }
        var launchedPID: pid_t?
        defer {
            let note = guardFocus?.note() ?? FocusGuard.verdict(
                targetWasFrontmost: launchedPID != nil && launchedPID == priorPID,
                targetIsFrontmostNow: launchedPID != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == launchedPID)
            if let note { FileHandle.standardError.write(Data((note + "\n").utf8)) }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.arguments = ["--user-data-dir=\(record.identity.userDataDir)", "--profile-directory=\(record.identity.profileDir)"]
        var completed = false
        var failure: Error?
        let lock = NSLock()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { app, error in
            lock.lock(); launchedPID = app?.processIdentifier; failure = error; completed = true; lock.unlock()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock(); let done = completed; let error = failure; lock.unlock()
            if done {
                if let error { throw AmcuError(.appNotFound, "browser launch failed: \(error.localizedDescription)") }
                return
            }
            // The request was submitted; a slow Launch Services callback is not permission to launch again.
            if Date() >= deadline { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
