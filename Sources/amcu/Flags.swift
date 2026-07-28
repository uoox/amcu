import Foundation
import AmcuCore

/// Minimal flag parser. A dependency-free CLI keeps the whole tool auditable in
/// one read, which matters more here than argument-parsing conveniences.
struct Flags {
    private(set) var values: [String: String] = [:]
    private(set) var booleans: Set<String> = []
    private(set) var positional: [String] = []

    static let knownBooleans: Set<String> = [
        "json", "force", "request", "no-snapshot", "screen", "help", "raw", "quiet",
        "press", "raise", "minimize", "restore", "allow-sensitive"
    ]

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    values[String(name[name.startIndex..<equals])] = String(name[name.index(after: equals)...])
                } else if Flags.knownBooleans.contains(name) {
                    booleans.insert(name)
                } else {
                    guard index + 1 < arguments.count else {
                        throw AmcuError(.invalidArgument, "flag --\(name) expects a value")
                    }
                    values[name] = arguments[index + 1]
                    index += 1
                }
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }

    func has(_ name: String) -> Bool { booleans.contains(name) }
    func string(_ name: String) -> String? { values[name] }

    func required(_ name: String, hint: String? = nil) throws -> String {
        guard let value = values[name] else {
            throw AmcuError(.invalidArgument, "missing required flag --\(name)", nextSteps: [hint ?? "Run `amcu help` for this command's flags."])
        }
        return value
    }

    func int(_ name: String) throws -> Int? {
        guard let raw = values[name] else { return nil }
        guard let value = Int(raw) else {
            throw AmcuError(.invalidArgument, "--\(name) expects an integer, got '\(raw)'")
        }
        return value
    }

    /// Narrowing an out-of-range value with a plain `Int32(_:)` conversion traps
    /// and takes the process down. A number the caller can type is input to be
    /// validated, not a programmer error to assert on.
    func int32(_ name: String, min lower: Int32 = .min, max upper: Int32 = .max) throws -> Int32? {
        guard let value = try int(name) else { return nil }
        guard let narrowed = NumericBounds.narrow(value, min: lower, max: upper) else {
            throw AmcuError(.invalidArgument, "--\(name) must be between \(lower) and \(upper), got \(value)", nextSteps: [
                "Scroll and drag distances are in points; values beyond a screen's size have no additional effect."
            ])
        }
        return narrowed
    }

    /// Clamps rather than rejects, for budgets where any positive number is
    /// meaningful and the caller mostly wants "as much as you can".
    func boundedInt(_ name: String, min lower: Int, max upper: Int) throws -> Int? {
        guard let value = try int(name) else { return nil }
        return NumericBounds.clamp(value, min: lower, max: upper)
    }

    func double(_ name: String) throws -> Double? {
        guard let raw = values[name] else { return nil }
        guard let value = Double(raw) else {
            throw AmcuError(.invalidArgument, "--\(name) expects a number, got '\(raw)'")
        }
        return value
    }

    /// Parses "x,y" for the point-taking flags.
    func point(_ name: String) throws -> CGPoint? {
        guard let raw = values[name] else { return nil }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
            throw AmcuError(.invalidArgument, "--\(name) expects 'x,y', got '\(raw)'")
        }
        return CGPoint(x: x, y: y)
    }

    func list(_ name: String) -> [String] {
        guard let raw = values[name], !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
