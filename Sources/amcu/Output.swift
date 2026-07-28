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
                print(string)
            }
        } else {
            print(text())
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
                FileHandle.standardError.write(Data((string + "\n").utf8))
            }
        } else {
            var lines = ["error [\(amcuError.code.rawValue)]: \(amcuError.message)"]
            lines.append(contentsOf: amcuError.nextSteps.map { "  next: \($0)" })
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        }
        exit(1)
    }
}

struct ActionResult: Encodable {
    let ok = true
    let action: String
    let mode: String?
    let target: String
    let detail: String?

    var text: String {
        var parts = ["\(action) ok on \(target)"]
        if let mode { parts.append("via \(mode)") }
        if let detail { parts.append("(\(detail))") }
        return parts.joined(separator: " ")
    }
}
