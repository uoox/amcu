import AppKit
import Foundation

/// The native messaging host: this binary, launched by the browser when the
/// extension connects, speaking length-prefixed JSON on stdin/stdout.
///
/// It is a relay with one job — let short-lived `amcu browser …` processes
/// reach the extension. It listens on a Unix socket, forwards each client
/// request to the extension with a fresh id, and writes the matching response
/// back. When the browser closes stdin the host removes its socket and exits.
///
/// Nothing but framed messages may ever go to stdout here: it is the wire.
public enum NativeHost {
    public static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let runtime = HostRuntime()
        runtime.start()
    }
}

private var globalSocketPath: UnsafeMutablePointer<CChar>?

private func removeSocketAndExit(_ signalNumber: Int32) {
    if let path = globalSocketPath { unlink(path) }
    _exit(0)
}

final class HostRuntime {
    private final class Pending {
        let semaphore = DispatchSemaphore(value: 0)
        var response: [String: Any]?
    }

    private let stdoutLock = NSLock()
    private let stateLock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private var extensionVersion: String?
    private var extensionID: String?
    private var brands: [String] = []
    private let helloSemaphore = DispatchSemaphore(value: 0)
    private var helloSignalled = false
    private let startedAt = Date()
    private var browser = "browser"
    private var socketPath = ""
    private var listenFD: Int32 = -1

    func start() -> Never {
        let reader = Thread { self.stdinLoop() }
        reader.name = "amcu-host-stdin"
        reader.start()

        // The extension says hello right after connecting; its brand list is
        // the fallback for naming the socket when the parent process is
        // not recognisable.
        _ = helloSemaphore.wait(timeout: .now() + 2)
        browser = detectBrowser()

        do {
            try openSocket()
        } catch {
            log("cannot open socket: \(error)")
            exit(1)
        }

        signal(SIGTERM, removeSocketAndExit)
        signal(SIGINT, removeSocketAndExit)
        signal(SIGHUP, removeSocketAndExit)
        atexit { if let path = globalSocketPath { unlink(path) } }

        let pinger = Thread { self.pingLoop() }
        pinger.name = "amcu-host-ping"
        pinger.start()

        acceptLoop()
    }

    // MARK: - Browser identity

    private func detectBrowser() -> String {
        let parent = NSRunningApplication(processIdentifier: getppid())
        if let name = BrowserBridge.browserName(bundleID: parent?.bundleIdentifier) { return name }
        stateLock.lock(); let brandList = brands; stateLock.unlock()
        if let name = BrowserBridge.browserName(brands: brandList) { return name }
        if let executable = parent?.executableURL?.lastPathComponent.lowercased(), !executable.isEmpty {
            return executable.replacingOccurrences(of: " ", with: "-")
        }
        return "browser"
    }

    // MARK: - Socket

    private func openSocket() throws {
        let directory = BrowserBridge.socketDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        removeStaleSockets(in: directory)

        let url = BrowserBridge.socketURL(browser: browser, pid: getpid())
        socketPath = url.path
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AmcuError(.unsupported, "socket() failed: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw AmcuError(.unsupported, "socket path too long: \(socketPath)")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (index, byte) in pathBytes.enumerated() { dest[index] = byte }
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else { throw AmcuError(.unsupported, "bind() failed: \(String(cString: strerror(errno)))") }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else { throw AmcuError(.unsupported, "listen() failed: \(String(cString: strerror(errno)))") }
        listenFD = fd
        globalSocketPath = strdup(socketPath)
    }

    /// A host that was killed outright leaves its socket file behind; a
    /// socket whose pid is gone is safe to remove.
    private func removeStaleSockets(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            guard let parsed = BrowserBridge.parseSocketName(name) else { continue }
            if kill(parsed.pid, 0) != 0 && errno == ESRCH {
                unlink(directory.appendingPathComponent(name).path)
            }
        }
    }

    private func acceptLoop() -> Never {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                log("accept() failed: \(String(cString: strerror(errno)))")
                sleep(1)
                continue
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let worker = Thread { self.serve(client: client) }
            worker.name = "amcu-host-client"
            worker.start()
        }
    }

    // MARK: - Client sessions (newline-delimited JSON)

    private func serve(client fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { return }
            buffer.append(chunk, count: count)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: 0..<newline)
                buffer.removeSubrange(0...newline)
                guard !line.isEmpty else { continue }
                let response = handle(clientLine: line)
                guard writeAll(fd, response + Data([0x0A])) else { return }
            }
        }
    }

    private func handle(clientLine line: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return encode(["ok": false, "error": ["code": "invalid_argument", "message": "malformed request", "nextSteps": []]])
        }
        let id = object["id"] ?? NSNull()
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]
        let timeoutMs = (object["timeoutMs"] as? Int) ?? 30_000

        if method == "hello" {
            return encode(["id": id, "ok": true, "result": hostInfo()])
        }

        let response = forward(method: method, params: params, timeoutMs: timeoutMs)
        var payload = response
        payload["id"] = id
        return encode(payload)
    }

    private func hostInfo() -> [String: Any] {
        stateLock.lock(); defer { stateLock.unlock() }
        return [
            "browser": browser,
            "pid": Int(getpid()),
            "hostVersion": AmcuVersion.string,
            "extensionVersion": extensionVersion ?? NSNull(),
            "extensionId": extensionID ?? NSNull(),
            "brands": brands,
            "since": ISO8601DateFormatter().string(from: startedAt),
            "socket": socketPath
        ]
    }

    /// Sends one request to the extension and blocks until its response or a
    /// timeout. Late responses are dropped.
    private func forward(method: String, params: [String: Any], timeoutMs: Int) -> [String: Any] {
        let pendingRequest = Pending()
        stateLock.lock()
        let id = nextID
        nextID += 1
        pending[id] = pendingRequest
        stateLock.unlock()

        let message: [String: Any] = ["type": "request", "id": id, "method": method, "params": params]
        do {
            try writeToExtension(message)
        } catch {
            stateLock.lock(); pending[id] = nil; stateLock.unlock()
            return ["ok": false, "error": ["code": "bridge_unavailable", "message": "could not reach the extension: \(error)", "nextSteps": ["Run `amcu browser doctor`."]]]
        }

        let limit = min(max(timeoutMs, 1_000), 600_000) + 2_000
        let outcome = pendingRequest.semaphore.wait(timeout: .now() + .milliseconds(limit))
        stateLock.lock(); pending[id] = nil; stateLock.unlock()
        guard outcome == .success, let response = pendingRequest.response else {
            return ["ok": false, "error": [
                "code": "timeout",
                "message": "the extension did not answer '\(method)' within \(limit / 1000)s",
                "nextSteps": [
                    "The page may be blocked by a modal dialog (`amcu browser dialog --accept`) or the extension may have been reloaded; retry once.",
                    "Run `amcu browser doctor` if it keeps happening."
                ]
            ]]
        }
        return response
    }

    // MARK: - Extension side

    private func writeToExtension(_ object: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: object)
        guard json.count <= BrowserBridge.maxOutboundMessage else {
            throw AmcuError(.invalidArgument, "request is \(json.count) bytes; the browser accepts at most \(BrowserBridge.maxOutboundMessage)")
        }
        let framed = BrowserBridge.frame(json)
        stdoutLock.lock(); defer { stdoutLock.unlock() }
        guard writeAll(1, framed) else {
            throw AmcuError(.bridgeUnavailable, "stdout closed")
        }
    }

    private func stdinLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(0, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            buffer.append(chunk, count: count)
            for message in BrowserBridge.unframe(&buffer) { dispatch(message) }
        }
        // The browser closed the pipe: the extension is gone or the browser quit.
        if let path = globalSocketPath { unlink(path) } else if !socketPath.isEmpty { unlink(socketPath) }
        exit(0)
    }

    private func dispatch(_ message: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "hello":
            stateLock.lock()
            extensionVersion = object["version"] as? String
            extensionID = object["extensionId"] as? String
            brands = object["brands"] as? [String] ?? []
            let signalled = helloSignalled
            helloSignalled = true
            stateLock.unlock()
            if !signalled { helloSemaphore.signal() }
        case "response":
            guard let id = object["id"] as? Int else { return }
            stateLock.lock()
            let target = pending[id]
            stateLock.unlock()
            guard let target else { return }
            var payload: [String: Any] = ["ok": object["ok"] as? Bool ?? false]
            if let result = object["result"] { payload["result"] = result }
            if let error = object["error"] { payload["error"] = error }
            target.response = payload
            target.semaphore.signal()
        case "pong":
            break
        default:
            break
        }
    }

    /// A message every 20 s keeps the extension's service worker from being
    /// idle-terminated (each received message resets its clock).
    private func pingLoop() {
        while true {
            sleep(20)
            try? writeToExtension(["type": "ping"])
        }
    }

    // MARK: - Helpers

    private func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"ok\":false}".utf8)
    }

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { pointer -> Int in
                write(fd, pointer.baseAddress! + offset, bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("amcu host: \(message)\n".utf8))
    }
}
