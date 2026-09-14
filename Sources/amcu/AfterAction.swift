import AppKit
import ApplicationServices
import Foundation
import AmcuCore

/// The part of every action that happens after the input was delivered:
/// wait for the application to finish reacting, check whether a background
/// input took focus, then re-capture the session's snapshot and diff it.
///
/// Observation only happens when the session already holds an accessibility
/// snapshot of the same application; a bare `type` into an app that was
/// never snapshotted has nothing to diff against and reports nothing extra.
/// `--no-observe` skips the re-capture (settling still happens: the focus
/// check and any read-back depend on it).
enum AfterAction {
    static func run(flags: Flags, app: NSRunningApplication, guarded: FocusGuard?) -> Aftermath {
        var aftermath = Aftermath()
        aftermath.settle = Settle.wait(pid: app.processIdentifier)
        aftermath.focusNote = guarded?.note(settleMicroseconds: 0)
        guard !flags.has("no-observe") else { return aftermath }
        aftermath.observation = observe(flags: flags, app: app)
        return aftermath
    }

    static func observe(flags: Flags, app: NSRunningApplication) -> SnapshotDiff? {
        let session = Commands.session(flags)
        guard let previous = SessionStore.loadIfPresent(session: session),
              previous.app.pid == app.processIdentifier,
              !previous.nodes.contains(where: { $0.origin == .vision }) else { return nil }
        guard let window = try? Commands.snapshotWindow(for: previous, app: app) else {
            return SnapshotDiff(changed: 0, added: 0, removed: previous.nodes.count, text: "# the snapshot's window is gone; take a new `amcu snapshot`", full: false)
        }
        var limits = SnapshotLimits()
        limits.maxNodes = previous.maxNodes
        let appInfo = AppInfo(pid: app.processIdentifier, name: app.localizedName ?? "(unnamed)", bundleID: app.bundleIdentifier, active: app.isActive, hasWindows: true)
        let fresh = SnapshotBuilder.capture(app: appInfo, window: window.info, windowElement: window.element, limits: limits, shaping: previous.shaped, previous: previous)
        try? SessionStore.save(fresh, session: session)
        return fresh.diff(from: previous)
    }
}
