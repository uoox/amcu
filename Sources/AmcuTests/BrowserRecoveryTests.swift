import Foundation
import AmcuCore

func runBrowserRecoveryTests(_ t: Harness) {
    t.suite("browser exact identity recovery")
    do {
        let root = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().appendingPathComponent(".amcu-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("Default/Local Extension Settings/\(BrowserBridge.extensionID)")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data("amcu_instance_full-id".utf8).write(to: store.appendingPathComponent("1.log"))
        let identity = try BrowserProfileIdentity(browser: "chrome", instanceId: "full-id", userDataDir: root.path, profileDir: "Default")
        let endpoint = BrowserEndpoint(browser: "chrome", pid: 7, socket: "/unused", instanceId: "full-id", userDataDir: root.path, profileDir: "Default")
        let wrong = BrowserEndpoint(browser: "chrome", pid: 8, socket: "/unused2", instanceId: "full-id", userDataDir: root.path, profileDir: "Profile 2")
        t.expect(identity.matches(endpoint), "full id/root/dir match")
        t.expect(!identity.matches(wrong), "same id with different directory does not match")
        t.expectThrows("duplicate live id refused") { _ = try BrowserRecovery.connected(identity, among: [endpoint, endpoint]) }
        t.expectThrows("conflicting live root/dir refused") { _ = try BrowserRecovery.connected(identity, among: [wrong]) }
        let record = BrowserRegistryRecord(identity: identity)
        var launches = 0
        let connected = try BrowserRecovery.launch(record, discover: { [endpoint] }, launcher: { _, _ in launches += 1 })
        t.expectEqual(connected.state, "already_connected", "connected identity only reports")
        t.expectEqual(launches, 0, "connected identity never launches")
        var time = Date()
        let timed = try BrowserRecovery.launch(record, timeout: 1, discover: { [] }, launcher: { _, _ in launches += 1 }, now: { time }, wait: { time.addTimeInterval($0) })
        t.expect(!timed.ok, "bridge timeout has ok false, not launch success")
        t.expectEqual(timed.state, "launched_not_connected", "timeout honestly reports submitted launch without bridge")
        t.expectEqual(launches, 1, "timeout never retries launch")
        var discoveries = 0
        let recovered = try BrowserRecovery.launch(record, discover: { discoveries += 1; return discoveries == 1 ? [] : [endpoint] }, launcher: { _, _ in launches += 1 })
        t.expect(recovered.connected && recovered.launched, "only exact returning identity completes recovery")
        t.expectThrows("NaN timeout refused") { _ = try BrowserRecovery.launch(record, timeout: .nan) }
    } catch { t.expect(false, "recovery fixture failed: \(error)") }
}
