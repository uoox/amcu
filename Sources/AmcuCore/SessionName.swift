import Foundation

/// The snapshot and browser-tab namespace a command works in. Without
/// `--session` it is the calling agent's own session, read from the
/// environment its host gives every command, so two agents on one machine
/// never share a snapshot or a current tab by accident (measured: with a
/// shared "default", one agent's `click --element` landed in the window
/// another agent had just scanned).
public enum SessionName {
    public static let environmentKeys = ["AMCU_SESSION", "AAA_SESSION", "CLAUDE_CODE_SESSION_ID"]

    public static func resolve(explicit: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> (name: String, source: String) {
        if let explicit, !explicit.isEmpty { return (explicit, "--session") }
        for key in environmentKeys {
            if let raw = environment[key] {
                let cleaned = sanitize(raw)
                if !cleaned.isEmpty { return (cleaned, "$\(key)") }
            }
        }
        return ("default", "fallback")
    }

    public static func sanitize(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var cleaned = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).map { allowed.contains($0) ? $0 : "_" })
        while cleaned.contains("..") { cleaned = cleaned.replacingOccurrences(of: "..", with: "_") }
        return String(cleaned.prefix(80))
    }
}
