import Foundation
import AmcuCore

/// The pure parts of the browser bridge: wire framing, ref and socket-name
/// parsing, browser identification, the manifest, and the embedded extension
/// staying in step with the source folder.
func runBrowserBridgeTests(_ t: Harness) {
    t.suite("browser bridge framing")
    do {
        let one = Data("{\"a\":1}".utf8)
        let two = Data("{\"b\":\"two\"}".utf8)
        var stream = BrowserBridge.frame(one) + BrowserBridge.frame(two)
        // Split at an awkward point to prove partial reads are handled.
        var partial = stream.subdata(in: 0..<(4 + one.count + 2))
        var messages = BrowserBridge.unframe(&partial)
        t.expectEqual(messages.count, 1, "a complete message is returned and a partial one is kept")
        t.expectEqual(partial.count, 2, "the partial tail stays in the buffer")
        partial.append(stream.subdata(in: (4 + one.count + 2)..<stream.count))
        messages += BrowserBridge.unframe(&partial)
        t.expectEqual(messages.count, 2, "the second message completes once the rest arrives")
        t.expectEqual(String(data: messages[1], encoding: .utf8), "{\"b\":\"two\"}", "message bodies round-trip intact")
        t.expect(partial.isEmpty, "nothing is left over after two complete messages")

        stream = BrowserBridge.frame(Data())
        t.expectEqual(stream.count, 4, "an empty message is a bare length prefix")
        t.expectEqual(BrowserBridge.unframe(&stream).count, 1, "an empty message still counts as one")
    }

    t.suite("browser refs")
    do {
        t.expect(BrowserBridge.parseRef("e12").map { $0.frameID == 0 && $0.index == 12 } == true, "e12 is element 12 of the main frame")
        t.expect(BrowserBridge.parseRef("f42e7").map { $0.frameID == 42 && $0.index == 7 } == true, "f42e7 is element 7 of frame 42")
        t.expect(BrowserBridge.parseRef(" e3 ").map { $0.index == 3 } == true, "surrounding whitespace is tolerated")
        t.expect(BrowserBridge.parseRef("12") == nil, "a bare number is not a ref")
        t.expect(BrowserBridge.parseRef("e") == nil, "e without digits is not a ref")
        t.expect(BrowserBridge.parseRef("f4") == nil, "a frame without an element is not a ref")
        t.expect(BrowserBridge.parseRef("fe4") == nil, "f without digits is not a ref")
        t.expect(BrowserBridge.parseRef("e4x") == nil, "trailing junk is rejected")
    }

    t.suite("browser identity")
    do {
        t.expectEqual(BrowserBridge.browserName(bundleID: "com.google.Chrome"), "chrome", "Chrome's bundle id maps to chrome")
        t.expectEqual(BrowserBridge.browserName(bundleID: "com.google.Chrome.canary"), "chrome-canary", "Canary is told apart from stable")
        t.expectEqual(BrowserBridge.browserName(bundleID: "com.microsoft.edgemac"), "edge", "Edge maps to edge")
        t.expectEqual(BrowserBridge.browserName(bundleID: "com.brave.Browser"), "brave", "Brave maps to brave")
        t.expectEqual(BrowserBridge.browserName(bundleID: "org.chromium.Chromium"), "chromium", "Chromium maps to chromium")
        t.expectEqual(BrowserBridge.browserName(bundleID: "company.thebrowser.Browser"), "arc", "Arc maps to arc")
        t.expectEqual(BrowserBridge.browserName(bundleID: "com.apple.Safari"), nil, "Safari is not a Chromium browser")
        t.expectEqual(BrowserBridge.browserName(bundleID: nil), nil, "no bundle id, no name")
        t.expectEqual(BrowserBridge.browserName(brands: ["Chromium 151", "Google Chrome 151", "Not A Brand 99"]), "chrome", "the Chrome brand wins over the Chromium one")
        t.expectEqual(BrowserBridge.browserName(brands: ["Chromium 151", "Microsoft Edge 151"]), "edge", "Edge is recognised from its brand")
        t.expectEqual(BrowserBridge.browserName(brands: ["Chromium 151"]), "chromium", "a lone Chromium brand is Chromium")
        t.expectEqual(BrowserBridge.browserName(brands: []), nil, "no brands, no name")

        let name = BrowserBridge.socketURL(browser: "chrome", pid: 4242).lastPathComponent
        t.expectEqual(name, "chrome-4242.sock", "socket names carry browser and pid")
        t.expect(BrowserBridge.parseSocketName(name).map { $0.browser == "chrome" && $0.pid == 4242 } == true, "socket names parse back")
        t.expect(BrowserBridge.parseSocketName("chrome-beta-77.sock").map { $0.browser == "chrome-beta" && $0.pid == 77 } == true, "a hyphenated browser name survives the round trip")
        t.expect(BrowserBridge.parseSocketName("junk") == nil, "non-socket files are ignored")
        t.expect(BrowserBridge.parseSocketName("chrome-x.sock") == nil, "a socket without a numeric pid is ignored")
    }

    t.suite("browser errors")
    do {
        let known = BrowserBridge.error(fromCode: "stale_snapshot", message: "m", nextSteps: ["s"])
        t.expectEqual(known.code, .staleSnapshot, "a known code from the extension keeps its identity")
        t.expectEqual(known.nextSteps, ["s"], "next steps travel through")
        let unknown = BrowserBridge.error(fromCode: "made_up", message: "m", nextSteps: [])
        t.expectEqual(unknown.code, .pageError, "an unknown code becomes page_error rather than being dropped")
        t.expectEqual(unknown.message, "m", "the message survives even when the code is unknown")
    }

    t.suite("native messaging manifest")
    do {
        let data = BrowserInstall.manifestJSON(executable: "/Users/me/.local/bin/amcu")
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        t.expectEqual(object?["name"] as? String, BrowserBridge.hostName, "the manifest names the host")
        t.expectEqual(object?["type"] as? String, "stdio", "the host speaks stdio")
        t.expectEqual(object?["path"] as? String, "/Users/me/.local/bin/amcu", "the manifest points at the given binary")
        t.expectEqual(object?["allowed_origins"] as? [String], ["chrome-extension://\(ExtensionBundle.id)/"], "only the amcu extension may connect")
        t.expect(BrowserBridge.hostName.range(of: "^[a-z0-9._]+$", options: .regularExpression) != nil, "the host name is valid for the browser")
        t.expect(BrowserInstall.knownBrowsers.map(\.name).contains("chrome"), "Chrome is a known browser")
        t.expect(Set(BrowserInstall.knownBrowsers.map(\.name)).count == BrowserInstall.knownBrowsers.count, "browser names are unique")
    }

    t.suite("embedded extension")
    do {
        let names = ExtensionBundle.files.map(\.name)
        t.expect(names.contains("manifest.json") && names.contains("background.js") && names.contains("content.js"), "the bundle carries the three essential files")
        let manifestFile = ExtensionBundle.files.first { $0.name == "manifest.json" }
        let manifest = manifestFile.flatMap { try? JSONSerialization.jsonObject(with: $0.data) } as? [String: Any]
        t.expectEqual(manifest?["version"] as? String, ExtensionBundle.version, "the bundle's version is the manifest's version")
        t.expectEqual(ExtensionBundle.version, AmcuVersion.string, "the extension version tracks the binary version")
        t.expect((manifest?["key"] as? String)?.isEmpty == false, "the manifest pins the extension id with a key")
        t.expect(ExtensionBundle.id.count == 32 && ExtensionBundle.id.allSatisfy { ("a"..."p").contains($0) }, "the extension id is a 32-letter a–p string")
        let permissions = manifest?["permissions"] as? [String] ?? []
        t.expect(permissions.contains("nativeMessaging") && permissions.contains("debugger") && permissions.contains("scripting"), "the manifest requests what the bridge needs")
        t.expect((manifest?["host_permissions"] as? [String])?.contains("<all_urls>") == true, "the manifest may script any page")

        // The generated Swift must match the source folder; otherwise a change
        // to the extension would ship silently stale.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("extension", isDirectory: true)
        if FileManager.default.fileExists(atPath: source.path) {
            for file in ExtensionBundle.files {
                let onDisk = FileManager.default.contents(atPath: source.appendingPathComponent(file.name).path)
                t.expect(onDisk == file.data, "embedded \(file.name) matches extension/\(file.name) (run Scripts/embed-extension.py after editing)")
            }
            let onDiskNames = (try? FileManager.default.contentsOfDirectory(atPath: source.path))?.filter { !$0.hasPrefix(".") }.sorted() ?? []
            t.expectEqual(onDiskNames, names.sorted(), "every file in extension/ is embedded")
        }
    }

    t.suite("json helpers")
    do {
        // Go through JSONSerialization so numbers and booleans arrive the way the bridge sees them.
        let object = try! JSONSerialization.jsonObject(with: Data(#"{"a":1,"b":"two","c":[1,2.5],"d":{"e":true},"n":null,"z":0,"f":false}"#.utf8)) as! [String: Any]
        let value = JSONValue(object)
        t.expectEqual(value["z"].bool, nil, "a zero is not read as a boolean")
        t.expectEqual(value["f"].bool, false, "false is read as a boolean")
        t.expectEqual(value["z"].int, 0, "a zero is read as an integer")
        t.expectEqual(value["a"].int, 1, "ints are read")
        t.expectEqual(value["b"].string, "two", "strings are read")
        t.expectEqual(value["c"][1].double, 2.5, "arrays index")
        t.expectEqual(value["d"]["e"].bool, true, "nested dictionaries index")
        t.expect(value["n"].isNull && value["missing"].isNull, "null and missing read as null")
        let encoded = try? JSONEncoder().encode(value.encodable)
        let decoded = encoded.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        t.expectEqual(decoded?["a"] as? Int, 1, "AnyEncodable keeps integers integral")
        t.expectEqual(decoded?["b"] as? String, "two", "AnyEncodable keeps strings")
        t.expectEqual((decoded?["d"] as? [String: Any])?["e"] as? Bool, true, "AnyEncodable keeps booleans boolean")
        t.expect(decoded?["n"] is NSNull, "AnyEncodable keeps nulls")
        t.expect((try? JSONEncoder().encode(value["z"].encodable)).flatMap { String(data: $0, encoding: .utf8) } == "0", "AnyEncodable encodes 0 as a number, not false")
        t.expect((try? JSONEncoder().encode(value["f"].encodable)).flatMap { String(data: $0, encoding: .utf8) } == "false", "AnyEncodable encodes false as a boolean")
    }
}
