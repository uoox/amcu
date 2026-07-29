import ApplicationServices
import Foundation

/// Chromium (and by extension every Electron app) treats its accessibility
/// tree as expensive to maintain and only builds it once something asks for
/// it. Unlike VoiceOver, a plain AXUIElement client is not one of the signals
/// it listens for, so amcu would otherwise see an empty tree or a lone app
/// root. Setting `AXManualAccessibility` (Chromium's documented opt-in) on the
/// application element flips that switch.
///
/// `AXEnhancedUserInterface` — the older assistive-client hint Chromium also
/// honors — is deliberately not set. AppKit reacts to that flag too: with it
/// raised, writes to `AXPosition` are ignored or animated (the long-documented
/// conflict that Rectangle and yabai work around), which would break
/// `WindowControl.setPosition` — and since activation here is one-way and
/// never reset, the breakage would outlive the snapshot that caused it.
/// `AXManualAccessibility` alone is Chromium's documented switch and is
/// sufficient to build the tree.
///
/// This is a whitelist on purpose: `AXManualAccessibility` is a Chromium-ism,
/// meaningless to native applications, so only bundle ids known to be
/// Chromium/Electron hosts are touched.
public enum ChromiumAccessibility {
    /// Known Chromium/Electron hosts that need the explicit opt-in.
    public static let bundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "notion.id",
        "com.spotify.client",
        "com.microsoft.teams2",
        "md.obsidian"
    ]

    /// Case-insensitive, because bundle ids arrive from user selectors as well
    /// as from NSRunningApplication and the two do not always agree on casing.
    private static let lowercasedBundleIDs = Set(bundleIDs.map { $0.lowercased() })

    public static func requiresActivation(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return lowercasedBundleIDs.contains(bundleID.lowercased())
    }

    /// Idempotent and deliberately silent: this runs on every app resolution,
    /// and a failure here (attribute unsupported, renderer busy, app quitting)
    /// just means the caller sees the same tree it would have seen anyway. The
    /// set is a no-op when the flag is already true, so there is no state to
    /// track between calls.
    public static func activate(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        // A short timeout keeps a hung renderer from stalling every command
        // that merely resolves the app; the flags stick once the app recovers.
        AX.setMessagingTimeout(app, seconds: 1.0)
        // Only Chromium's own switch — see the type comment for why
        // AXEnhancedUserInterface must stay untouched.
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
