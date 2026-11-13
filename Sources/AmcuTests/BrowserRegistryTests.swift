import Foundation
import AmcuCore

func runBrowserRegistryTests(_ t: Harness) {
    t.suite("browser registry private history")
    do {
        let root = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().appendingPathComponent(".amcu-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data")
        func marker(_ profile: String) throws {
            let store = data.appendingPathComponent(profile).appendingPathComponent("Local Extension Settings/\(BrowserBridge.extensionID)")
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try Data("amcu_instance_abcdef".utf8).write(to: store.appendingPathComponent("000001.log"))
        }
        try marker("Default")
        let identity = try BrowserProfileIdentity(browser: "chrome", instanceId: "abcdef", userDataDir: data.path, profileDir: "Default")
        try identity.validateOnDisk()
        let registry = BrowserRegistry(directory: root.appendingPathComponent("registry"))
        let record = BrowserRegistryRecord(identity: identity, label: "shop", applicationBundleID: "test.chrome", applicationPath: "/Applications/Test.app")
        try registry.merge([record, record])
        t.expectEqual(try registry.list().count, 1, "duplicate records replace identity")
        t.expectEqual(try registry.select(profile: "shop").identity, identity, "label selects but is not identity")
        t.expectEqual(try JSONDecoder().decode(BrowserRegistryRecord.self, from: JSONEncoder().encode(record)), record, "registry serializes full identity and app")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("registry/registry.json").path)
        t.expectEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "history file is private")
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("registry").path)
        t.expectEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700, "history directory is private")
        t.expectThrows("reject path escape") { _ = try BrowserProfileIdentity(browser: "chrome", instanceId: "abcdef", userDataDir: data.path, profileDir: "../Default") }
        let missing = try BrowserProfileIdentity(browser: "chrome", instanceId: "abcdef", userDataDir: data.path, profileDir: "Missing")
        t.expectThrows("reject absent profile directory") { try missing.validateOnDisk() }
        try marker("Profile 2")
        t.expectThrows("reject cloned marker") { try identity.validateOnDisk() }
        let clone = try BrowserProfileIdentity(browser: "chrome", instanceId: "abcdef", userDataDir: data.path, profileDir: "Profile 2")
        try registry.merge([BrowserRegistryRecord(identity: clone, label: "other")])
        t.expectThrows("label cannot bypass duplicated identity") { _ = try registry.select(profile: "shop") }
        let other = try BrowserProfileIdentity(browser: "chrome", instanceId: "different", userDataDir: data.path, profileDir: "Profile 2")
        let ambiguous = BrowserRegistry(directory: root.appendingPathComponent("ambiguous"))
        try ambiguous.merge([record, BrowserRegistryRecord(identity: other, label: "shop")])
        t.expectThrows("ambiguous label refused") { _ = try ambiguous.select(profile: "shop") }
        try FileManager.default.removeItem(at: data.appendingPathComponent("Profile 2"))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: data.appendingPathComponent("Profile 2"), withDestinationURL: outside)
        t.expectThrows("symlink profile refused") { try clone.validateOnDisk() }
        let symlink = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        t.expectThrows("store refuses symlink directory") { _ = try BrowserRegistry(directory: symlink).list() }
        let privateRoot = root.appendingPathComponent("secure")
        let secure = BrowserRegistry(directory: privateRoot)
        _ = try secure.list()
        let lockFile = privateRoot.appendingPathComponent("store.lock")
        let target = outside.appendingPathComponent("target")
        try Data("private".utf8).write(to: target)
        let history = privateRoot.appendingPathComponent("registry.json")
        try FileManager.default.createSymbolicLink(at: history, withDestinationURL: target)
        t.expectThrows("store refuses symlink data file") { _ = try secure.list() }
        try FileManager.default.removeItem(at: history)
        try FileManager.default.linkItem(at: target, to: history)
        t.expectThrows("store refuses hardlinked data file") { _ = try secure.list() }
        try FileManager.default.removeItem(at: history)
        try FileManager.default.removeItem(at: lockFile)
        try FileManager.default.createSymbolicLink(at: lockFile, withDestinationURL: target)
        t.expectThrows("store refuses symlink lock") { _ = try secure.list() }
        let serialized = try JSONEncoder().encode(identity)
        var fields = try JSONSerialization.jsonObject(with: serialized) as! [String: Any]
        fields["profileDir"] = "../escape"
        t.expectThrows("identity decode cannot bypass path validation") {
            _ = try JSONDecoder().decode(BrowserProfileIdentity.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        fields["profileDir"] = "Default"
        fields["userDataDir"] = data.path + "/../data"
        t.expectThrows("identity decode refuses noncanonical root") {
            _ = try JSONDecoder().decode(BrowserProfileIdentity.self, from: JSONSerialization.data(withJSONObject: fields))
        }
    } catch { t.expect(false, "registry fixture failed: \(error)") }
}
