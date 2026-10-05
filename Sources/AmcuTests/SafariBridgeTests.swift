import Foundation
import AmcuCore

/// The Safari bridge without Safari: relay bookkeeping, the appex wire
/// config, verb refusals, the bundle the installer assembles, signer choice,
/// and every branch of doctor's diagnosis.
func runSafariBridgeTests(_ t: Harness) {
    t.suite("safari relay config")
    do {
        let token = String(repeating: "ab", count: 24)
        t.expectEqual(SafariBridge.relayConfig(from: ["AmcuRelayPort": 51234, "AmcuRelayToken": token]), .init(port: 51234, token: token), "port and token are read from the appex Info.plist")
        t.expectEqual(SafariBridge.relayConfig(from: ["AmcuRelayPort": "51234", "AmcuRelayToken": token])?.port, 51234, "a string port is accepted")
        t.expect(SafariBridge.relayConfig(from: ["AmcuRelayPort": 0, "AmcuRelayToken": token]) == nil, "port 0 is refused")
        t.expect(SafariBridge.relayConfig(from: ["AmcuRelayPort": 70000, "AmcuRelayToken": token]) == nil, "an out-of-range port is refused")
        t.expect(SafariBridge.relayConfig(from: ["AmcuRelayPort": 51234, "AmcuRelayToken": "short"]) == nil, "a short token is refused")
        t.expect(SafariBridge.relayConfig(from: [:]) == nil, "a plist without the keys yields no config")
        let random = SafariBridge.randomToken()
        t.expect(random.count == 48 && random != SafariBridge.randomToken(), "random tokens are 48 hex characters and differ")
        t.expect(SafariBridge.tokenMatches(token, token), "the right token matches")
        t.expect(!SafariBridge.tokenMatches(token + "x", token), "a longer token does not match")
        t.expect(!SafariBridge.tokenMatches(nil, token), "a missing token does not match")
        t.expect(!SafariBridge.tokenMatches(String(token.dropLast()) + "c", token), "a token differing in one character does not match")
    }

    t.suite("safari verb routing")
    do {
        t.expect(SafariBridge.isSafariSelector("safari") && SafariBridge.isSafariSelector("Safari:123"), "safari and safari:PID select Safari")
        t.expect(!SafariBridge.isSafariSelector("chrome") && !SafariBridge.isSafariSelector(nil), "other browsers and no selector do not")
        for method in ["console", "network", "dialog", "drag"] {
            let error = SafariBridge.unsupportedError(method: method)
            t.expect(error?.code == .unsupported && error?.nextSteps.isEmpty == false, "\(method) is refused as unsupported, with next steps")
        }
        for method in ["click", "snapshot", "evaluate", "screenshot", "tabs.list"] {
            t.expect(SafariBridge.unsupportedError(method: method) == nil, "\(method) is passed through to the extension")
        }
        let background = SafariExtensionBundle.files.first { $0.name == "background.js" }.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
        for method in ["console", "network", "dialog", "drag", "resize"] {
            t.expect(background.contains("async \(method)("), "the Safari extension also answers \(method) (refusing it) rather than reporting an unknown method")
        }
        t.expect(background.contains("isTrusted=false"), "the Safari extension labels its clicks as synthetic")
    }

    t.suite("safari relay core")
    do {
        let core = SafariRelayCore()
        t.expect(!core.isReady, "a fresh relay has heard from no extension")
        let started = Date()
        let failed = core.submit(method: "tabs.list", params: [:], timeout: 5, notPollingAfter: 0.3)
        let error = failed["error"] as? [String: Any]
        t.expectEqual(error?["code"] as? String, "bridge_unavailable", "a request with no extension polling fails as bridge_unavailable")
        t.expect(Date().timeIntervalSince(started) < 2, "and fails fast instead of waiting out the timeout")
        t.expect((error?["nextSteps"] as? [String])?.contains { $0.contains("doctor --browser safari") } == true, "the failure points at doctor")

        t.expect(core.notePoll(["type": "poll", "version": "9.9.9", "hostAccess": true, "profile": "A"]), "the first profile's poll is accepted")
        t.expect(core.isReady, "a recent poll makes the relay ready")
        t.expectEqual(core.extensionInfo.version, "9.9.9", "the poll's extension version is recorded")
        t.expectEqual(core.extensionInfo.hostAccess, true, "the poll's website access is recorded")
        t.expect(!core.notePoll(["type": "poll", "profile": "B"]), "a second Safari profile is told to idle while the first is active")

        let poller = DispatchQueue(label: "poller")
        poller.async {
            guard let request = core.poll(window: 3) else { return }
            core.respond(id: request.id, payload: ["ok": true, "result": ["echo": request.method, "n": request.params["n"] ?? 0]])
        }
        let reply = core.submit(method: "snapshot", params: ["n": 7], timeout: 5)
        t.expectEqual(reply["ok"] as? Bool, true, "a polled request is answered")
        let result = reply["result"] as? [String: Any]
        t.expectEqual(result?["echo"] as? String, "snapshot", "the answer belongs to the request that was sent")
        t.expectEqual(result?["n"] as? Int, 7, "params travel to the extension intact")

        t.expect(core.poll(window: 0.2) == nil, "a poll with nothing queued comes back idle")
        t.expect(!core.respond(id: 9999, payload: ["ok": true]), "a response for an unknown request is not delivered")

        // A request handed to a connection that broke is put back for the next poll.
        let secondPoller = DispatchQueue(label: "poller2")
        secondPoller.async {
            guard let first = core.poll(window: 3) else { return }
            core.requeue(first)
            guard let again = core.poll(window: 3) else { return }
            core.respond(id: again.id, payload: ["ok": true, "result": ["second": true]])
        }
        let requeued = core.submit(method: "find", params: [:], timeout: 5)
        t.expectEqual((requeued["result"] as? [String: Any])?["second"] as? Bool, true, "a requeued request is delivered on the next poll")

        let late = SafariRelayCore()
        _ = late.notePoll(["type": "poll"])
        let timedOut = late.submit(method: "click", params: [:], timeout: 1)
        t.expectEqual((timedOut["error"] as? [String: Any])?["code"] as? String, "bridge_unavailable", "a request no poll picks up within the timeout says so")
    }

    t.suite("safari bundle")
    do {
        let config = SafariBridge.RelayConfig(port: 50001, token: String(repeating: "c", count: 48))
        let appex = SafariInstall.appexInfo(version: "1.2.3", config: config)
        let ext = appex["NSExtension"] as? [String: Any]
        t.expectEqual(ext?["NSExtensionPointIdentifier"] as? String, "com.apple.Safari.web-extension", "the appex declares the Safari web extension point")
        t.expectEqual(ext?["NSExtensionPrincipalClass"] as? String, SafariBridge.handlerClassName, "the principal class is the handler compiled into amcu")
        t.expect(NSClassFromString(SafariBridge.handlerClassName) != nil, "the principal class is registered with the Objective-C runtime under that name")
        t.expectEqual(appex["CFBundlePackageType"] as? String, "XPC!", "the appex is packaged as an XPC service")
        t.expectEqual(SafariBridge.relayConfig(from: appex), config, "the relay config round-trips through the appex Info.plist")
        t.expect((appex["CFBundleIdentifier"] as? String)?.hasPrefix(SafariBridge.appBundleID + ".") == true, "the appex id is prefixed by the app id, as the system requires")
        let app = SafariInstall.appInfo(version: "1.2.3")
        t.expectEqual(app["LSUIElement"] as? Bool, true, "the container app never shows a Dock icon")
        t.expectEqual(SafariInstall.appexEntitlements["com.apple.security.app-sandbox"] as? Bool, true, "the appex is sandboxed (Safari requires it)")
        t.expectEqual(SafariInstall.appexEntitlements["com.apple.security.network.client"] as? Bool, true, "the appex may open the loopback connection to the relay")

        let custom = URL(fileURLWithPath: "/tmp/x/amcu Safari Bridge.app")
        t.expectEqual(SafariInstall.appExecutableURL(custom).path, "/tmp/x/amcu Safari Bridge.app/Contents/MacOS/amcu", "the relay runs the app's own executable")
        t.expectEqual(SafariInstall.appexInfoURL(custom).path, "/tmp/x/amcu Safari Bridge.app/Contents/PlugIns/amcu Safari Extension.appex/Contents/Info.plist", "the appex lives in PlugIns")
        t.expect(SafariInstall.defaultAppURL.path.hasSuffix("/Applications/amcu Safari Bridge.app"), "the default install location is ~/Applications")

        let names = SafariInstall.extensionFiles.map(\.name)
        for required in ["manifest.json", "background.js", "content.js", "popup.html", "popup.js", "icon16.png", "icon48.png", "icon128.png"] {
            t.expect(names.contains(required), "the appex resources include \(required)")
        }
        t.expectEqual(Set(names).count, names.count, "no resource is written twice")
        let shared = SafariInstall.extensionFiles.first { $0.name == "content.js" }?.data
        t.expect(shared == ExtensionBundle.files.first { $0.name == "content.js" }?.data, "Safari runs the very content script Chrome runs")
        let manifestData = SafariInstall.extensionFiles.first { $0.name == "manifest.json" }?.data ?? Data()
        let manifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any]
        t.expectEqual(manifest?["version"] as? String, AmcuVersion.string, "the Safari extension version tracks the binary version")
        let permissions = manifest?["permissions"] as? [String] ?? []
        t.expect(permissions.contains("nativeMessaging") && !permissions.contains("debugger"), "the Safari manifest asks for native messaging and not for the debugger it cannot have")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("safari/extension", isDirectory: true)
        if FileManager.default.fileExists(atPath: source.path) {
            for file in SafariExtensionBundle.files {
                let onDisk = FileManager.default.contents(atPath: source.appendingPathComponent(file.name).path)
                t.expect(onDisk == file.data, "embedded \(file.name) matches safari/extension/\(file.name) (run Scripts/embed-extension.py after editing)")
            }
            let onDiskNames = (try? FileManager.default.contentsOfDirectory(atPath: source.path))?.filter { !$0.hasPrefix(".") }.sorted() ?? []
            t.expectEqual(onDiskNames, SafariExtensionBundle.files.map(\.name).sorted(), "every file in safari/extension/ is embedded")
        }
    }

    t.suite("safari signing choice")
    do {
        let listing = """
          1) AAAA "Apple Development: A (X)"
          2) BBBB "Developer ID Application: Someone (TEAM123)"
          3) CCCC "AAA Local Signing"
             3 valid identities found
        """
        t.expectEqual(SafariInstall.chooseSigner(identityListing: listing, requested: nil), .identity("Developer ID Application: Someone (TEAM123)"), "a Developer ID identity is preferred")
        t.expect(SafariInstall.chooseSigner(identityListing: listing, requested: nil).isDeveloperID, "and recognised as Developer ID")
        t.expectEqual(SafariInstall.chooseSigner(identityListing: listing, requested: "AAA Local Signing"), .identity("AAA Local Signing"), "an explicit AMCU_SIGN_IDENTITY that exists wins")
        t.expectEqual(SafariInstall.chooseSigner(identityListing: "     0 valid identities found", requested: "Missing"), .adHoc, "a requested identity that is absent falls back to ad-hoc")
        t.expectEqual(SafariInstall.chooseSigner(identityListing: "", requested: nil), .adHoc, "no identities means ad-hoc")
        t.expectEqual(SafariInstall.Signer.adHoc.codesignArgument, "-", "ad-hoc signs with '-'")
        t.expect(SafariInstall.ownerSteps(developerID: false).first?.contains("Allow unsigned extensions") == true, "a locally signed build needs Allow unsigned extensions first")
        t.expect(SafariInstall.ownerSteps(developerID: true).allSatisfy { !$0.contains("Allow unsigned") }, "a Developer ID build skips that step")
    }

    t.suite("safari doctor")
    do {
        func status(_ edit: (inout SafariInstall.Status) -> Void) -> SafariInstall.Status {
            var s = SafariInstall.Status(appPath: "/A.app", appInstalled: true, appVersion: AmcuVersion.string, binaryVersion: AmcuVersion.string, signatureValid: true, signer: "ad-hoc", registered: true, safariInstalled: true, safariRunning: true, safariEnabled: nil, safariWebsiteAccess: nil, relayRunning: true, relayPid: 42, relayError: nil, extensionPolling: true, extensionVersion: AmcuVersion.string, lastPollAgoSeconds: 1, hostAccess: true)
            edit(&s)
            return s
        }
        func failing(_ checks: [SafariInstall.Check]) -> [String] { checks.filter { !$0.ok }.map(\.name) }

        let healthy = SafariInstall.diagnose(status { _ in })
        t.expect(healthy.allSatisfy(\.ok), "a complete setup passes every check")
        t.expect(healthy.contains { $0.name == "website access" && $0.ok }, "website access is reported when the extension says it has it")

        t.expectEqual(failing(SafariInstall.diagnose(status { $0.safariInstalled = false })), ["safari"], "no Safari is the only finding when Safari is missing")
        let missing = SafariInstall.diagnose(status { $0.appInstalled = false })
        t.expectEqual(failing(missing), ["app"], "a missing app stops the diagnosis at the app")
        t.expect(missing.first?.next.first?.contains("install --browser safari") == true, "and says how to install it")
        t.expectEqual(failing(SafariInstall.diagnose(status { $0.appVersion = "0.0.1" })), ["app"], "an outdated app is flagged")
        t.expectEqual(failing(SafariInstall.diagnose(status { $0.signatureValid = false })), ["signature"], "a broken signature is flagged")
        t.expectEqual(failing(SafariInstall.diagnose(status { $0.registered = false })), ["registration"], "a missing pluginkit registration is flagged")
        t.expectEqual(failing(SafariInstall.diagnose(status { $0.relayError = "boom"; $0.relayRunning = false })), ["relay"], "a relay that cannot start is flagged")
        let closed = SafariInstall.diagnose(status { $0.safariRunning = false })
        t.expect(failing(closed) == ["extension"] && closed.last?.detail.contains("not running") == true, "Safari not running is explained")
        let silent = SafariInstall.diagnose(status { $0.extensionPolling = false; $0.lastPollAgoSeconds = nil })
        t.expectEqual(failing(silent), ["extension"], "an extension that never polled is flagged")
        let steps = silent.last?.next ?? []
        t.expect(steps.contains { $0.contains("Allow unsigned extensions") } && steps.contains { $0.contains("Extensions") } && steps.contains { $0.contains("Edit Websites") }, "and the owner's three one-time steps are listed")
        let developerID = SafariInstall.diagnose(status { $0.extensionPolling = false; $0.signer = "Developer ID Application: X (T)" })
        t.expect(developerID.last?.next.allSatisfy { !$0.contains("Allow unsigned") } == true, "a Developer ID build is not told to allow unsigned extensions")
        let off = SafariInstall.diagnose(status { $0.extensionPolling = false; $0.safariEnabled = false })
        t.expect(off.last?.detail.contains("turned off") == true, "Safari's own 'off' record is mentioned when readable")
        let stale = SafariInstall.diagnose(status { $0.extensionVersion = "0.0.1" })
        t.expect(failing(stale) == ["extension"] && stale.first { $0.name == "extension" }?.next.first?.contains("off and on") == true, "an old extension still running is flagged with how to refresh it")
        t.expectEqual(failing(SafariInstall.diagnose(status { $0.hostAccess = false })), ["website access"], "missing website access is flagged")
    }

    t.suite("safari upload payload")
    do {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("amcu-upload-test.txt")
        try? Data("hello".utf8).write(to: file)
        let payload = try? SafariBridge.uploadPayload(paths: [file.path])
        t.expectEqual(payload?.first?["name"] as? String, "amcu-upload-test.txt", "the file name travels with the bytes")
        t.expectEqual(payload?.first?["data"] as? String, Data("hello".utf8).base64EncodedString(), "the bytes are base64")
        t.expectEqual(payload?.first?["type"] as? String, "text/plain", "the MIME type comes from the extension")
        try? FileManager.default.removeItem(at: file)
        t.expectThrows("a missing file is an error, not an empty upload") { _ = try SafariBridge.uploadPayload(paths: ["/nonexistent/amcu"]) }
    }
}
