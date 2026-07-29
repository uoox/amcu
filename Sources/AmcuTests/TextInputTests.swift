import Foundation
import AmcuCore

/// Pure-logic coverage of the text-replacement path. The AX write/read-back
/// round trip needs a live application and would mutate real UI state, so it
/// is exercised manually; what is tested here is the part that silently
/// corrupts text when it is wrong — the UTF-16 offset arithmetic — plus the
/// three-state verdict and its wording.
func runTextInputTests(_ t: Harness) {
    t.suite("text replacement: UTF-16 offsets")

    do {
        // AXSelectedTextRange counts UTF-16 code units, not Characters.
        let (result, caret) = TextInput.replacing("XY", in: "hello", utf16Range: CFRange(location: 1, length: 3))
        t.expectEqual(result, "hXYo", "an ASCII range replaces exactly the selected units")
        t.expectEqual(caret, 3, "the caret lands just past the inserted text")
    }

    do {
        let (result, caret) = TextInput.replacing("插入", in: "你好世界", utf16Range: CFRange(location: 2, length: 0))
        t.expectEqual(result, "你好插入世界", "a zero-length selection inserts at the caret in CJK text")
        t.expectEqual(caret, 4, "the caret advances by the insertion's UTF-16 length")
    }

    do {
        // Each of these CJK characters is one UTF-16 unit; a byte- or
        // Character-based slice would land somewhere else entirely.
        let (result, _) = TextInput.replacing("x", in: "你好世界", utf16Range: CFRange(location: 1, length: 2))
        t.expectEqual(result, "你x界", "CJK selections are measured in UTF-16 units")
    }

    do {
        // 👍 is a surrogate pair: two UTF-16 units, one Character. This is the
        // case a Character-counted offset gets wrong.
        let (result, caret) = TextInput.replacing("👏", in: "a👍b", utf16Range: CFRange(location: 1, length: 2))
        t.expectEqual(result, "a👏b", "a surrogate-pair emoji is replaced as two UTF-16 units")
        t.expectEqual(caret, 3, "the caret accounts for the replacement's own surrogate pair")
    }

    do {
        let (result, caret) = TextInput.replacing("!", in: "🇨🇳好", utf16Range: CFRange(location: 4, length: 1))
        t.expectEqual(result, "🇨🇳!", "text after a multi-unit flag emoji is addressed correctly")
        t.expectEqual(caret, 5, "the caret is positioned in UTF-16 space, not Character space")
    }

    do {
        // Applications do report ranges past the end of a value they have just
        // mutated; clamping keeps the write meaningful instead of crashing.
        let (result, caret) = TextInput.replacing("x", in: "abc", utf16Range: CFRange(location: 10, length: 5))
        t.expectEqual(result, "abcx", "an out-of-bounds location clamps to an append")
        t.expectEqual(caret, 4, "the clamped caret still tracks the insertion")

        let (overrun, _) = TextInput.replacing("x", in: "abc", utf16Range: CFRange(location: 2, length: 99))
        t.expectEqual(overrun, "abx", "an overlong length clamps to the end of the value")

        let (negative, _) = TextInput.replacing("x", in: "abc", utf16Range: CFRange(location: -3, length: 1))
        t.expectEqual(negative, "xbc", "a negative location clamps to the start")
    }

    do {
        let (result, caret) = TextInput.replacing("", in: "abc", utf16Range: CFRange(location: 0, length: 3))
        t.expectEqual(result, "", "replacing the whole value with nothing empties it")
        t.expectEqual(caret, 0, "deleting a selection leaves the caret at its start")
    }

    t.suite("text replacement: scope disclosure")

    do {
        // A whole-value overwrite discards the field's previous content; the
        // wording must say so plainly, because it is what the caller reads.
        t.expect(
            ReplacementScope.wholeValue.label.contains("whole value"),
            "the whole-value fallback names itself as an overwrite"
        )
        t.expect(
            ReplacementScope.selection.label.contains("selection"),
            "a selection replacement names itself as such"
        )
        t.expect(
            ReplacementScope.selection.label != ReplacementScope.wholeValue.label,
            "the two scopes are distinguishable in text output"
        )
        // The scope rides inside JSON command output, so it must encode as a
        // stable machine-readable token.
        do {
            let encoded = String(decoding: try JSONEncoder().encode([ReplacementScope.wholeValue, .selection]), as: UTF8.self)
            t.expect(
                encoded.contains("\"wholeValue\"") && encoded.contains("\"selection\""),
                "scopes encode as stable JSON tokens"
            )
        } catch {
            t.expect(false, "encoding a replacement scope threw: \(error)")
        }
    }

    t.suite("action verification")

    do {
        let verified = ActionVerification.verified(expected: "a", actual: "a")
        t.expect(verified.isVerified, "an exact read-back is verified")
        t.expectEqual(verified.summary, "verified", "a verified write says so plainly")
    }

    do {
        let mismatch = ActionVerification.unverified(reason: .valueMismatch, expected: " a ", actual: "a")
        t.expect(!mismatch.isVerified, "a normalised read-back is not verified — the caller judges, not us")
        t.expectEqual(mismatch.summary, "unverified: value mismatch", "a mismatch names its reason")
    }

    do {
        let unreadable = ActionVerification.unverified(reason: .notReadable)
        t.expect(!unreadable.isVerified, "an unreadable element cannot claim verification")
        t.expectEqual(unreadable.summary, "unverified: not readable", "an unreadable element admits it, not fakes success")
        t.expectEqual(
            ActionVerification.unverified(reason: .syntheticInput).summary,
            "unverified: synthetic input",
            "synthesised keystrokes admit they cannot be read back"
        )
    }

    do {
        // The verdict rides inside JSON command output, so it must encode —
        // and must carry both values on a mismatch for the caller to compare.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let verified = String(
                decoding: try encoder.encode(ActionVerification.verified(expected: "a", actual: "a")),
                as: UTF8.self
            )
            t.expect(verified.contains("\"verified\":true"), "a verified verdict encodes as verified")

            let mismatch = String(
                decoding: try encoder.encode(ActionVerification.unverified(reason: .valueMismatch, expected: "wrote", actual: "kept")),
                as: UTF8.self
            )
            t.expect(mismatch.contains("\"verified\":false"), "a mismatch encodes as unverified")
            t.expect(mismatch.contains("\"reason\":\"valueMismatch\""), "the reason is machine-readable in JSON")
            t.expect(
                mismatch.contains("\"expected\":\"wrote\"") && mismatch.contains("\"actual\":\"kept\""),
                "both sides of a mismatch are carried out for the caller to compare"
            )
        } catch {
            t.expect(false, "encoding a verification threw: \(error)")
        }
    }
}
