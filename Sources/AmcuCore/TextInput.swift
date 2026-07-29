import ApplicationServices
import Foundation

/// Whether an action was proven to have taken effect, not merely accepted.
///
/// `AXUIElementSetAttributeValue` returning `.success` means the message was
/// delivered, not that the application kept the value — plenty of apps quietly
/// ignore or rewrite writes they dislike. Reading the value back and comparing
/// is the only honest answer, and when reading back is impossible the result
/// says so instead of pretending.
public enum ActionVerification: Sendable {
    case verified(expected: String, actual: String)
    /// The values, where they exist, ride along so the caller can see exactly
    /// what was written versus what the application kept. Comparison is strict
    /// equality on purpose: some apps normalise input (trimming whitespace,
    /// reformatting numbers), and deciding whether a normalised value "counts"
    /// belongs to the caller, not to a fuzzy match buried in here.
    case unverified(reason: UnverifiedReason, expected: String?, actual: String?)

    /// Enum cases cannot carry default arguments, so the reason-only spelling
    /// callers reach for first is provided as an overload.
    public static func unverified(reason: UnverifiedReason) -> ActionVerification {
        .unverified(reason: reason, expected: nil, actual: nil)
    }

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .verified:
            return "verified"
        case let .unverified(reason, _, _):
            return "unverified: \(reason.label)"
        }
    }
}

extension ActionVerification: Encodable {
    private enum CodingKeys: String, CodingKey {
        case verified, reason, expected, actual
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .verified(expected, actual):
            try container.encode(true, forKey: .verified)
            try container.encode(expected, forKey: .expected)
            try container.encode(actual, forKey: .actual)
        case let .unverified(reason, expected, actual):
            try container.encode(false, forKey: .verified)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(expected, forKey: .expected)
            try container.encodeIfPresent(actual, forKey: .actual)
        }
    }
}

public enum UnverifiedReason: String, Sendable, Codable {
    /// The read-back differs from what was written.
    case valueMismatch
    /// The element exposes no readable AXValue, so there is nothing to compare.
    case notReadable
    /// The input went through synthesised keystrokes, which by construction
    /// have no value to read back against.
    case syntheticInput

    public var label: String {
        switch self {
        case .valueMismatch: return "value mismatch"
        case .notReadable: return "not readable"
        case .syntheticInput: return "synthetic input"
        }
    }
}

/// How much of the element's value a replacement actually touched. The two
/// outcomes differ enough — one edits the selection, the other discards
/// everything that was there — that reporting them under the same name would
/// hide a data-loss-shaped surprise from the caller.
public enum ReplacementScope: String, Sendable, Codable {
    /// The element exposed a usable `AXSelectedTextRange`; only that range
    /// (or the caret position) was rewritten.
    case selection
    /// No usable selection range: the entire value was overwritten.
    case wholeValue

    public var label: String {
        switch self {
        case .selection: return "replaced selection"
        case .wholeValue: return "no selection range available — replaced the whole value"
        }
    }
}

/// Text entry through the accessibility value attributes rather than the
/// keyboard. This path needs no focus, no frontmost window, and no cooperation
/// from the active input method — which is why it is the preferred route
/// whenever the target element supports it.
public enum TextInput {
    /// Writes AXValue and reads it back to prove the write stuck.
    public static func setValue(_ value: String, on element: AXUIElement) throws -> ActionVerification {
        try AX.setValue(element, kAXValueAttribute as String, value as CFTypeRef)
        return verifyValue(expected: value, on: element)
    }

    /// Replaces the selected text (or inserts at the caret when the selection
    /// is empty) by rewriting AXValue at the string level, then parks the caret
    /// just after the inserted text. When the element exposes no usable
    /// selection, the whole value is replaced instead — still a real write,
    /// just a coarser one, and the returned scope says which one happened so
    /// the caller learns "your previous content is gone" from the result
    /// instead of from the next read.
    public static func replaceSelection(
        with text: String,
        on element: AXUIElement
    ) throws -> (verification: ActionVerification, resultingValue: String, scope: ReplacementScope) {
        let newValue: String
        let caret: Int
        let scope: ReplacementScope
        if let current = AX.string(element, kAXValueAttribute as String),
           let range = selectedTextRange(of: element) {
            (newValue, caret) = replacing(text, in: current, utf16Range: range)
            scope = .selection
        } else {
            newValue = text
            caret = text.utf16.count
            scope = .wholeValue
        }

        try AX.setValue(element, kAXValueAttribute as String, newValue as CFTypeRef)
        let verification = verifyValue(expected: newValue, on: element)

        // Caret placement is a courtesy, not part of the contract: a write that
        // verified must not be reported as failed because the app refused to
        // move its selection afterwards.
        if AX.isSettable(element, kAXSelectedTextRangeAttribute as String) {
            setSelectedTextRange(CFRange(location: caret, length: 0), on: element)
        }

        let resulting: String
        switch verification {
        case let .verified(_, actual):
            resulting = actual
        case let .unverified(_, _, actual):
            resulting = actual ?? newValue
        }
        return (verification, resulting, scope)
    }

    /// Splices `replacement` into `value` over a UTF-16 range.
    ///
    /// `AXSelectedTextRange` speaks UTF-16 code-unit offsets while Swift string
    /// indices do not, so the splice happens on the UTF-16 units themselves —
    /// slicing the `String` by a converted index would mis-cut any value
    /// containing CJK text or emoji. Out-of-range offsets are clamped rather
    /// than refused because applications do report ranges one past a value
    /// they have just mutated.
    ///
    /// Returns the new value and the UTF-16 offset just past the inserted
    /// text, which is where the caret belongs after a replacement.
    public static func replacing(
        _ replacement: String,
        in value: String,
        utf16Range: CFRange
    ) -> (result: String, caretUTF16: Int) {
        var units = Array(value.utf16)
        let location = min(max(utf16Range.location, 0), units.count)
        let length = min(max(utf16Range.length, 0), units.count - location)
        units.replaceSubrange(location ..< location + length, with: Array(replacement.utf16))
        return (String(decoding: units, as: UTF16.self), location + replacement.utf16.count)
    }

    // MARK: - Private

    private static func verifyValue(expected: String, on element: AXUIElement) -> ActionVerification {
        guard let actual = AX.string(element, kAXValueAttribute as String) else {
            return .unverified(reason: .notReadable, expected: expected, actual: nil)
        }
        guard actual == expected else {
            return .unverified(reason: .valueMismatch, expected: expected, actual: actual)
        }
        return .verified(expected: expected, actual: actual)
    }

    /// `AXSelectedTextRange` arrives boxed in an AXValue, which `AX.attribute`
    /// hands back untyped; the unboxing lives here rather than in AXBridge
    /// because no other caller needs a CFRange.
    private static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        guard let value = AX.attribute(element, kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return range
    }

    private static func setSelectedTextRange(_ range: CFRange, on element: AXUIElement) {
        var range = range
        guard let boxed = AXValueCreate(.cfRange, &range) else { return }
        try? AX.setValue(element, kAXSelectedTextRangeAttribute as String, boxed)
    }
}
