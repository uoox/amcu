import AppKit
import CoreGraphics
import Foundation

/// Result of exercising the window-routed pointer path end to end.
public struct SelfCheckResult: Codable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        /// The click was delivered to the intended window at the intended point.
        case accurate
        /// The click was delivered, but not where it was aimed. This is the
        /// signature of window routing without a usable `CGEventSetWindowLocation`.
        case mislocated
        /// Nothing arrived within the timeout.
        case undelivered
        /// The private symbol is missing entirely.
        case unavailable
    }

    public let verdict: Verdict
    public let symbolPresent: Bool
    public let expected: PointJSON?
    public let measured: PointJSON?
    public let osBuild: String
    public let checkedAt: Date

    public init(
        verdict: Verdict,
        symbolPresent: Bool,
        expected: PointJSON?,
        measured: PointJSON?,
        osBuild: String,
        checkedAt: Date
    ) {
        self.verdict = verdict
        self.symbolPresent = symbolPresent
        self.expected = expected
        self.measured = measured
        self.osBuild = osBuild
        self.checkedAt = checkedAt
    }

    public var usable: Bool { verdict == .accurate }

    public var summary: String {
        switch verdict {
        case .accurate:
            return "window-routed pointer events land accurately (verified on build \(osBuild))"
        case .mislocated:
            let expectedText = expected.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "?"
            let measuredText = measured.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "?"
            return "window-routed events are delivered but mislocated: aimed \(expectedText), landed \(measuredText)"
        case .undelivered:
            return "window-routed events were not delivered within the timeout"
        case .unavailable:
            return "CGEventSetWindowLocation is not present in this system's CoreGraphics"
        }
    }
}

public struct PointJSON: Codable, Sendable {
    public let x: Double
    public let y: Double
    public init(_ point: CGPoint) { x = point.x; y = point.y }
}

private final class ProbeView: NSView {
    var onClick: ((CGPoint) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil))
    }
}

/// Verifies at runtime what cannot be verified at compile time.
///
/// `CGEventSetWindowLocation` is private, so its behaviour is not guaranteed
/// across macOS releases — and the way it fails is quiet: clicks keep being
/// delivered, they just stop landing where they were aimed. Rather than trust
/// the symbol's presence, amcu clicks its own throwaway window at a known
/// asymmetric point and checks where the click actually arrived. The result is
/// cached per OS build, so the cost is paid once per system update.
public enum SelfCheck {
    public static var cacheURL: URL {
        SessionStore.directory.appendingPathComponent("selfcheck.json")
    }

    public static var osBuild: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        let build = String(cString: buffer)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion) (\(build))"
    }

    public static func cached() -> SelfCheckResult? {
        guard let data = FileManager.default.contents(atPath: cacheURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let result = try? decoder.decode(SelfCheckResult.self, from: data) else { return nil }
        // A cached verdict from a different OS build says nothing about this one.
        guard result.osBuild == osBuild else { return nil }
        return result
    }

    public static func store(_ result: SelfCheckResult) {
        try? FileManager.default.createDirectory(at: SessionStore.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(result) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Returns a verified verdict, running the probe only when no valid cached
    /// one exists for this OS build.
    @discardableResult
    public static func ensure(force: Bool = false) -> SelfCheckResult {
        if !force, let cached = cached() { return cached }
        let result = probe()
        // `.undelivered` can mean nothing worse than a starved event pump on a
        // busy machine. Caching it would disable background delivery for the
        // rest of this OS build over a one-off timeout, so only durable
        // verdicts are persisted.
        if result.verdict != .undelivered { store(result) }
        return result
    }

    public static func probe(timeout: TimeInterval = 2.0) -> SelfCheckResult {
        guard PointerInput.supportsWindowRouting else {
            return SelfCheckResult(verdict: .unavailable, symbolPresent: false, expected: nil, measured: nil, osBuild: osBuild, checkedAt: Date())
        }
        guard let screen = NSScreen.screens.first else {
            return SelfCheckResult(verdict: .undelivered, symbolPresent: true, expected: nil, measured: nil, osBuild: osBuild, checkedAt: Date())
        }

        let app = NSApplication.shared
        if app.activationPolicy() == .regular { app.setActivationPolicy(.accessory) }

        let side: CGFloat = 60
        let originCocoa = CGPoint(x: screen.frame.minX + 8, y: screen.frame.minY + 8)
        let window = NSWindow(
            contentRect: NSRect(x: originCocoa.x, y: originCocoa.y, width: side, height: side),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let view = ProbeView()
        window.contentView = view
        window.backgroundColor = .clear
        window.isOpaque = false
        // Nearly invisible and never key: the probe must not take focus from
        // whatever the user is actually doing.
        window.alphaValue = 0.01
        window.level = .floating
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()

        let primaryHeight = NSScreen.screens[0].frame.maxY
        let quartzTop = primaryHeight - (originCocoa.y + side)
        let windowFrameQuartz = CGRect(x: originCocoa.x, y: quartzTop, width: side, height: side)
        // Asymmetric on purpose: a flipped or transposed coordinate would still
        // match a centred target, and would go unnoticed.
        let localTarget = CGPoint(x: 20, y: 45)
        let globalTarget = CGPoint(x: windowFrameQuartz.minX + localTarget.x, y: windowFrameQuartz.minY + localTarget.y)
        let expectedViewPoint = CGPoint(x: localTarget.x, y: side - localTarget.y)

        var measured: CGPoint?
        view.onClick = { measured = $0 }

        let windowID = CGWindowID(window.windowNumber)
        let request = PointerInput.ClickRequest(
            pid: ProcessInfo.processInfo.processIdentifier,
            windowID: windowID,
            windowFrame: windowFrameQuartz,
            global: globalTarget,
            mode: .background
        )
        try? PointerInput.click(request)

        let deadline = Date().addingTimeInterval(timeout)
        while measured == nil, Date() < deadline {
            if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
        }

        window.orderOut(nil)
        window.close()

        guard let measured else {
            return SelfCheckResult(
                verdict: .undelivered,
                symbolPresent: true,
                expected: PointJSON(expectedViewPoint),
                measured: nil,
                osBuild: osBuild,
                checkedAt: Date()
            )
        }

        let tolerance: CGFloat = 2
        let accurate = abs(measured.x - expectedViewPoint.x) <= tolerance && abs(measured.y - expectedViewPoint.y) <= tolerance
        return SelfCheckResult(
            verdict: accurate ? .accurate : .mislocated,
            symbolPresent: true,
            expected: PointJSON(expectedViewPoint),
            measured: PointJSON(measured),
            osBuild: osBuild,
            checkedAt: Date()
        )
    }
}
