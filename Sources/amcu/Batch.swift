import Foundation
import AmcuCore

/// Several commands in one process: JSONL on stdin (or `--file`), one object
/// per step, `{"cmd": "click", "element": 3}`. Keys become flags; booleans
/// become boolean flags; the batch's own `--app`, `--session`, `--json`,
/// `--mode` and `--no-observe` are inherited by steps that do not set them.
/// Steps run in order and the batch stops at the first failure, which is
/// reported like any other error; the steps before it stood.
enum Batch {
    static let inherited = ["app", "session", "mode", "window-id", "window-index"]
    static let inheritedBooleans = ["json", "no-observe", "allow-sensitive", "force", "screen"]

    static func run(_ flags: Flags, dispatch: (String, Flags) throws -> Void) throws {
        let source: Data
        if let path = flags.string("file") {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw AmcuError(.invalidArgument, "cannot read \(path)")
            }
            source = data
        } else {
            source = FileHandle.standardInput.readDataToEndOfFile()
        }
        let lines = String(decoding: source, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else {
            throw AmcuError(.invalidArgument, "batch needs at least one JSONL step on stdin or in --file", nextSteps: [
                "Example: printf '%s\\n' '{\"cmd\":\"click\",\"element\":3}' '{\"cmd\":\"type\",\"text\":\"hello\"}' | amcu batch --app com.apple.TextEdit"
            ])
        }
        for (number, line) in lines.enumerated() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                throw AmcuError(.invalidArgument, "batch step \(number + 1) is not a JSON object: \(line)")
            }
            guard let command = object["cmd"] as? String else {
                throw AmcuError(.invalidArgument, "batch step \(number + 1) has no \"cmd\"")
            }
            if command == "batch" {
                throw AmcuError(.invalidArgument, "batch step \(number + 1): a batch cannot nest another batch")
            }
            var argv: [String] = []
            for (key, value) in object where key != "cmd" {
                switch value {
                case let flag as Bool:
                    if flag { argv.append("--\(key)") }
                case let number as NSNumber:
                    argv.append("--\(key)"); argv.append(number.stringValue)
                case let text as String:
                    argv.append("--\(key)"); argv.append(text)
                default:
                    throw AmcuError(.invalidArgument, "batch step \(number + 1): \"\(key)\" must be a string, number or boolean")
                }
            }
            for key in inherited where object[key] == nil {
                if let value = flags.string(key) { argv.append("--\(key)"); argv.append(value) }
            }
            for key in inheritedBooleans where object[key] == nil {
                if flags.has(key) { argv.append("--\(key)") }
            }
            let stepFlags = try Flags(argv)
            if !Output.json { print("# step \(number + 1): \(command)") }
            try dispatch(command, stepFlags)
        }
    }
}
