import Foundation

/// Secrets loaded from a dotenv-style file with `--secrets` (or $AMCU_SECRETS).
/// Values are typed by key reference (`fill --secret KEY`) so the secret never
/// appears on the command line, and every emitted string — snapshots, echoes,
/// verification errors, console and network listings — has known values masked.
///
/// The masking is exact-string matching and therefore best-effort where the
/// page re-encodes a value (base64, URL-encoding, JSON escapes inside network
/// bodies defeat it). It is a redaction aid, not a confidentiality boundary;
/// the guide says so in the same breath that documents the flag.
public enum SecretStore {
    public private(set) static var values: [String: String] = [:]

    public static var isEmpty: Bool { values.isEmpty }

    public static func load(path: String) throws {
        let raw: String
        do {
            raw = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw AmcuError(.invalidArgument, "cannot read secrets file \(path): \((error as NSError).localizedDescription)", nextSteps: [
                "--secrets expects a dotenv-style file of KEY=VALUE lines."
            ])
        }
        var loaded: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") { continue }
            if text.hasPrefix("export ") { text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = text.firstIndex(of: "=") else { continue }
            let key = String(text[text.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(text[text.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !value.isEmpty else { continue }
            loaded[key] = value
        }
        guard !loaded.isEmpty else {
            throw AmcuError(.invalidArgument, "no KEY=VALUE entries found in \(path)")
        }
        values = loaded
    }

    public static func value(forKey key: String) throws -> String {
        guard let value = values[key] else {
            let known = values.keys.sorted().joined(separator: ", ")
            throw AmcuError(.invalidArgument, "no secret named '\(key)' in the loaded secrets file", nextSteps: [
                values.isEmpty
                    ? "Load one first: --secrets path/to/.env (KEY=VALUE lines), or set $AMCU_SECRETS."
                    : "Loaded keys: \(known)"
            ])
        }
        return value
    }

    /// Longest values first, so a value containing another is masked whole.
    /// Values shorter than 4 characters are skipped — masking them would
    /// mangle ordinary text more than it would protect anything.
    public static func mask(_ text: String) -> String {
        guard !values.isEmpty else { return text }
        var out = text
        for (key, value) in ordered() {
            out = out.replacingOccurrences(of: value, with: token(for: key))
        }
        return out
    }

    /// Masking inside an already-encoded JSON document. A secret containing
    /// `"` or `\` appears JSON-escaped there, so it is matched in that
    /// spelling too; and a purely numeric secret standing as a bare JSON
    /// number is replaced by a *quoted* token, so the document stays valid.
    public static func maskJSON(_ text: String) -> String {
        guard !values.isEmpty else { return text }
        var out = text
        for (key, value) in ordered() {
            let mark = token(for: key)
            let escaped = jsonEscaped(value)
            if escaped != value {
                // Escaped spellings only occur inside strings; a plain swap is safe.
                out = out.replacingOccurrences(of: escaped, with: mark)
                // The raw spelling cannot occur verbatim in valid JSON (its
                // quote/backslash would have been escaped), and scanning for
                // it would desynchronise the string tracker below.
                continue
            }
            out = replaceRespectingJSONStrings(in: out, value: value, mark: mark)
        }
        return out
    }

    /// Walks the document tracking whether the cursor is inside a JSON string.
    /// Inside one, the bare token is substituted; outside, only a standalone
    /// value (a bare number) is replaced, and with a *quoted* token, so the
    /// document stays valid JSON either way.
    private static func replaceRespectingJSONStrings(in text: String, value: String, mark: String) -> String {
        let chars = Array(text)
        let target = Array(value)
        guard !target.isEmpty else { return text }
        var result = ""
        result.reserveCapacity(chars.count)
        var inString = false
        var i = 0
        let standaloneBefore: Set<Character> = [":", ",", "[", " ", "\n", "\t", "\r"]
        let standaloneAfter: Set<Character> = [",", "}", "]", " ", "\n", "\t", "\r"]
        while i < chars.count {
            let c = chars[i]
            if inString && c == "\\" && i + 1 < chars.count {
                result.append(c)
                result.append(chars[i + 1])
                i += 2
                continue
            }
            if c != "\"" && i + target.count <= chars.count && Array(chars[i..<(i + target.count)]) == target {
                let prevOK = i == 0 || standaloneBefore.contains(chars[i - 1])
                let next = i + target.count
                let nextOK = next >= chars.count || standaloneAfter.contains(chars[next])
                if inString {
                    result += mark
                    i += target.count
                    continue
                }
                if prevOK && nextOK {
                    result += "\"\(mark)\""
                    i += target.count
                    continue
                }
            }
            if c == "\"" { inString.toggle() }
            result.append(c)
            i += 1
        }
        return result
    }

    private static func ordered() -> [(key: String, value: String)] {
        values.sorted { $0.value.count > $1.value.count }
            .filter { $0.value.count >= 4 }
            .map { (key: $0.key, value: $0.value) }
    }

    /// The replacement token must never itself break the surrounding text; a
    /// key is reduced to the characters that are safe in both plain text and
    /// an encoded JSON string.
    private static func token(for key: String) -> String {
        let safe = key.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
        return "[secret:\(safe.isEmpty ? "?" : safe)]"
    }

    private static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode([value]),
              let text = String(data: data, encoding: .utf8) else { return value }
        return String(text.dropFirst(2).dropLast(2)) // ["…"] → the inner spelling
    }
}
