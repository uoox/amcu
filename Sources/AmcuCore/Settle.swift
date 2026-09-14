import ApplicationServices
import Foundation

/// What waiting for the interface to finish reacting to an action found out.
public struct SettleReport: Codable, Sendable {
    /// False when `max` elapsed while notifications were still arriving —
    /// the interface may still be changing.
    public let settled: Bool
    public let seconds: Double
    public let notifications: Int

    public var summary: String {
        let time = String(format: "%.1fs", seconds)
        return settled ? "settled \(time)" : "not settled after \(time), \(notifications) notifications still arriving"
    }
}

/// Waits until the target application stops emitting accessibility
/// notifications. Registered on the application element, an `AXObserver`
/// receives layout, value, focus, creation and destruction notifications for
/// every element in that application, so "no notification for `quiet`
/// seconds" is a usable definition of "done reacting".
///
/// The observer runs on this process's main run loop, which the caller spins
/// here in short slices; nothing else in a one-shot command needs that loop.
public enum Settle {
    static let notifications: [String] = [
        kAXValueChangedNotification, kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
        kAXUIElementDestroyedNotification, kAXCreatedNotification, kAXLayoutChangedNotification,
        kAXWindowCreatedNotification, kAXSheetCreatedNotification, kAXDrawerCreatedNotification,
        kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXRowCountChangedNotification,
        kAXSelectedChildrenChangedNotification, kAXSelectedRowsChangedNotification, kAXTitleChangedNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification, kAXMainWindowChangedNotification,
        kAXSelectedTextChangedNotification, kAXRowExpandedNotification, kAXRowCollapsedNotification
    ] as [String]

    final class Counter {
        var count = 0
        var last = Date.distantPast
    }

    public static func wait(pid: pid_t, timing: Policy.SettleTiming = Policy.current.settle) -> SettleReport {
        let start = Date()
        let counter = Counter()
        var observerRef: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let counter = Unmanaged<Counter>.fromOpaque(refcon).takeUnretainedValue()
            counter.count += 1
            counter.last = Date()
        }, &observerRef)
        let app = AXUIElementCreateApplication(pid)
        AX.setMessagingTimeout(app, seconds: 1.0)
        let refcon = Unmanaged.passUnretained(counter).toOpaque()
        if status == .success, let observer = observerRef {
            for name in notifications {
                AXObserverAddNotification(observer, app, name as CFString, refcon)
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        defer {
            if let observer = observerRef {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
                for name in notifications { AXObserverRemoveNotification(observer, app, name as CFString) }
            }
        }

        var settled = false
        while true {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= timing.max { break }
            let quietSince = max(counter.last, start)
            if elapsed >= timing.min, Date().timeIntervalSince(quietSince) >= timing.quiet,
               (AX.bool(app, "AXElementBusy") ?? false) == false {
                settled = true
                break
            }
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
        }
        // Without an observer (sandboxed or dying process) the minimum wait is
        // all that can be promised, which is still more than nothing.
        if observerRef == nil { settled = Date().timeIntervalSince(start) >= timing.min }
        return SettleReport(settled: settled, seconds: Date().timeIntervalSince(start), notifications: counter.count)
    }
}
