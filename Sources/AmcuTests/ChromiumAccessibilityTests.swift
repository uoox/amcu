import Foundation
import AmcuCore

/// Pure-logic coverage of the Chromium activation whitelist. `activate` itself
/// needs a live renderer process and mutates real application state, so it is
/// exercised manually, not here.
func runChromiumAccessibilityTests(_ t: Harness) {
    t.suite("chromium accessibility whitelist")

    // The ids the feature exists for: browsers and the big Electron hosts.
    for id in [
        "com.google.Chrome",
        "com.microsoft.VSCode",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "notion.id",
        "md.obsidian"
    ] {
        t.expect(ChromiumAccessibility.bundleIDs.contains(id), "\(id) is whitelisted")
        t.expect(ChromiumAccessibility.requiresActivation(bundleID: id), "\(id) requires activation")
    }

    // Selectors arrive user-typed; casing must not decide whether a tree loads.
    t.expect(ChromiumAccessibility.requiresActivation(bundleID: "COM.GOOGLE.CHROME"), "matching is case-insensitive")
    t.expect(ChromiumAccessibility.requiresActivation(bundleID: "com.microsoft.vscode"), "lowercased ids still match")

    // Native apps must never be activated — the flag degrades their trees.
    t.expect(!ChromiumAccessibility.requiresActivation(bundleID: "com.apple.Safari"), "Safari is not activated")
    t.expect(!ChromiumAccessibility.requiresActivation(bundleID: "com.apple.finder"), "Finder is not activated")
    t.expect(!ChromiumAccessibility.requiresActivation(bundleID: nil), "a missing bundle id is not activated")
    t.expect(!ChromiumAccessibility.requiresActivation(bundleID: ""), "an empty bundle id is not activated")

    // Substrings of whitelisted ids must not match — only exact ids do.
    t.expect(!ChromiumAccessibility.requiresActivation(bundleID: "com.google"), "a prefix of a whitelisted id does not match")
    t.expect(!ChromiumAccessibility.requiresActivation(bundleID: "com.google.Chrome.helper"), "an extension of a whitelisted id does not match")

    t.suite("chromium accessibility: bundle detection")
    // The list can never be complete; the bundle on disk says what engine it
    // ships. Fake bundles stand in for real ones so the check needs no apps.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("amcu-bundle-tests-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? FileManager.default.removeItem(at: root) }
    func fakeBundle(_ name: String, frameworks: [String]) -> URL {
        let bundle = root.appendingPathComponent(name, isDirectory: true)
        let dir = bundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for framework in frameworks {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(framework, isDirectory: true), withIntermediateDirectories: true)
        }
        return bundle
    }
    t.expect(ChromiumAccessibility.looksLikeChromiumHost(bundleURL: fakeBundle("Unknown Electron.app", frameworks: ["Electron Framework.framework", "Squirrel.framework"])), "an Electron app nobody listed is recognised from its bundle")
    t.expect(ChromiumAccessibility.looksLikeChromiumHost(bundleURL: fakeBundle("CEF Host.app", frameworks: ["Chromium Embedded Framework.framework"])), "a CEF host is recognised from its bundle")
    t.expect(!ChromiumAccessibility.looksLikeChromiumHost(bundleURL: fakeBundle("Native.app", frameworks: ["Sparkle.framework"])), "a native app with other frameworks is not touched")
    t.expect(!ChromiumAccessibility.looksLikeChromiumHost(bundleURL: fakeBundle("Bare.app", frameworks: [])), "an app without frameworks is not touched")
    t.expect(!ChromiumAccessibility.looksLikeChromiumHost(bundleURL: root.appendingPathComponent("Missing.app")), "a bundle that does not exist is not touched")
    t.expect(!ChromiumAccessibility.looksLikeChromiumHost(bundleURL: nil), "no bundle url, no activation")
}
