import Foundation
import AmcuCore

func runBrowserTaskStoreTests(_ t: Harness) {
    t.suite("browser task persistence and partial recovery")
    do {
        let root = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().appendingPathComponent(".amcu-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserTaskStore(directory: root)
        let a = try BrowserProfileIdentity(browser: "chrome", instanceId: "a-full", userDataDir: root.path, profileDir: "Default")
        let b = try BrowserProfileIdentity(browser: "chrome", instanceId: "b-full", userDataDir: root.path, profileDir: "Profile 2")
        let url = "https://example.test/path?explicit=private#fragment"
        _ = try store.save(name: "work", identity: a, url: url, tabHint: 1, session: "same")
        let first = try store.load(name: "work")
        _ = try store.save(name: "work", identity: b, url: "https://other.test/", tabHint: 2, session: "same")
        _ = try store.save(name: "work", identity: a, url: url, tabHint: 3, session: "changed")
        let task = try store.load(name: "work")
        t.expectEqual(task.entries.count, 2, "repeated save replaces only matching profile")
        t.expectEqual(task.entries[0].session, first.entries[0].session, "replacement preserves isolated session")
        t.expect(task.entries[0].session != task.entries[1].session, "same explicit prefix does not share sessions")
        t.expectEqual(try JSONDecoder().decode(BrowserTask.self, from: JSONEncoder().encode(task)), task, "task round trip preserves URL query and hints")
        for bad in ["file:///tmp/x", "javascript:alert(1)", "https://u:p@example.test/", "https:///", "https://example.test/\n"] {
            t.expectThrows("reject unsafe URL \(bad.debugDescription)") { try BrowserTaskStore.validateURL(bad) }
        }
        let lease = try store.acquireResume(name: "work")
        t.expectThrows("concurrent resume refused without browser lock") { _ = try store.acquireResume(name: "work") }
        _ = try store.list()
        try store.releaseResume(token: lease)
        let nextLease = try store.acquireResume(name: "work")
        try store.releaseResume(token: nextLease)
        func writeLease(pid: Int32?) throws {
            var item: [String: Any] = ["name": "work", "token": "crashed", "expires": Date().addingTimeInterval(86400).timeIntervalSinceReferenceDate]
            if let pid { item["ownerPID"] = pid }
            try JSONSerialization.data(withJSONObject: ["items": [item]]).write(to: root.appendingPathComponent("task-leases.json"))
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        try writeLease(pid: child.processIdentifier)
        let reclaimed = try store.acquireResume(name: "work")
        t.expect(!reclaimed.isEmpty, "dead owner lease reclaimed immediately, not after 24h")
        try store.releaseResume(token: reclaimed)
        try writeLease(pid: nil)
        let legacy = try store.acquireResume(name: "work")
        t.expect(!legacy.isEmpty, "legacy ownerless lease does not block recovery")
        try store.releaseResume(token: legacy)
        let endpoint = BrowserEndpoint(browser: "chrome", pid: 1, socket: "/unused", instanceId: a.instanceId, userDataDir: a.userDataDir, profileDir: a.profileDir)
        var tabs = [BrowserRecoveryTab(id: 99, url: url)]
        var binds = 0; var opens = 0; var launches = 0
        let ops = BrowserTaskOperations(discover: { [endpoint] }, tabs: { _ in tabs }, bind: { _, _, _ in binds += 1 }, open: { _, entry in
            opens += 1
            let tab = BrowserRecoveryTab(id: 100, url: entry.url, verifiedOnStage: entry.stage)
            tabs.append(tab); return tab
        }, launch: { _ in launches += 1 })
        let status = BrowserTaskRecovery.run(task, operations: ops)
        t.expectEqual(status.map(\.state), ["available", "offline"], "status is read-only and reports partial offline entries")
        t.expect(binds == 0 && opens == 0 && launches == 0, "status never binds, opens, or launches")
        t.expect(!BrowserTaskRecoveryReport(progress: status).ok, "partial offline status has ok false")
        let resumed = BrowserTaskRecovery.run(task, resume: true, operations: ops)
        t.expectEqual(resumed.map(\.state), ["bound", "offline"], "resume binds exact URL and continues offline entry")
        t.expectEqual(binds, 1, "tab hint is not authority for non-stage exact URL")
        tabs.append(BrowserRecoveryTab(id: 101, url: url))
        t.expectEqual(BrowserTaskRecovery.run(task, resume: true, openMissing: true, operations: ops).first?.state, "ambiguous_url", "duplicate exact URL never guessed or duplicated")
        tabs = []
        t.expectEqual(BrowserTaskRecovery.run(task, resume: true, operations: ops).first?.state, "missing_page", "default never opens missing URL")
        _ = BrowserTaskRecovery.run(task, resume: true, openMissing: true, operations: ops)
        _ = BrowserTaskRecovery.run(task, resume: true, openMissing: true, operations: ops)
        t.expectEqual(opens, 1, "rerunning reuses unique opened URL")
        t.expectEqual(launches, 0, "open-missing does not imply launch-missing")
        _ = BrowserTaskRecovery.run(task, resume: true, launchMissing: true, operations: ops)
        t.expectEqual(launches, 1, "launch missing is explicit and attempted once per offline entry")
        _ = try store.save(name: "staged", identity: a, url: url, tabHint: 3, stage: true)
        let staged = try store.load(name: "staged")
        tabs = [BrowserRecoveryTab(id: 3, url: url)]
        t.expectEqual(BrowserTaskRecovery.run(staged, resume: true, openMissing: true, operations: ops).first?.state, "stage_pending", "matching saved hint off stage never moved or duplicated")
        tabs = [BrowserRecoveryTab(id: 900, url: url, verifiedOnStage: true)]
        let stagedResume = BrowserTaskRecovery.run(staged, resume: true, operations: ops)
        t.expectEqual(stagedResume.first?.state, "bound", "verified current stage tab binds despite changed id after restart")
        t.expect(BrowserTaskRecoveryReport(progress: stagedResume).ok, "complete recovery has ok true")
        try store.recordOpened(name: "staged", entry: staged.entries[0], tab: 50)
        t.expectEqual(try store.load(name: "staged").entries[0].tabHint, 50, "new stage tab hint persists for rerun")
    } catch { t.expect(false, "task fixture failed: \(error)") }
}
