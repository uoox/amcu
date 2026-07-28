import ApplicationServices
import Foundation

/// Chromium (and by extension every Electron app) treats its accessibility
/// tree as expensive to maintain and only builds it once something asks for
/// it. Unlike VoiceOver, a plain AXUIElement client is not one of the signals
/// it listens for, so umbra would otherwise see an empty tree or a lone app
/// root. Setting `AXManualAccessibility` (Chromium's documented opt-in) and
/// `AXEnhancedUserInterface` (the older assistive-client hint it also honors)
/// on the application element flips that switch.
///
/// This is a whitelist on purpose. `AXEnhancedUserInterface` set on a native
/// Cocoa application changes AppKit's behavior — some apps collapse their tree
/// to the app root, and window-move animations start interfering with frame
/// reads — so blanket activation would break exactly the apps that already
/// worked. Only bundle ids known to be Chromium/Electron hosts are touched.
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
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
}
