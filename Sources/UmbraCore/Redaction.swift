import Foundation

/// Deciding whether a value is a secret.
///
/// AppKit's own secure fields do mask their characters — but they publish the
/// mask at the original length, in private-use glyphs. So even the well-behaved
/// case leaks how long the password is and hands a model a run of junk it
/// cannot read. A custom control, a web input or an Electron form makes no
/// promise at all.
///
/// A snapshot goes straight to a model and usually into a transcript, so the
/// value is withheld on any hint that it holds a secret. False positives cost a
/// caller one visible string; false negatives cost them a password.
public enum Redaction {
    public static let placeholder = "[redacted]"

    static let markers = [
        "secure", "password", "passwd", "passcode", "pin code",
        "verification code", "one-time code", "otp", "secret", "token"
    ]

    /// `descriptors` are the element's self-descriptions: role, subrole, title,
    /// description, placeholder, identifier.
    public static func holdsSecret(descriptors: [String]) -> Bool {
        let haystack = descriptors.joined(separator: " ").lowercased()
        return markers.contains(where: haystack.contains)
    }
}
