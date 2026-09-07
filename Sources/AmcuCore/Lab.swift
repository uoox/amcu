import Foundation

/// A disposable browser of amcu's own, with the DevTools protocol exposed.
///
/// `amcu browser` works inside the user's browser through an extension, and an
/// extension's `chrome.debugger` is fenced by design: it cannot attach to other
/// extensions, their service workers, or chrome:// pages, and it cannot trace,
/// profile or intercept at the browser level. Those are developer-tool jobs,
/// not computer-use jobs, and they need a Chrome started with a debugging port.
/// The lab is that Chrome: a throwaway profile, the port bound to localhost,
/// the amcu extension loaded when the binary allows it, and nothing shared with
/// the user's own browsing. Everything else is a raw protocol call.
public enum Lab {
    public struct State: Codable {
        public let name: String
        public let pid: Int32
        public let port: Int
        public let profile: String
        public let chrome: String
        public let extensionLoaded: Bool
        public let headless: Bool
        public let startedAt: Date
    }

    public struct Browser {
        public let path: String
        /// Branded Google Chrome dropped `--load-extension` in 137; Chrome for
        /// Testing and Chromium still honour it.
        public let loadsExtension: Bool
        public let label: String
    }

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/amcu/lab", isDirectory: true)
    }

    static func stateFile(_ name: String) -> URL { directory.appendingPathComponent("\(name).json") }
    static func profileDirectory(_ name: String) -> URL { directory.appendingPathComponent(name, isDirectory: true).appendingPathComponent("profile", isDirectory: true) }

    // MARK: - Finding a browser

    /// Candidates in order of preference. Chrome for Testing first because it
    /// loads the extension; branded Chrome last, extension-less, so the lab
    /// still works for network/performance jobs on a machine with nothing else.
    public static func findBrowser(explicit: String?) throws -> Browser {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let explicit = explicit ?? ProcessInfo.processInfo.environment["AMCU_LAB_CHROME"], !explicit.isEmpty {
            let path = executableInside(explicit)
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw AmcuError(.invalidArgument, "'\(explicit)' is not a browser executable or .app", nextSteps: [
                    "Pass --chrome with the .app bundle or the binary inside it."
                ])
            }
            let branded = path.contains("Google Chrome.app")
            return Browser(path: path, loadsExtension: !branded, label: explicit)
        }
        var candidates: [(String, Bool, String)] = [
            ("/Applications/Google Chrome for Testing.app", true, "Chrome for Testing"),
            ("\(home)/Applications/Google Chrome for Testing.app", true, "Chrome for Testing"),
        ]
        // Puppeteer / Playwright caches.
        for pattern in ["\(home)/.cache/puppeteer/chrome", "\(home)/Library/Caches/ms-playwright"] {
            if let entries = try? FileManager.default.subpathsOfDirectory(atPath: pattern) {
                for entry in entries.sorted().reversed() where entry.hasSuffix("Google Chrome for Testing.app") || entry.hasSuffix("Chromium.app") {
                    candidates.append(("\(pattern)/\(entry)", true, "cached \(entry.hasSuffix("Chromium.app") ? "Chromium" : "Chrome for Testing")"))
                }
            }
        }
        candidates += [
            ("/Applications/Chromium.app", true, "Chromium"),
            ("/Applications/Google Chrome.app", false, "Google Chrome (extension cannot be loaded)"),
        ]
        for (app, loads, label) in candidates {
            let path = executableInside(app)
            if FileManager.default.isExecutableFile(atPath: path) { return Browser(path: path, loadsExtension: loads, label: label) }
        }
        throw AmcuError(.unsupported, "no Chromium-based browser found for the lab", nextSteps: [
            "Install Chrome for Testing (`npx @puppeteer/browsers install chrome@stable`) or pass --chrome /path/to/Chromium.app.",
            "Branded Google Chrome works for network and performance jobs but cannot load the amcu extension."
        ])
    }

    public static func executableInside(_ path: String) -> String {
        guard path.hasSuffix(".app") else { return path }
        let macOS = "\(path)/Contents/MacOS"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: macOS), let first = names.sorted().first {
            return "\(macOS)/\(first)"
        }
        return path
    }

    // MARK: - Lifecycle

    public static func start(name: String, chrome explicit: String?, url: String?, port requested: Int?, headless: Bool) throws -> State {
        if let existing = status(name: name), existing.alive {
            throw AmcuError(.invalidArgument, "lab '\(name)' is already running (pid \(existing.state.pid), port \(existing.state.port))", nextSteps: [
                "Use it, or `amcu lab stop` first.",
                "A second lab needs its own --name."
            ])
        }
        let browser = try findBrowser(explicit: explicit)
        let port = try requested ?? freePort()
        let profile = profileDirectory(name)
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("NativeMessagingHosts"), withIntermediateDirectories: true)
        // The lab's own copy of the extension and a manifest inside the profile:
        // `amcu browser` then drives the lab browser like any other.
        let extensionDirectory = directory.appendingPathComponent(name, isDirectory: true).appendingPathComponent("extension", isDirectory: true)
        _ = try BrowserInstall.install(browsers: [], extensionDirectory: extensionDirectory, manifestDirectory: profile.appendingPathComponent("NativeMessagingHosts"))

        var arguments = [
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(profile.path)",
            "--no-first-run", "--no-default-browser-check",
            "--disable-features=ExtensionDisableUnsupportedDeveloper,TranslateUI",
            "--window-size=1200,900", "--window-position=40,40",
        ]
        if browser.loadsExtension { arguments.append("--load-extension=\(extensionDirectory.path)") }
        if headless { arguments.append("--headless=new") }
        arguments.append(url ?? "about:blank")

        let log = directory.appendingPathComponent(name, isDirectory: true).appendingPathComponent("chrome.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: browser.path)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        do { try process.run() } catch {
            throw AmcuError(.unsupported, "could not start \(browser.path): \(error.localizedDescription)")
        }

        // Ready when the debugging endpoint answers.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !process.isRunning {
                throw AmcuError(.unsupported, "the browser exited during startup (see \(log.path))", nextSteps: [
                    "A profile another browser instance holds open cannot be reused; `amcu lab stop` then start again."
                ])
            }
            if (try? fetch(port: port, path: "/json/version")) != nil { break }
            usleep(200_000)
        }
        guard (try? fetch(port: port, path: "/json/version")) != nil else {
            process.terminate()
            throw AmcuError(.timeout, "the browser started but port \(port) never answered", nextSteps: ["See \(log.path)."])
        }
        let state = State(name: name, pid: process.processIdentifier, port: port, profile: profile.path, chrome: browser.path,
                          extensionLoaded: browser.loadsExtension, headless: headless, startedAt: Date())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateFile(name), options: .atomic)
        return state
    }

    public struct Status { public let state: State; public let alive: Bool }

    public static func status(name: String) -> Status? {
        guard let data = try? Data(contentsOf: stateFile(name)), let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }
        return Status(state: state, alive: kill(state.pid, 0) == 0)
    }

    public static func all() -> [Status] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.compactMap { status(name: String($0.dropLast(5))) }
    }

    public static func stop(name: String, keepProfile: Bool) throws -> State? {
        guard let found = status(name: name) else { return nil }
        if found.alive {
            kill(found.state.pid, SIGTERM)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, kill(found.state.pid, 0) == 0 { usleep(100_000) }
            if kill(found.state.pid, 0) == 0 { kill(found.state.pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: stateFile(name))
        if !keepProfile { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name, isDirectory: true)) }
        return found.state
    }

    public static func running(name: String) throws -> State {
        guard let found = status(name: name), found.alive else {
            throw AmcuError(.bridgeUnavailable, "lab '\(name)' is not running", nextSteps: ["`amcu lab start` first."])
        }
        return found.state
    }

    // MARK: - DevTools protocol

    public static func targets(port: Int) throws -> [[String: Any]] {
        let data = try fetch(port: port, path: "/json/list")
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    /// Methods that belong to the browser endpoint rather than a page. Anything
    /// else goes to a page target.
    public static func isBrowserLevel(_ method: String) -> Bool {
        ["Browser.", "Target.", "SystemInfo.", "Tethering.", "Storage.", "Memory."].contains { method.hasPrefix($0) }
    }

    /// One request, one reply. Events that arrive while waiting are dropped:
    /// the lab is a probe, not a session.
    public static func call(port: Int, method: String, params: [String: Any], target: String?, timeout: TimeInterval) throws -> Any {
        let socketURL: String
        if let target {
            let list = try targets(port: port)
            guard let match = list.first(where: { ($0["id"] as? String)?.hasPrefix(target) == true || ($0["url"] as? String)?.contains(target) == true }),
                  let url = match["webSocketDebuggerUrl"] as? String else {
                throw AmcuError(.elementNotFound, "no target matches '\(target)'", nextSteps: ["`amcu lab targets` lists ids and urls; a prefix of the id or a substring of the url selects one."])
            }
            socketURL = url
        } else if isBrowserLevel(method) {
            let version = (try? JSONSerialization.jsonObject(with: try fetch(port: port, path: "/json/version"))) as? [String: Any]
            guard let url = version?["webSocketDebuggerUrl"] as? String else { throw AmcuError(.bridgeUnavailable, "the browser endpoint did not report a socket") }
            socketURL = url
        } else {
            let list = try targets(port: port)
            guard let page = list.first(where: { ($0["type"] as? String) == "page" }), let url = page["webSocketDebuggerUrl"] as? String else {
                throw AmcuError(.elementNotFound, "the lab has no page target", nextSteps: ["Open one: `amcu lab cdp --method Target.createTarget --params '{\"url\":\"https://…\"}'`."])
            }
            socketURL = url
        }
        guard let url = URL(string: socketURL) else { throw AmcuError(.bridgeUnavailable, "bad socket url \(socketURL)") }

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 256 * 1024 * 1024
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }

        let request: [String: Any] = ["id": 1, "method": method, "params": params]
        let payload = try JSONSerialization.data(withJSONObject: request)
        var sendError: Error?
        let sent = DispatchSemaphore(value: 0)
        task.send(.string(String(decoding: payload, as: UTF8.self))) { sendError = $0; sent.signal() }
        guard sent.wait(timeout: .now() + timeout) == .success else { throw AmcuError(.timeout, "sending \(method) timed out") }
        if let sendError { throw AmcuError(.bridgeUnavailable, "could not reach the lab browser: \(sendError.localizedDescription)") }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var received: Result<URLSessionWebSocketTask.Message, Error>?
            let got = DispatchSemaphore(value: 0)
            task.receive { received = $0; got.signal() }
            guard got.wait(timeout: .now() + max(0.1, deadline.timeIntervalSinceNow)) == .success, let received else { break }
            let text: String
            switch received {
            case .success(.string(let string)): text = string
            case .success(.data(let data)): text = String(decoding: data, as: UTF8.self)
            case .success: continue
            case .failure(let error): throw AmcuError(.bridgeUnavailable, "the lab browser closed the connection: \(error.localizedDescription)")
            }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], (object["id"] as? Int) == 1 else { continue }
            if let error = object["error"] as? [String: Any] {
                throw AmcuError(.pageError, "\(method): \(error["message"] as? String ?? "error") (code \(error["code"] ?? 0))", nextSteps: [
                    "Method and parameter names follow the Chrome DevTools Protocol exactly (https://chromedevtools.github.io/devtools-protocol/)."
                ])
            }
            return object["result"] ?? [:]
        }
        throw AmcuError(.timeout, "\(method) did not answer within \(Int(timeout))s")
    }

    // MARK: - Helpers

    static func fetch(port: Int, path: String) throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw AmcuError(.invalidArgument, "bad path") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        var result: Result<Data, Error> = .failure(AmcuError(.timeout, "no answer from port \(port)"))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { result = .failure(error) }
            else if let data, (response as? HTTPURLResponse)?.statusCode == 200 { result = .success(data) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 4)
        return try result.get()
    }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AmcuError(.unsupported, "socket() failed") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw AmcuError(.unsupported, "could not find a free port") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
