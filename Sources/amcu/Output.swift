import Foundation
import AmcuCore

enum Output {
    static var json = false

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func emit<T: Encodable>(_ value: T, text: () -> String) {
        if json {
            if let data = try? encoder().encode(value), let string = String(data: data, encoding: .utf8) {
                print(SecretStore.maskJSON(string))
            }
        } else {
            print(SecretStore.mask(text()))
        }
    }

    static func fail(_ error: Error) -> Never {
        let amcuError = error as? AmcuError
            ?? AmcuError(.unsupported, (error as NSError).localizedDescription)
        if json {
            struct Payload: Encodable {
                let ok = false
                let code: String
                let message: String
                let nextSteps: [String]
            }
            let payload = Payload(code: amcuError.code.rawValue, message: amcuError.message, nextSteps: amcuError.nextSteps)
            if let data = try? encoder().encode(payload), let string = String(data: data, encoding: .utf8) {
                FileHandle.standardError.write(Data((SecretStore.maskJSON(string) + "\n").utf8))
            }
        } else {
            var lines = ["error [\(amcuError.code.rawValue)]: \(amcuError.message)"]
            lines.append(contentsOf: amcuError.nextSteps.map { "  next: \($0)" })
            FileHandle.standardError.write(Data((SecretStore.mask(lines.joined(separator: "\n")) + "\n").utf8))
        }
        exit(1)
    }
}

/// What every action reports after it ran: how long the interface took to
/// settle, whether a background input stole focus, and the diff of the
/// session's snapshot if one was on record for this application.
struct Aftermath: Encodable {
    var settle: SettleReport?
    var focusNote: String?
    var observation: SnapshotDiff?

    var lines: [String] {
        var out: [String] = []
        if let observation { out.append(observation.text) }
        return out
    }
}

struct ActionResult: Encodable {
    let ok = true
    let action: String
    let mode: String?
    let target: String
    var detail: String?
    var settle: SettleReport?
    var observation: SnapshotDiff?

    var text: String {
        var parts = ["\(action) ok on \(target)"]
        if let mode { parts.append("via \(mode)") }
        if let detail { parts.append("(\(detail))") }
        if let settle { parts.append("(\(settle.summary))") }
        var lines = [parts.joined(separator: " ")]
        if let observation { lines.append(observation.text) }
        return lines.joined(separator: "\n")
    }

    mutating func apply(_ aftermath: Aftermath) {
        settle = aftermath.settle
        observation = aftermath.observation
        if let note = aftermath.focusNote {
            detail = [detail, note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; ")
        }
    }
}

/// `ActionResult` plus the proof: whether the write was read back intact, and
/// (for replacements) the full value the element now holds.
struct VerifiedActionResult: Encodable {
    let ok = true
    let action: String
    let mode: String?
    let target: String
    var detail: String?
    let verification: ActionVerification
    let resultingValue: String?
    /// Only `replace` sets this; `set-value` always overwrites by contract.
    var scope: ReplacementScope? = nil
    var settle: SettleReport?
    var observation: SnapshotDiff?

    var text: String {
        var parts = ["\(action) ok on \(target)"]
        if let mode { parts.append("via \(mode)") }
        if let detail { parts.append("(\(detail))") }
        if let scope { parts.append("(\(scope.label))") }
        parts.append("(\(verification.summary))")
        if let settle { parts.append("(\(settle.summary))") }
        var lines = [parts.joined(separator: " ")]
        if let observation { lines.append(observation.text) }
        return lines.joined(separator: "\n")
    }

    mutating func apply(_ aftermath: Aftermath) {
        settle = aftermath.settle
        observation = aftermath.observation
        if let note = aftermath.focusNote {
            detail = [detail, note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; ")
        }
    }
}
