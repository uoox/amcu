import Foundation

/// A running host the CLI can talk to.
public struct BrowserEndpoint: Encodable {
    public let browser: String
    public let pid: pid_t
    public let socket: String
    public let extensionVersion: String?
    public let hostVersion: String?
    public let since: String?
    /// False for a relay whose extension has not checked in lately (Safari):
    /// it exists, but a request would only wait. Chrome hosts are always
    /// ready — the browser spawns them for a live extension.
    public var ready: Bool = true

    public var label: String { "\(browser) (pid \(pid))" }
}

/// The CLI's side of the bridge: finds hosts, picks one, sends requests.
public final class BrowserClient {
    public let endpoint: BrowserEndpoint

    private init(endpoint: BrowserEndpoint) {
        self.endpoint = endpoint
    }

    // MARK: - Discovery

    /// Every host that answers on its socket. Sockets nobody answers on are
    /// left over from a host that died and are removed on the way past.
    public static func discover() -> [BrowserEndpoint] {
        let directory = BrowserBridge.socketDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var endpoints: [BrowserEndpoint] = []
        for name in names.sorted() {
            guard let parsed = BrowserBridge.parseSocketName(name) else { continue }
            let path = directory.appendingPathComponent(name).path
            guard let fd = connect(path: path) else {
                if kill(parsed.pid, 0) != 0 && errno == ESRCH { unlink(path) }
                continue
            }
            defer { close(fd) }
            guard let reply = try? roundTrip(fd: fd, request: ["id": 0, "method": "hello", "params": [:], "timeoutMs": 2000], timeoutSeconds: 3),
                  let result = reply["result"] as? [String: Any] else { continue }
            endpoints.append(BrowserEndpoint(
                browser: result["browser"] as? String ?? parsed.browser,
                pid: parsed.pid,
                socket: path,
                extensionVersion: result["extensionVersion"] as? String,
                hostVersion: result["hostVersion"] as? String,
                since: result["since"] as? String,
                ready: result["ready"] as? Bool ?? true
            ))
        }
        return endpoints
    }

    /// Picks the host for a command. `selector` is a browser name (`chrome`,
    /// `edge`, …) or `name:pid`; without one, a lone host is used, otherwise
    /// Chrome is preferred and the choice is reported in the result.
    public static func select(_ selector: String?) throws -> BrowserClient {
        // Safari's relay is started on demand, by the first command that asks for Safari.
        if SafariBridge.isSafariSelector(selector) && !discover().contains(where: { $0.browser == SafariBridge.browserName }) {
            try SafariRelay.ensureRunning()
        }
        let endpoints = discover()
        guard !endpoints.isEmpty else {
            throw AmcuError(.bridgeUnavailable, "no browser is connected to amcu", nextSteps: [
                "Run `amcu browser doctor` — it checks the native host registration and whether the extension is loaded.",
                "First time here? `amcu browser install`, then load the extension folder it prints in chrome://extensions (Developer mode → Load unpacked).",
                "If the extension is loaded, click its toolbar icon: it says whether the host connected and why not."
            ])
        }
        if let selector, !selector.isEmpty {
            let lowered = selector.lowercased()
            let matches = endpoints.filter { endpoint in
                endpoint.browser == lowered || "\(endpoint.browser):\(endpoint.pid)" == lowered || String(endpoint.pid) == lowered
            }
            guard let match = matches.first else {
                throw AmcuError(.bridgeUnavailable, "no connected browser matches '\(selector)'", nextSteps: [
                    "Connected: \(endpoints.map(\.label).joined(separator: ", ")).",
                    "Pass --browser NAME or NAME:PID from that list."
                ])
            }
            return BrowserClient(endpoint: match)
        }
        if endpoints.count == 1 { return BrowserClient(endpoint: endpoints[0]) }
        // A Safari relay whose extension is not polling would only time out;
        // without an explicit --browser, a live browser wins.
        let live = endpoints.filter(\.ready)
        let pool = live.isEmpty ? endpoints : live
        let preferred = pool.first { $0.browser == "chrome" } ?? pool[0]
        return BrowserClient(endpoint: preferred)
    }

    // MARK: - Requests

    /// Sends one request and returns the extension's result. Errors the
    /// extension reports come back as AmcuError with its code and next steps.
    public func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 30) throws -> JSONValue {
        guard let fd = BrowserClient.connect(path: endpoint.socket) else {
            throw AmcuError(.bridgeUnavailable, "the \(endpoint.browser) host went away", nextSteps: [
                "The browser or the extension was probably closed or reloaded; run `amcu browser tabs` to reconnect."
            ])
        }
        defer { close(fd) }
        let timeoutMs = Int(timeout * 1000)
        let request: [String: Any] = ["id": 1, "method": method, "params": params, "timeoutMs": timeoutMs]
        let reply = try BrowserClient.roundTrip(fd: fd, request: request, timeoutSeconds: timeout + 5)
        if reply["ok"] as? Bool == true {
            return JSONValue(reply["result"])
        }
        let error = reply["error"] as? [String: Any] ?? [:]
        throw BrowserBridge.error(
            fromCode: error["code"] as? String ?? "page_error",
            message: error["message"] as? String ?? "the extension reported an error without a message",
            nextSteps: error["nextSteps"] as? [String] ?? []
        )
    }

    // MARK: - Plumbing

    private static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dest in
                for (index, byte) in bytes.enumerated() { dest[index] = byte }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }

    private static func roundTrip(fd: Int32, request: [String: Any], timeoutSeconds: TimeInterval) throws -> [String: Any] {
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        var offset = 0
        let bytes = [UInt8](line)
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if written < 0 {
                if errno == EINTR { continue }
                throw AmcuError(.bridgeUnavailable, "could not write to the host socket: \(String(cString: strerror(errno)))")
            }
            offset += written
        }

        var timeout = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Replies are a single newline-terminated line; a screenshot can be
        // several megabytes, so only the freshly-read bytes are scanned for the
        // terminator rather than the whole growing buffer each pass.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        var scanned = 0
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw AmcuError(.timeout, "the host did not answer within \(Int(timeoutSeconds))s", nextSteps: [
                        "Run `amcu browser doctor`; if the browser is fine, `amcu browser snapshot` shows the current state before you retry."
                    ])
                }
                throw AmcuError(.bridgeUnavailable, "read from the host socket failed: \(String(cString: strerror(errno)))")
            }
            if count == 0 {
                throw AmcuError(.bridgeUnavailable, "the host closed the connection", nextSteps: [
                    "The browser or the extension probably went away mid-request; run `amcu browser tabs` and retry."
                ])
            }
            let base = buffer.count
            buffer.append(chunk, count: count)
            if let newline = buffer[max(scanned, buffer.startIndex)...].firstIndex(of: 0x0A) {
                let payload = buffer.subdata(in: buffer.startIndex..<newline)
                guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                    throw AmcuError(.bridgeUnavailable, "the host sent a malformed reply")
                }
                return object
            }
            scanned = base + count
        }
    }
}
