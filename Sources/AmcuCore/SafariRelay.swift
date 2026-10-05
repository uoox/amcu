import Foundation

/// The relay process (`amcu browser safari-relay`, normally the copy of amcu
/// inside the container app). It listens on a Unix socket for the CLI —
/// same newline-JSON protocol and `hello` as the Chrome native host — and on
/// 127.0.0.1:<port> for the appex, which only gets requests after presenting
/// the install's token.
public enum SafariRelay {
    public static func run(config: SafariBridge.RelayConfig) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let runtime = SafariRelayRuntime(config: config)
        runtime.start()
    }

    /// The relay socket of a running relay, if one answers.
    public static func runningEndpoint() -> BrowserEndpoint? {
        BrowserClient.discover().first { $0.browser == SafariBridge.browserName }
    }

    /// Starts the relay from the installed container app and waits for its
    /// socket. Detached in its own session so it outlives this process and
    /// the shell that ran it.
    @discardableResult
    public static func ensureRunning(appURL: URL = SafariInstall.appURL, wait: TimeInterval = 3) throws -> BrowserEndpoint {
        if let endpoint = runningEndpoint() { return endpoint }
        let executable = SafariInstall.appExecutableURL(appURL).path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw AmcuError(.bridgeUnavailable, "the Safari bridge is not installed (\(appURL.path) is missing)", nextSteps: [
                "Run `amcu browser install --browser safari`, then follow the one-time steps it prints."
            ])
        }
        try FileManager.default.createDirectory(at: SafariInstall.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, SafariInstall.logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), strdup("browser"), strdup("safari-relay"), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        guard status == 0 else {
            throw AmcuError(.bridgeUnavailable, "could not start the Safari relay: \(String(cString: strerror(status)))", nextSteps: [
                "Run `amcu browser doctor --browser safari`; the relay log is \(SafariInstall.logURL.path)."
            ])
        }
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            usleep(100_000)
            if let endpoint = runningEndpoint() { return endpoint }
        }
        throw AmcuError(.bridgeUnavailable, "the Safari relay did not come up within \(Int(wait))s", nextSteps: [
            "See \(SafariInstall.logURL.path) for why; re-running `amcu browser install --browser safari` repairs a broken install."
        ])
    }
}

final class SafariRelayRuntime {
    private let config: SafariBridge.RelayConfig
    private let core = SafariRelayCore()
    private let startedAt = Date()
    private var socketPath = ""
    private let activityLock = NSLock()
    private var lastClientActivity = Date()

    init(config: SafariBridge.RelayConfig) {
        self.config = config
    }

    func start() -> Never {
        let unixFD: Int32
        let tcpFD: Int32
        do {
            tcpFD = try RelaySockets.listenLoopback(port: config.port)
            unixFD = try openUnixSocket()
        } catch {
            log("cannot start: \(error)")
            exit(1)
        }
        relaySocketPathForCleanup = strdup(socketPath)
        signal(SIGTERM, relayRemoveSocketAndExit)
        signal(SIGINT, relayRemoveSocketAndExit)
        signal(SIGHUP, relayRemoveSocketAndExit)
        log("listening on \(socketPath) and 127.0.0.1:\(config.port)")

        let tcp = Thread { self.acceptLoop(tcpFD) { self.serveExtension($0) } }
        tcp.name = "amcu-relay-appex"
        tcp.start()
        let idle = Thread { self.idleLoop() }
        idle.name = "amcu-relay-idle"
        idle.start()
        acceptLoop(unixFD) { self.serveClient($0) }
    }

    private func openUnixSocket() throws -> Int32 {
        let directory = BrowserBridge.socketDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Only one relay may serve Safari; a second one would split the polls.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names {
                guard let parsed = BrowserBridge.parseSocketName(name), parsed.browser == SafariBridge.browserName else { continue }
                if parsed.pid != getpid() && kill(parsed.pid, 0) == 0 {
                    throw AmcuError(.unsupported, "another Safari relay is running (pid \(parsed.pid))")
                }
                unlink(directory.appendingPathComponent(name).path)
            }
        }
        socketPath = BrowserBridge.socketURL(browser: SafariBridge.browserName, pid: getpid()).path
        return try RelaySockets.listenUnix(path: socketPath)
    }

    private func acceptLoop(_ fd: Int32, _ handler: @escaping (Int32) -> Void) -> Never {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                sleep(1)
                continue
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let worker = Thread { handler(client) }
            worker.start()
        }
    }

    private func idleLoop() {
        while true {
            sleep(60)
            activityLock.lock()
            let idle = Date().timeIntervalSince(lastClientActivity)
            activityLock.unlock()
            if idle > SafariBridge.relayIdleExit {
                log("no CLI request for \(Int(idle))s; exiting (the next --browser safari command restarts the relay)")
                unlink(socketPath)
                exit(0)
            }
        }
    }

    // MARK: CLI clients

    private func serveClient(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        while let line = RelaySockets.readLine(fd, buffer: &buffer, timeout: 0) {
            activityLock.lock(); lastClientActivity = Date(); activityLock.unlock()
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                _ = RelaySockets.writeLine(fd, SafariRelayCore.failure("invalid_argument", "malformed request", []))
                continue
            }
            let id = object["id"] ?? NSNull()
            let method = object["method"] as? String ?? ""
            let params = object["params"] as? [String: Any] ?? [:]
            let timeoutMs = (object["timeoutMs"] as? Int) ?? 30_000
            var reply: [String: Any]
            if method == "hello" {
                reply = ["ok": true, "result": hostInfo()]
            } else if let refusal = SafariBridge.unsupportedError(method: method) {
                reply = SafariRelayCore.failure(refusal.code.rawValue, refusal.message, refusal.nextSteps)
            } else {
                reply = core.submit(method: method, params: params, timeout: Double(min(max(timeoutMs, 1_000), 600_000)) / 1000)
            }
            reply["id"] = id
            guard RelaySockets.writeLine(fd, reply) else { return }
        }
    }

    private func hostInfo() -> [String: Any] {
        let info = core.extensionInfo
        let formatter = ISO8601DateFormatter()
        return [
            "browser": SafariBridge.browserName,
            "pid": Int(getpid()),
            "hostVersion": AmcuVersion.string,
            "extensionVersion": info.version ?? NSNull(),
            "extensionId": SafariBridge.extensionBundleID,
            "brands": [String](),
            "since": formatter.string(from: startedAt),
            "socket": socketPath,
            "ready": core.isReady,
            "lastPoll": info.lastPoll.map { formatter.string(from: $0) } ?? NSNull(),
            "lastPollAgoSeconds": info.lastPoll.map { Int(Date().timeIntervalSince($0)) } ?? NSNull(),
            "hostAccess": info.hostAccess ?? NSNull(),
            "userAgent": info.userAgent ?? NSNull(),
            "profiles": core.profilesSeen.count,
            "relayPort": Int(config.port)
        ]
    }

    // MARK: The appex

    private func serveExtension(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        guard let line = RelaySockets.readLine(fd, buffer: &buffer, timeout: 10),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        // Anything without the token — a web page's fetch to this port, a
        // stray process — gets nothing back at all.
        guard SafariBridge.tokenMatches(object["token"] as? String, config.token) else { return }
        let message = object["message"] as? [String: Any] ?? [:]
        switch message["type"] as? String {
        case "poll":
            guard core.notePoll(message) else {
                _ = RelaySockets.writeLine(fd, ["type": "idle", "reason": "another Safari profile is being driven"])
                return
            }
            let window = min(max((message["waitMs"] as? Double ?? SafariBridge.pollWindow * 1000) / 1000, 0), SafariBridge.pollWindow)
            guard let request = core.poll(window: window) else {
                _ = RelaySockets.writeLine(fd, ["type": "idle"])
                return
            }
            let payload: [String: Any] = ["type": "request", "id": request.id, "method": request.method, "params": request.params]
            if !RelaySockets.writeLine(fd, payload) { core.requeue(request) }
        case "response":
            guard let id = message["id"] as? Int else { return }
            let delivered = core.respond(id: id, payload: message)
            _ = RelaySockets.writeLine(fd, ["type": "ack", "delivered": delivered])
        default:
            _ = RelaySockets.writeLine(fd, ["type": "error", "message": "unknown message type"])
        }
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) amcu safari relay: \(message)\n".utf8))
    }
}

private var relaySocketPathForCleanup: UnsafeMutablePointer<CChar>?

private func relayRemoveSocketAndExit(_ signalNumber: Int32) {
    if let path = relaySocketPathForCleanup { unlink(path) }
    _exit(0)
}

/// Minimal blocking socket helpers shared by the relay and the appex.
enum RelaySockets {
    static func listenUnix(path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AmcuError(.unsupported, "socket() failed: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw AmcuError(.unsupported, "socket path too long: \(path)")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dest in
                for (index, byte) in bytes.enumerated() { dest[index] = byte }
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw AmcuError(.unsupported, "bind(\(path)) failed: \(reason)")
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); throw AmcuError(.unsupported, "listen() failed") }
        return fd
    }

    static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    static func listenLoopback(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AmcuError(.unsupported, "socket() failed") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = loopbackAddress(port: port)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw AmcuError(.unsupported, "cannot listen on 127.0.0.1:\(port): \(reason)", nextSteps: [
                "Another program holds that port; `amcu browser install --browser safari` picks a new one."
            ])
        }
        guard listen(fd, 16) == 0 else { close(fd); throw AmcuError(.unsupported, "listen() failed") }
        return fd
    }

    /// Whether a loopback port is free to bind right now.
    static func portIsFree(_ port: UInt16) -> Bool {
        guard let fd = try? listenLoopback(port: port) else { return false }
        close(fd)
        return true
    }

    static func connectLoopback(port: UInt16, timeout: TimeInterval) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var address = loopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }

    /// Reads one newline-terminated line. `timeout` 0 waits indefinitely.
    static func readLine(_ fd: Int32, buffer: inout Data, timeout: TimeInterval) -> Data? {
        if timeout > 0 {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        var scanned = 0
        while true {
            if let newline = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            scanned = buffer.count
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return nil }
            buffer.append(chunk, count: count)
        }
    }

    static func writeLine(_ fd: Int32, _ object: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(0x0A)
        return writeAll(fd, data)
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}
