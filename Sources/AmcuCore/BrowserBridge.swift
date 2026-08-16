import AppKit
import Foundation

/// The contract between the three parties of browser automation: the CLI, the
/// native messaging host (this same binary, launched by the browser), and the
/// extension.
///
/// Why native messaging: the browser starts the host itself and enforces which
/// extension may talk to it, so there is no port to guard and no token to
/// configure or lose. The CLI reaches the host over a Unix socket in the user's
/// cache directory, which the file system already protects.
public enum BrowserBridge {
    /// Reverse-DNS name registered in the browser's NativeMessagingHosts dir.
    public static let hostName = "cc.uoox.amcu"

    /// The extension's fixed id: it is derived from the `key` in its manifest,
    /// so it is the same wherever the unpacked folder lives.
    public static var extensionID: String { ExtensionBundle.id }

    /// Chrome hands host→extension messages a 1 MB ceiling; requests are tiny,
    /// but a caller could pass a huge --value, so it is checked rather than
    /// discovered as a dropped connection.
    public static let maxOutboundMessage = 1_000_000

    // MARK: - Native messaging framing (4-byte native-endian length + JSON)

    public static func frame(_ json: Data) -> Data {
        var length = UInt32(json.count).littleEndian
        var data = Data(bytes: &length, count: 4)
        data.append(json)
        return data
    }

    /// Splits framed messages out of a stream buffer. Returns the complete
    /// messages and leaves any partial tail in `buffer`.
    public static func unframe(_ buffer: inout Data) -> [Data] {
        var messages: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.withUnsafeBytes { raw -> UInt32 in
                let bytes = raw.bindMemory(to: UInt8.self)
                return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            }
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            messages.append(buffer.subdata(in: 4..<total))
            buffer.removeSubrange(0..<total)
        }
        return messages
    }

    // MARK: - Socket discovery

    /// One socket per running host: `<browser>-<pid>.sock`. Several browsers,
    /// or several profiles of one browser, each spawn their own host.
    public static var socketDirectory: URL {
        SessionStore.directory.appendingPathComponent("browser", isDirectory: true)
    }

    public static func socketURL(browser: String, pid: pid_t) -> URL {
        socketDirectory.appendingPathComponent("\(browser)-\(pid).sock")
    }

    /// Parses `<browser>-<pid>.sock` back into its parts.
    public static func parseSocketName(_ name: String) -> (browser: String, pid: pid_t)? {
        guard name.hasSuffix(".sock") else { return nil }
        let stem = name.dropLast(5)
        guard let dash = stem.lastIndex(of: "-"), let pid = pid_t(stem[stem.index(after: dash)...]) else { return nil }
        return (String(stem[..<dash]), pid)
    }

    // MARK: - Browser identity

    /// Maps a browser's bundle id to the short name used in socket names,
    /// `--browser`, and the install report.
    public static func browserName(bundleID: String?) -> String? {
        guard let bundleID = bundleID?.lowercased() else { return nil }
        let table: [(String, String)] = [
            ("com.google.chrome.canary", "chrome-canary"),
            ("com.google.chrome.dev", "chrome-dev"),
            ("com.google.chrome.beta", "chrome-beta"),
            ("com.google.chrome.for.testing", "chrome-for-testing"),
            ("com.google.chrome", "chrome"),
            ("org.chromium.chromium", "chromium"),
            ("com.microsoft.edgemac.beta", "edge-beta"),
            ("com.microsoft.edgemac.dev", "edge-dev"),
            ("com.microsoft.edgemac.canary", "edge-canary"),
            ("com.microsoft.edgemac", "edge"),
            ("com.brave.browser.beta", "brave-beta"),
            ("com.brave.browser.nightly", "brave-nightly"),
            ("com.brave.browser", "brave"),
            ("com.vivaldi.vivaldi", "vivaldi"),
            ("company.thebrowser.browser", "arc"),
            ("com.operasoftware.opera", "opera"),
        ]
        for (prefix, name) in table where bundleID == prefix { return name }
        for (prefix, name) in table where bundleID.hasPrefix(prefix) { return name }
        return nil
    }

    /// Falls back to the user-agent brand list the extension reports.
    public static func browserName(brands: [String]) -> String? {
        let lowered = brands.map { $0.lowercased() }
        if lowered.contains(where: { $0.contains("microsoft edge") }) { return "edge" }
        if lowered.contains(where: { $0.contains("brave") }) { return "brave" }
        if lowered.contains(where: { $0.contains("opera") }) { return "opera" }
        if lowered.contains(where: { $0.contains("vivaldi") }) { return "vivaldi" }
        if lowered.contains(where: { $0.contains("google chrome") }) { return "chrome" }
        if lowered.contains(where: { $0.contains("chromium") }) { return "chromium" }
        return nil
    }

    // MARK: - Refs

    /// `e12` addresses the main frame; `f42e12` addresses frame 42. The frame
    /// id is part of the ref so a caller cannot accidentally act in the wrong
    /// document.
    public static func parseRef(_ ref: String) -> (frameID: Int, index: Int)? {
        let trimmed = ref.trimmingCharacters(in: .whitespaces)
        var frame = 0
        var rest = Substring(trimmed)
        if rest.hasPrefix("f") {
            rest = rest.dropFirst()
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { return nil }
            frame = value
            rest = rest.dropFirst(digits.count)
        }
        guard rest.hasPrefix("e") else { return nil }
        rest = rest.dropFirst()
        guard !rest.isEmpty, rest.allSatisfy({ $0.isNumber }), let index = Int(rest) else { return nil }
        return (frame, index)
    }

    // MARK: - Errors from the extension

    /// The extension reports `{code, message, nextSteps}` using the same code
    /// vocabulary as AmcuError; anything unrecognised becomes `page_error` so
    /// the message is still surfaced.
    public static func error(fromCode code: String, message: String, nextSteps: [String]) -> AmcuError {
        AmcuError(AmcuError.Code(rawValue: code) ?? .pageError, message, nextSteps: nextSteps)
    }
}

// MARK: - JSON convenience

/// Untyped JSON access for the bridge, where payloads are shaped by the
/// extension and the CLI mostly formats them for display.
public struct JSONValue {
    public let raw: Any?

    public init(_ raw: Any?) { self.raw = raw }

    public subscript(key: String) -> JSONValue {
        JSONValue((raw as? [String: Any])?[key])
    }

    public subscript(index: Int) -> JSONValue {
        guard let array = raw as? [Any], index >= 0, index < array.count else { return JSONValue(nil) }
        return JSONValue(array[index])
    }

    public var isNull: Bool { raw == nil || raw is NSNull }
    public var string: String? { raw as? String }
    public var int: Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }
    public var double: Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }
    /// Only a real boolean counts: JSONSerialization hands numbers and
    /// booleans back as NSNumber, and `0 as? Bool` would happily say false.
    public var bool: Bool? {
        guard let number = raw as? NSNumber else { return raw as? Bool }
        return CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : nil
    }
    public var array: [JSONValue] { (raw as? [Any])?.map(JSONValue.init) ?? [] }
    public var dictionary: [String: JSONValue] {
        (raw as? [String: Any])?.mapValues(JSONValue.init) ?? [:]
    }
    public var stringArray: [String] { array.compactMap(\.string) }

    /// The value as something JSONEncoder can emit, for --json output.
    public var encodable: AnyEncodable { AnyEncodable(raw) }
}

/// Wraps JSONSerialization-shaped values (dictionaries, arrays, strings,
/// numbers, bools, NSNull) so they can be embedded in Encodable payloads.
public struct AnyEncodable: Encodable {
    public let value: Any?

    public init(_ value: Any?) { self.value = value }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case nil, is NSNull:
            try container.encodeNil()
        case let string as String:
            try container.encode(string)
        case let number as NSNumber:
            // Booleans and numbers both arrive as NSNumber; only the CF type tells them apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                try container.encode(number.boolValue)
            } else if number.doubleValue.rounded() == number.doubleValue, abs(number.doubleValue) < 1e15 {
                try container.encode(number.intValue)
            } else {
                try container.encode(number.doubleValue)
            }
        case let array as [Any]:
            try container.encode(array.map(AnyEncodable.init))
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues(AnyEncodable.init))
        default:
            try container.encode(String(describing: value!))
        }
    }
}
