import Foundation
import AmcuCore

/// Several profiles of one browser: endpoint parsing from the host's hello,
/// choosing a connection (and refusing to guess), and finding a profile
/// directory from the instance id the extension leaves in its storage.
func runBrowserProfilesTests(_ t: Harness) {
    func endpoint(_ browser: String, _ pid: pid_t, id: String? = nil, label: String? = nil, dir: String? = nil, name: String? = nil) -> BrowserEndpoint {
        BrowserEndpoint(browser: browser, pid: pid, socket: "/tmp/\(browser)-\(pid).sock", instanceId: id, label: label, profileDir: dir, profileName: name)
    }
    func code(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch let error as AmcuError { return error.code.rawValue } catch { return "other" }
    }

    t.suite("browser hello parsing")
    do {
        let hello: [String: Any] = [
            "browser": "chrome", "hostVersion": "0.10.0", "extensionVersion": "0.10.0", "since": "2026-10-27T00:00:00Z",
            "instanceId": "abc123def0", "label": "shop", "userDataDir": "/u", "profileDir": "Profile 2", "profileName": "BunnyGleam"
        ]
        let parsed = BrowserEndpoint.fromHello(hello, browser: "fallback", pid: 77, socket: "/s")
        t.expectEqual(parsed.browser, "chrome", "the host's browser name wins over the socket's")
        t.expectEqual(parsed.instanceId, "abc123def0", "the instance id is carried")
        t.expectEqual(parsed.label, "shop", "the label is carried")
        t.expectEqual(parsed.profileDir, "Profile 2", "the profile directory is carried")
        t.expectEqual(parsed.profileName, "BunnyGleam", "the profile display name is carried")
        t.expectEqual(parsed.pid, 77, "the pid comes from the socket name")

        let old = BrowserEndpoint.fromHello(["browser": "chrome", "extensionVersion": "0.9.1", "instanceId": NSNull(), "label": ""], browser: "chrome", pid: 5, socket: "/s")
        t.expect(old.instanceId == nil && old.label == nil && old.profileDir == nil, "a pre-0.10 host or null/empty fields leave the identity empty, not invented")
        t.expectEqual(BrowserEndpoint.fromHello([:], browser: "edge", pid: 5, socket: "/s").browser, "edge", "the socket's browser name is the fallback")

        let json = (try? JSONEncoder().encode(old)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        t.expect(json?["profileDir"] is NSNull && json?["instanceId"] is NSNull, "unknown identity fields are encoded as null, not dropped")
        t.expect(parsed.summary.contains("Profile 2") && parsed.summary.contains("shop"), "the summary names profile and label")
    }

    t.suite("browser connection selection")
    do {
        let lone = [endpoint("chrome", 10, id: "aaaa1111")]
        t.expectEqual((try? BrowserSelection.choose(from: lone, browser: nil, profile: nil))?.pid, 10, "a lone connection needs no selector")
        t.expectEqual(code { try BrowserSelection.choose(from: [], browser: nil, profile: nil) }, "bridge_unavailable", "no connection is bridge_unavailable")

        let two = [
            endpoint("chrome", 10, id: "k3x9aaaa01", dir: "Default", name: ":D"),
            endpoint("chrome", 11, id: "m2b7bbbb02", label: "shop", dir: "Profile 2", name: "BunnyGleam"),
        ]
        t.expectEqual(code { try BrowserSelection.choose(from: two, browser: nil, profile: nil) }, "ambiguous_browser", "two profiles of one browser without a selector are refused, not the first one picked")
        t.expectEqual(code { try BrowserSelection.choose(from: two, browser: "chrome", profile: nil) }, "ambiguous_browser", "--browser chrome matching two connections is refused too")
        t.expectEqual((try? BrowserSelection.choose(from: two, browser: "chrome:11", profile: nil))?.pid, 11, "NAME:PID still selects one")
        t.expectEqual((try? BrowserSelection.choose(from: two, browser: nil, profile: "shop"))?.pid, 11, "--profile matches a label")
        t.expectEqual((try? BrowserSelection.choose(from: two, browser: nil, profile: "SHOP"))?.pid, 11, "label matching ignores case")
        t.expectEqual((try? BrowserSelection.choose(from: two, browser: nil, profile: "default"))?.pid, 10, "--profile matches a profile directory")
        t.expectEqual((try? BrowserSelection.choose(from: two, browser: nil, profile: "Profile 2"))?.pid, 11, "a profile directory with a space matches")
        t.expectEqual((try? BrowserSelection.choose(from: two, browser: nil, profile: "bunnygleam"))?.pid, 11, "--profile matches the display name")
        t.expectEqual((try? BrowserSelection.choose(from: two, browser: nil, profile: ":D"))?.pid, 10, "a punctuation display name matches")
        t.expectEqual((try? BrowserSelection.choose(from: two, browser: nil, profile: "k3x"))?.pid, 10, "--profile matches an instance id prefix")
        t.expectEqual((try? BrowserSelection.choose(from: two, browser: "chrome", profile: "shop"))?.pid, 11, "--browser and --profile combine")
        t.expectEqual(code { try BrowserSelection.choose(from: two, browser: nil, profile: "Profile 3") }, "bridge_unavailable", "a profile that is not connected is not found")
        t.expectEqual(code { try BrowserSelection.choose(from: two, browser: "edge", profile: nil) }, "bridge_unavailable", "a browser that is not connected is not found")
        t.expectEqual(code { try BrowserSelection.choose(from: two, browser: "chrome:10", profile: "shop") }, "bridge_unavailable", "--profile is applied within --browser, not instead of it")

        let prefixClash = [endpoint("chrome", 10, id: "abc111"), endpoint("chrome", 11, id: "abc222")]
        t.expectEqual(code { try BrowserSelection.choose(from: prefixClash, browser: nil, profile: "abc") }, "ambiguous_browser", "an instance id prefix shared by two is ambiguous")
        let shadow = [endpoint("chrome", 10, id: "work0001"), endpoint("chrome", 11, id: "zzzz0002", label: "work")]
        t.expectEqual((try? BrowserSelection.choose(from: shadow, browser: nil, profile: "work"))?.pid, 11, "an exact label wins over another connection's id prefix")

        let tiers = [endpoint("chrome", 10, id: "p1", label: "work"), endpoint("chrome", 11, id: "p2", dir: "Profile 3", name: "Work")]
        t.expectEqual((try? BrowserSelection.choose(from: tiers, browser: nil, profile: "work"))?.pid, 10, "a label outranks another profile's display name")
        t.expectEqual((try? BrowserSelection.choose(from: tiers, browser: nil, profile: "Profile 3"))?.pid, 11, "lower tiers still match when no label does")
        let sameName = [endpoint("chrome", 10, id: "q1", dir: "Default", name: "Person"), endpoint("chrome", 11, id: "q2", dir: "Profile 2", name: "Person")]
        t.expectEqual(code { try BrowserSelection.choose(from: sameName, browser: nil, profile: "person") }, "ambiguous_browser", "two profiles with the same display name are refused")
        let oldPool = [endpoint("chrome", 10), endpoint("chrome", 11, id: "r1", dir: "Default")]
        do {
            _ = try BrowserSelection.choose(from: oldPool, browser: nil, profile: "shop")
        } catch let error as AmcuError {
            t.expect(error.nextSteps.contains { $0.contains("without identity") && $0.contains("--browser chrome:10") }, "a miss names connections whose extension predates identity")
        } catch {}

        let mixed = [endpoint("chrome", 10, id: "a1"), endpoint("edge", 20, id: "b2")]
        t.expectEqual((try? BrowserSelection.choose(from: mixed, browser: nil, profile: nil))?.browser, "chrome", "one Chrome among other browsers is still preferred")
        var idle = endpoint("safari", 40); idle.ready = false
        t.expectEqual((try? BrowserSelection.choose(from: [endpoint("edge", 20), idle], browser: nil, profile: nil))?.browser, "edge", "a Safari relay that is not polling does not compete with a live browser")
        t.expectEqual(code { try BrowserSelection.choose(from: [endpoint("chrome", 10, id: "a1"), endpoint("chrome", 11, id: "b2"), idle], browser: nil, profile: nil) }, "ambiguous_browser", "skipping an idle relay does not make two live profiles less ambiguous")
        t.expectEqual((try? BrowserSelection.choose(from: [endpoint("chrome", 10, id: "a1"), idle], browser: "safari", profile: nil))?.browser, "safari", "an idle relay is still used when named")
        let noChrome = [endpoint("edge", 20), endpoint("brave", 30)]
        t.expectEqual(code { try BrowserSelection.choose(from: noChrome, browser: nil, profile: nil) }, "ambiguous_browser", "several non-Chrome browsers without a selector are refused")

        do {
            _ = try BrowserSelection.choose(from: two, browser: nil, profile: nil)
        } catch let error as AmcuError {
            let steps = error.nextSteps.joined(separator: "\n")
            t.expect(steps.contains("--profile shop") && steps.contains("--profile Default"), "the refusal lists each candidate with the flag that selects it")
        } catch {}

        t.expectEqual(BrowserSelection.selectingFlag(for: two[1], among: two), "--profile shop", "a label is the preferred selector")
        t.expectEqual(BrowserSelection.selectingFlag(for: two[0], among: two), "--profile Default", "without a label the profile directory is used")
        let bare = [endpoint("chrome", 10), endpoint("chrome", 11)]
        t.expectEqual(BrowserSelection.selectingFlag(for: bare[1], among: bare), "--browser chrome:11", "an old extension without identity falls back to NAME:PID")
        let quoted = [endpoint("chrome", 10, id: "x1", dir: "Profile 3"), endpoint("chrome", 11, id: "y2", dir: "Default")]
        t.expectEqual(BrowserSelection.selectingFlag(for: quoted[0], among: quoted), "--profile 'Profile 3'", "a selector with a space is shell-quoted")
    }

    t.suite("browser profile location")
    do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("amcu-profiles-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionID = ExtensionBundle.id
        func store(_ profile: String, _ file: String, _ contents: String) {
            let directory = root.appendingPathComponent(profile).appendingPathComponent("Local Extension Settings").appendingPathComponent(extensionID)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: directory.appendingPathComponent(file).path, contents: Data(contents.utf8))
        }
        store("Default", "000003.log", "\u{1}\u{2}amcu_identity{}\u{0}amcu_instance_aaaa1111\u{0}123")
        store("Profile 2", "000005.log", "junk amcu_instance_bbbb2222 junk")
        store("Profile 2", "000004.ldb", "older table amcu_instance_zzzz9999")
        store("Profile 3", "LOCK", "amcu_instance_cccc3333")
        store("Profile 4", "000001.log", "amcu_instance_dddd4444")
        store("Profile 5", "000001.log", "amcu_instance_dddd4444")
        let localState = #"{"profile":{"info_cache":{"Default":{"name":":D"},"Profile 2":{"name":"BunnyGleam"},"Profile 3":{"name":""}}}}"#
        FileManager.default.createFile(atPath: root.appendingPathComponent("Local State").path, contents: Data(localState.utf8))

        t.expectEqual(ProfileLocator.profileDirectory(instanceID: "aaaa1111", extensionID: extensionID, userDataDir: root), "Default", "the profile whose extension log holds the id is found")
        t.expectEqual(ProfileLocator.profileDirectory(instanceID: "bbbb2222", extensionID: extensionID, userDataDir: root), "Profile 2", "profile directories with spaces are found")
        t.expectEqual(ProfileLocator.profileDirectory(instanceID: "zzzz9999", extensionID: extensionID, userDataDir: root), "Profile 2", "a table file is searched too")
        t.expectEqual(ProfileLocator.profileDirectory(instanceID: "cccc3333", extensionID: extensionID, userDataDir: root), nil, "files other than .log/.ldb are not evidence")
        t.expectEqual(ProfileLocator.profileDirectory(instanceID: "dddd4444", extensionID: extensionID, userDataDir: root), nil, "an id found in two profiles (a copied profile) is not guessed")
        t.expectEqual(ProfileLocator.profileDirectory(instanceID: "eeee5555", extensionID: extensionID, userDataDir: root), nil, "an id found nowhere gives no profile")
        t.expectEqual(ProfileLocator.profileDirectory(instanceID: "aaaa1111", extensionID: "otherextensionid", userDataDir: root), nil, "only this extension's store is searched")
        t.expectEqual(ProfileLocator.profileName(userDataDir: root, profileDir: "Profile 2"), "BunnyGleam", "the display name comes from Local State")
        t.expectEqual(ProfileLocator.profileName(userDataDir: root, profileDir: "Default"), ":D", "Default has its own display name")
        t.expectEqual(ProfileLocator.profileName(userDataDir: root, profileDir: "Profile 3"), nil, "an empty display name is no name")
        t.expectEqual(ProfileLocator.profileName(userDataDir: root, profileDir: "Profile 9"), nil, "an unknown profile has no name")
        t.expectEqual(ProfileLocator.profileName(localState: Data("not json".utf8), profileDir: "Default"), nil, "a corrupt Local State gives no name")
    }

    t.suite("browser user data directory")
    do {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        t.expectEqual(ProfileLocator.userDataDirectory(arguments: ["/x/Chrome", "--user-data-dir=/tmp/lab/p"], browser: "chrome")?.path, "/tmp/lab/p", "--user-data-dir wins over the default")
        t.expectEqual(ProfileLocator.userDataDirectory(arguments: ["--user-data-dir=/a", "--user-data-dir=/b"], browser: "chrome")?.path, "/b", "a repeated --user-data-dir resolves to the last one, as in Chromium")
        t.expectEqual(ProfileLocator.userDataDirectory(arguments: ["/x/Chrome"], browser: "chrome")?.path, "\(home)/Library/Application Support/Google/Chrome", "Chrome's default user data dir")
        t.expectEqual(ProfileLocator.userDataDirectory(arguments: [], browser: "chrome-for-testing")?.path, "\(home)/Library/Application Support/Google/Chrome for Testing", "Chrome for Testing has its own default")
        t.expectEqual(ProfileLocator.userDataDirectory(arguments: ["--user-data-dir=relative"], browser: "chrome")?.path, nil, "a relative --user-data-dir is not resolved by guesswork")
        t.expectEqual(ProfileLocator.userDataDirectory(arguments: [], browser: "unknown-browser")?.path, nil, "an unknown browser has no default")

        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += Array("/Applications/Chrome.app/Contents/MacOS/Chrome".utf8) + [0, 0, 0, 0]
        for argument in ["/Applications/Chrome.app/Contents/MacOS/Chrome", "--user-data-dir=/tmp/x y", "--flag"] { bytes += Array(argument.utf8) + [0] }
        bytes += Array("HOME=/Users/me".utf8) + [0]
        t.expectEqual(ProfileLocator.parseProcArgs(bytes) ?? [], ["/Applications/Chrome.app/Contents/MacOS/Chrome", "--user-data-dir=/tmp/x y", "--flag"], "KERN_PROCARGS2 parses into argv without the environment")
        t.expect(ProfileLocator.parseProcArgs([1, 0]) == nil, "a truncated buffer is rejected")
        t.expect(ProfileLocator.parseProcArgs([2, 0, 0, 0] + Array("/x".utf8) + [0] + Array("a".utf8) + [0]) == nil, "fewer arguments than argc is rejected")
        let own = ProfileLocator.processArguments(pid: getpid())
        t.expect(own?.first?.hasSuffix("amcu-tests") == true, "this process's own argv can be read")
    }

    t.suite("extension identity contract")
    do {
        let background = ExtensionBundle.files.first { $0.name == "background.js" }.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
        t.expect(background.contains("'\(ProfileLocator.markerPrefix)'"), "the extension writes the same key prefix the host searches for")
        t.expect(background.contains("async setLabel(") && background.contains("async identity("), "the extension answers setLabel and identity")
        t.expect(background.contains("instanceId: info.instanceId"), "the extension's hello carries its instance id")
    }
}
