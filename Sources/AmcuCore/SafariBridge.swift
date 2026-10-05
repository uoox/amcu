import Foundation
import UniformTypeIdentifiers

/// The Safari side of the browser bridge.
///
/// Safari cannot run the Chrome extension's transport: its native messaging
/// does not spawn a stdio host but calls `beginRequest` on an app extension
/// (`.appex`) inside a container app, one message at a time, in a sandbox.
/// So the pieces are:
///
///   CLI ──unix socket──▶ relay ◀──TCP 127.0.0.1 (token)── appex ◀──sendNativeMessage── extension
///
/// The relay is the container app's own executable (a copy of this binary)
/// started on demand by the CLI. It speaks exactly the protocol of the Chrome
/// native host on its `safari-<pid>.sock`, so `BrowserClient` and every
/// browser verb reach it unchanged. The extension long-polls: each
/// `sendNativeMessage({type:"poll"})` is held by the relay until a request is
/// queued (or the poll window ends), and the answer comes back with
/// `{type:"response"}`. Loopback TCP is the channel because the sandboxed
/// appex may open it with `network.client` alone, whereas a socket in a
/// shared container needs an app group (which ad-hoc signing cannot claim)
/// or another app's container (which macOS guards with a consent prompt).
public enum SafariBridge {
    public static let browserName = "safari"
    public static let appBundleID = "cc.uoox.amcu.safari"
    public static let extensionBundleID = "cc.uoox.amcu.safari.extension"
    public static let appName = "amcu Safari Bridge"
    public static let appexName = "amcu Safari Extension"
    public static let appExecutable = "amcu"
    public static let appexExecutable = "amcu-safari-extension"
    public static let handlerClassName = "AmcuSafariWebExtensionHandler"
    /// Info.plist keys of the appex that carry the relay's address and secret.
    public static let portKey = "AmcuRelayPort"
    public static let tokenKey = "AmcuRelayToken"
    public static let versionKey = "AmcuVersion"

    /// How long a poll is held before the relay answers `idle`. Short enough
    /// that Safari never gives up on the native message first.
    public static let pollWindow: TimeInterval = 15
    /// A poll seen within this window means the extension is alive.
    public static let readyWindow: TimeInterval = 45
    /// The relay exits after this long without a CLI request; the next
    /// `--browser safari` command starts it again.
    public static let relayIdleExit: TimeInterval = 30 * 60

    /// Verbs that need the Chrome debugger protocol and have no honest Safari
    /// equivalent. The extension refuses them too; refusing here first gives a
    /// fast, uniform answer without a round trip.
    public static let unsupportedMethods: [String: (reason: String, nextSteps: [String])] = [
        "console": ("Safari gives extensions no access to a page's console", [
            "Read state with `amcu browser eval --js …` (e.g. a value the page logged), or use `--browser chrome` / `amcu lab` for console capture."
        ]),
        "network": ("Safari gives extensions no view of a page's network requests", [
            "Use `--browser chrome` (debugger-based capture) or `amcu lab` for network work; `eval --js \"performance.getEntriesByType('resource').map(e => e.name)\"` lists resource URLs."
        ]),
        "dialog": ("Safari gives extensions no way to see or answer alert/confirm/prompt dialogs", [
            "A JavaScript dialog blocks the page until a person answers it; desktop amcu can press its button: `amcu snapshot --app com.apple.Safari`, then `amcu click --element N`."
        ]),
        "drag": ("Safari has no trusted pointer path for extensions, and a synthetic drag does not move sliders or drag-and-drop libraries reliably", [
            "Use desktop amcu on the Safari window (`amcu drag --app com.apple.Safari --from X,Y --to X,Y`) or `--browser chrome`."
        ])
    ]

    public static func unsupportedError(method: String) -> AmcuError? {
        guard let entry = unsupportedMethods[method] else { return nil }
        return AmcuError(.unsupported, "\(method) is not available in Safari: \(entry.reason)", nextSteps: entry.nextSteps)
    }

    /// `--browser safari`, `safari:1234`, or AMCU_BROWSER=safari.
    public static func isSafariSelector(_ selector: String?) -> Bool {
        guard let lowered = selector?.lowercased().trimmingCharacters(in: .whitespaces) else { return false }
        return lowered == browserName || lowered.hasPrefix(browserName + ":")
    }

    /// Safari's extension cannot read files, so `upload` carries their bytes.
    /// The cap keeps a request well inside what native messaging passes.
    public static let maxUploadBytes = 25 * 1024 * 1024

    public static func uploadPayload(paths: [String]) throws -> [[String: Any]] {
        var total = 0
        return try paths.map { path in
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            total += data.count
            guard total <= maxUploadBytes else {
                throw AmcuError(.invalidArgument, "upload through Safari is limited to \(maxUploadBytes / 1024 / 1024) MB in total; these files are larger", nextSteps: [
                    "Upload fewer or smaller files, or use `--browser chrome`, which hands the browser the path instead of the bytes."
                ])
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return [
                "name": url.lastPathComponent,
                "type": UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "",
                "lastModified": Int(modified.timeIntervalSince1970 * 1000),
                "data": data.base64EncodedString()
            ]
        }
    }

    // MARK: - Relay wire (appex ⇄ relay): one JSON line each way per connection

    public struct RelayConfig: Equatable {
        public let port: UInt16
        public let token: String
        public init(port: UInt16, token: String) {
            self.port = port
            self.token = token
        }
    }

    /// Reads the port and token from an appex Info.plist dictionary.
    public static func relayConfig(from info: [String: Any]) -> RelayConfig? {
        let port: UInt16?
        if let number = info[portKey] as? Int { port = UInt16(exactly: number) }
        else if let string = info[portKey] as? String { port = UInt16(string) }
        else { port = nil }
        guard let port, port > 0, let token = info[tokenKey] as? String, token.count >= 16 else { return nil }
        return RelayConfig(port: port, token: token)
    }

    public static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison so the token cannot be probed byte by byte.
    public static func tokenMatches(_ presented: String?, _ expected: String) -> Bool {
        guard let presented else { return false }
        let a = Array(presented.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<a.count { diff |= a[index] ^ b[index] }
        return diff == 0
    }
}

/// The relay's bookkeeping, free of sockets so it can be tested directly:
/// a queue of CLI requests, the extension's polls waiting for them, and the
/// responses travelling back.
public final class SafariRelayCore {
    public struct Request {
        public let id: Int
        public let method: String
        public let params: [String: Any]
    }

    public struct ExtensionInfo {
        public var version: String?
        public var userAgent: String?
        public var hostAccess: Bool?
        public var profile: String?
        public var lastPoll: Date?
    }

    private final class Waiter {
        let semaphore = DispatchSemaphore(value: 0)
        var payload: [String: Any]?
    }

    private let lock = NSLock()
    private var queue: [Request] = []
    private var pollers: [Waiter] = []
    private var pending: [Int: Waiter] = [:]
    private var nextID = 1
    private var info = ExtensionInfo()
    private let now: () -> Date
    /// Safari profiles each run their own copy of the extension; requests go
    /// to one of them so tab ids stay consistent. The first profile heard
    /// from is used until it stops polling.
    private var pinnedProfile: String?
    public private(set) var profilesSeen: Set<String> = []

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public var extensionInfo: ExtensionInfo {
        lock.lock(); defer { lock.unlock() }
        return info
    }

    /// Whether a poll arrived recently or one is waiting right now.
    public var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return readyLocked()
    }

    private func readyLocked() -> Bool {
        if !pollers.isEmpty { return true }
        guard let last = info.lastPoll else { return false }
        return now().timeIntervalSince(last) < SafariBridge.readyWindow
    }

    // MARK: CLI side

    /// Queues a request and blocks until the extension answers or `timeout`
    /// passes. `notPollingAfter` bounds the wait when the extension has not
    /// polled at all: a disabled extension should fail in seconds, not after
    /// the full timeout.
    public func submit(method: String, params: [String: Any], timeout: TimeInterval, notPollingAfter: TimeInterval = 8) -> [String: Any] {
        let waiter = Waiter()
        lock.lock()
        let id = nextID
        nextID += 1
        pending[id] = waiter
        let wasReady = readyLocked()
        queue.append(Request(id: id, method: method, params: params))
        let poller = pollers.isEmpty ? nil : pollers.removeFirst()
        lock.unlock()
        poller?.semaphore.signal()

        let deadline = Date().addingTimeInterval(max(timeout, 1))
        if !wasReady {
            // Give a sleeping or disabled extension a short chance to show up.
            let firstWait = min(notPollingAfter, max(timeout, 1))
            if waiter.semaphore.wait(timeout: .now() + firstWait) == .success {
                return finish(id: id, waiter: waiter)
            }
            lock.lock()
            let stillQueued = queue.contains { $0.id == id }
            if stillQueued && !readyLocked() {
                queue.removeAll { $0.id == id }
                pending[id] = nil
                lock.unlock()
                return Self.failure("bridge_unavailable", "the amcu extension in Safari is not polling (no contact for \(Int(firstWait))s)", Self.notPollingSteps)
            }
            lock.unlock()
        }
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0, waiter.semaphore.wait(timeout: .now() + remaining) == .success {
            return finish(id: id, waiter: waiter)
        }
        lock.lock()
        let neverTaken = queue.contains { $0.id == id }
        queue.removeAll { $0.id == id }
        pending[id] = nil
        lock.unlock()
        if neverTaken {
            return Self.failure("bridge_unavailable", "the amcu extension in Safari did not pick up '\(method)' within \(Int(timeout))s", Self.notPollingSteps)
        }
        return Self.failure("timeout", "the amcu extension in Safari did not answer '\(method)' within \(Int(timeout))s", [
            "The page may be blocked by a JavaScript dialog (Safari gives extensions no way to answer it; desktop amcu can: `amcu snapshot --app com.apple.Safari`).",
            "Retry once; `amcu browser doctor --browser safari` if it keeps happening."
        ])
    }

    private func finish(id: Int, waiter: Waiter) -> [String: Any] {
        lock.lock(); pending[id] = nil; lock.unlock()
        return waiter.payload ?? Self.failure("page_error", "empty response from the extension", [])
    }

    public static let notPollingSteps = [
        "Run `amcu browser doctor --browser safari`: it lists which one-time step is missing.",
        "Usual causes: Safari was restarted (Settings → Developer → \"Allow unsigned extensions\" resets on every launch), or the extension is off in Safari Settings → Extensions.",
        "Safari may also have put the extension's background page to sleep; it wakes on its next alarm (within a minute) or when any tab loads."
    ]

    public static func failure(_ code: String, _ message: String, _ nextSteps: [String]) -> [String: Any] {
        ["ok": false, "error": ["code": code, "message": message, "nextSteps": nextSteps]]
    }

    // MARK: Extension side

    /// Records a poll's self-description. Returns false when the poll comes
    /// from a profile other than the pinned one (it is told to idle).
    public func notePoll(_ message: [String: Any]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let profile = message["profile"] as? String
        if let profile {
            profilesSeen.insert(profile)
            if let pinned = pinnedProfile, pinned != profile {
                // The pinned profile is gone if it has not polled for a while.
                if let last = info.lastPoll, now().timeIntervalSince(last) < SafariBridge.readyWindow { return false }
            }
            pinnedProfile = profile
        }
        info.version = message["version"] as? String ?? info.version
        info.userAgent = message["userAgent"] as? String ?? info.userAgent
        if let access = message["hostAccess"] as? Bool { info.hostAccess = access }
        info.profile = profile ?? info.profile
        info.lastPoll = now()
        return true
    }

    /// Waits up to `window` for a queued request. Nil means idle.
    public func poll(window: TimeInterval) -> Request? {
        let deadline = Date().addingTimeInterval(window)
        while true {
            lock.lock()
            if !queue.isEmpty {
                let request = queue.removeFirst()
                info.lastPoll = now()
                lock.unlock()
                return request
            }
            let waiter = Waiter()
            pollers.append(waiter)
            lock.unlock()
            let remaining = deadline.timeIntervalSinceNow
            let woke = remaining > 0 && waiter.semaphore.wait(timeout: .now() + remaining) == .success
            if !woke {
                lock.lock()
                pollers.removeAll { $0 === waiter }
                info.lastPoll = now()
                // A request may have been queued between the timeout and the lock.
                let request = queue.isEmpty ? nil : queue.removeFirst()
                lock.unlock()
                return request
            }
        }
    }

    /// Puts a request back at the front when it could not be handed over
    /// (the appex connection broke before the write).
    public func requeue(_ request: Request) {
        lock.lock()
        guard pending[request.id] != nil else { lock.unlock(); return }
        queue.insert(request, at: 0)
        let poller = pollers.isEmpty ? nil : pollers.removeFirst()
        lock.unlock()
        poller?.semaphore.signal()
    }

    /// Delivers the extension's answer to the waiting CLI request.
    @discardableResult
    public func respond(id: Int, payload: [String: Any]) -> Bool {
        lock.lock()
        let waiter = pending[id]
        lock.unlock()
        guard let waiter else { return false }
        var clean: [String: Any] = ["ok": payload["ok"] as? Bool ?? false]
        if let result = payload["result"] { clean["result"] = result }
        if let error = payload["error"] { clean["error"] = error }
        waiter.payload = clean
        waiter.semaphore.signal()
        return true
    }
}
