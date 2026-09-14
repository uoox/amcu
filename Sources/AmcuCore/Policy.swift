import Foundation

/// User-editable knobs, read from `~/.config/amcu/policy.json`. Missing file
/// or malformed JSON means defaults; a malformed file is reported once on
/// stderr so a typo does not silently disable a deny entry.
///
/// ```json
/// {
///   "sensitive": { "deny": ["com.example.vault"], "allow": ["com.apple.Passwords"] },
///   "immune": ["com.example.antiautomation"],
///   "settle": { "min": 0.2, "quiet": 0.3, "max": 5 }
/// }
/// ```
public struct Policy: Sendable {
    public var sensitiveDeny: [String] = []
    public var sensitiveAllow: [String] = []
    public var immune: [String] = []
    public var settle = SettleTiming()

    public struct SettleTiming: Sendable {
        /// Never return before this much time has passed after the action.
        public var min: Double = 0.2
        /// Return once no accessibility notification arrived for this long.
        public var quiet: Double = 0.3
        /// Give up waiting after this long and report `settled: false`.
        public var max: Double = 5.0
    }

    public static var path: String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("amcu/policy.json").path
    }

    nonisolated(unsafe) private static var cached: Policy?

    public static var current: Policy {
        if let cached { return cached }
        let loaded = load(path: path)
        cached = loaded
        return loaded
    }

    public static func load(path: String) -> Policy {
        guard let data = FileManager.default.contents(atPath: path) else { return Policy() }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            FileHandle.standardError.write(Data("warning: \(path) is not a JSON object; using default policy\n".utf8))
            return Policy()
        }
        return parse(root)
    }

    public static func parse(_ root: [String: Any]) -> Policy {
        var policy = Policy()
        func strings(_ value: Any?) -> [String] { (value as? [Any])?.compactMap { $0 as? String } ?? [] }
        if let sensitive = root["sensitive"] as? [String: Any] {
            policy.sensitiveDeny = strings(sensitive["deny"])
            policy.sensitiveAllow = strings(sensitive["allow"])
        }
        policy.immune = strings(root["immune"])
        if let settle = root["settle"] as? [String: Any] {
            func number(_ key: String, _ lower: Double, _ upper: Double, _ fallback: Double) -> Double {
                guard let raw = settle[key] as? NSNumber else { return fallback }
                return Swift.min(upper, Swift.max(lower, raw.doubleValue))
            }
            policy.settle.min = number("min", 0, 5, policy.settle.min)
            policy.settle.quiet = number("quiet", 0.05, 5, policy.settle.quiet)
            policy.settle.max = number("max", 0.2, 30, policy.settle.max)
        }
        return policy
    }

    /// Everything a caller may want to print: the effective values plus where
    /// they came from.
    public var effective: [String: Any] {
        [
            "path": Policy.path,
            "exists": FileManager.default.fileExists(atPath: Policy.path),
            "sensitive": [
                "builtin": SensitiveApps.builtinBundleIDs.sorted(),
                "deny": sensitiveDeny,
                "allow": sensitiveAllow
            ],
            "immune": ["builtin": SensitiveApps.builtinImmune.sorted(), "extra": immune],
            "settle": ["min": settle.min, "quiet": settle.quiet, "max": settle.max]
        ]
    }
}
