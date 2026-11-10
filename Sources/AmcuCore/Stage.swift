import AppKit
import CoreGraphics
import Foundation

/// The stage: a virtual display amcu adds off the corner of the user's
/// screen, so the windows an agent drives are fully drawn and current without
/// ever being in front of the user. A small holder process (`amcu stage
/// hold`) keeps the display — it exists only while that process lives — and
/// a resident host (`amcu stage serve`) does everything else: the stage app
/// in the Dock and its tabbed window, the cursor guard, moving windows. A new host can take
/// over a display that stays, so upgrading amcu never drops the windows on
/// the user's screen. Every other amcu process finds the display by its
/// identity and talks to the host over a Unix socket.
public enum Stage {
    /// `AMCU_STAGE_DIR` and `AMCU_STAGE_SERIAL` give a test a stage of its
    /// own beside the user's: its own files, its own display.
    private static let environment = ProcessInfo.processInfo.environment

    public static let identity = VirtualDisplay.Identity(name: "amcu stage", vendorID: 0x616D, productID: 0x6375, serial: environment["AMCU_STAGE_SERIAL"].flatMap(UInt32.init) ?? 1)

    /// An empty stage removes itself after this long.
    public static let idleExit: TimeInterval = 15 * 60

    static var cacheDirectory: URL {
        if let directory = environment["AMCU_STAGE_DIR"], !directory.isEmpty { return URL(fileURLWithPath: directory, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/amcu", isDirectory: true)
    }

    public static var socketURL: URL { cacheDirectory.appendingPathComponent("stage.sock") }
    /// What the user has taken over, written by the host whenever it changes,
    /// so every amcu process can check it without a round trip.
    public static var takeoversURL: URL { cacheDirectory.appendingPathComponent("stage-takeovers.json") }
    static var lockURL: URL { cacheDirectory.appendingPathComponent("stage.lock") }
    /// The host runs from its own copy of the binary. replayd tells its
    /// clients apart by executable path: while the host held capture
    /// streams, `amcu screenshot` run from the very same path hung in
    /// replayd (4 of 5 runs, and on after the streams stopped), while a copy
    /// anywhere else, even beside it, did not.
    static var hostExecutableURL: URL { StageBundle.executableURL }
    /// The display holder's record: its pid and display.
    public static var holderURL: URL { cacheDirectory.appendingPathComponent("stage-display.json") }
    static var holderExecutableURL: URL { cacheDirectory.appendingPathComponent("stage-display/amcu") }
    /// What a host knows that the display does not — where put windows came
    /// from, what is followed and held, what agents did — for the host that
    /// takes over the display next.
    static var stateURL: URL { cacheDirectory.appendingPathComponent("stage-state.json") }
    public static var logURL: URL {
        if environment["AMCU_STAGE_DIR"]?.isEmpty == false { return cacheDirectory.appendingPathComponent("stage.log") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/amcu/stage.log")
    }

    /// Online, not active: while the displays sleep (the user away five
    /// minutes) the active list is empty, and a stage looked up there was
    /// "gone" — a new host then tried to make a second display with the same
    /// identity, which the system refused.
    public static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// The stage display, if one is up.
    public static func display() -> (id: CGDirectDisplayID, bounds: CGRect)? {
        onlineDisplays().first(where: identity.matches).map { ($0, CGDisplayBounds($0)) }
    }

    /// Bounds of every display except the stage.
    public static func userDisplays() -> [CGRect] {
        onlineDisplays().filter { !identity.matches($0) }.map(CGDisplayBounds)
    }

    public static func isOnStage(_ frame: CGRect) -> Bool {
        guard let stage = display() else { return false }
        return StageGeometry.isOnStage(frame, stage: stage.bounds)
    }

    /// What the user holds right now; empty when no stage host is running
    /// (a file left behind by a host that died holds nothing).
    public static func takeovers() -> [StageTakeover] {
        guard let data = try? Data(contentsOf: takeoversURL),
              let file = try? StageWire.decoder().decode(StageTakeoverFile.self, from: data),
              !file.takeovers.isEmpty, kill(file.hostPID, 0) == 0, StageClient.isRunning() else { return [] }
        return file.takeovers
    }

    /// An acting verb about to touch a window the user took over hands it
    /// back to the stage first: the user's rule is that amcu acting means
    /// amcu wants the window back. Without `windowID` the verb goes to the
    /// application's focused window. Other windows of the application are not
    /// locked. Returns whether a window moved, so the caller reads its frame
    /// again.
    @discardableResult
    public static func handBackBeforeActing(pid: pid_t, windowID: CGWindowID?, session: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: takeoversURL.path) else { return false }
        let held = takeovers().filter { $0.pid == pid }
        guard !held.isEmpty, let target = windowID ?? focusedWindowID(pid: pid),
              let window = held.first(where: { $0.windowID == target }) else { return false }
        let reply: StageReply
        do {
            reply = try StageClient.request("handback", StageParams(windowIDs: [window.windowID], by: session), timeout: 10)
        } catch let error as AmcuError {
            throw takenOverError(window, reason: error.message)
        }
        guard let move = reply.moves.first, move.ok else {
            throw takenOverError(window, reason: reply.moves.first?.note ?? "the stage did not move it")
        }
        return true
    }

    /// The application with keyboard focus now, from the accessibility
    /// server: NSWorkspace lags, and in a command that does not run its
    /// run loop it does not update at all.
    public static func focusedApplicationPID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        AX.setMessagingTimeout(systemWide, seconds: 0.5)
        guard let app = AX.element(systemWide, kAXFocusedApplicationAttribute as String) else { return nil }
        return AX.pid(app)
    }

    /// The window an application's keystrokes go to.
    public static func focusedWindowID(pid: pid_t) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        AX.setMessagingTimeout(app, seconds: 0.5)
        guard let window = AX.element(app, kAXFocusedWindowAttribute as String) else { return nil }
        return AX.windowID(window)
    }

    /// A window's frame from the window server, wherever it is.
    public static func windowFrame(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let entry = list.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == id }),
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    /// The browser process whose windows a bridge connection drives — what a
    /// taken-over browser window is recorded under. Chrome and its relatives
    /// start the native host as a child of the browser process; the Safari
    /// relay is amcu's own, so Safari is found by its bundle id.
    public static func browserPID(for endpoint: BrowserEndpoint) -> pid_t? {
        if endpoint.browser == SafariBridge.browserName {
            return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first?.processIdentifier
        }
        return parentPID(of: endpoint.pid)
    }

    public static var screenIsLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static func isAmcu(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent == "amcu"
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    public static func takenOverError(_ held: StageTakeover, reason: String) -> AmcuError {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let window = held.title.map { " (window \"\($0)\")" } ?? ""
        return AmcuError(.takenOver, "the user took over \(held.app)\(window) from the stage at \(formatter.string(from: held.since)), and handing it back to the stage before acting failed: \(reason)", nextSteps: [
            "Ask the user to press \"hand back\" in the stage window, or wait; `amcu stage status` shows what is still taken over.",
            "Reading still works (snapshot, scan, screenshot)."
        ])
    }

    /// Seconds since the user last touched the keyboard, mouse or trackpad.
    /// Events amcu posts to a process do not count: they bypass the HID system.
    public static func secondsSinceUserInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Starts a process in a session of its own, so it outlives the command
    /// and the shell that ran it, with stderr going to the stage log.
    /// Responsibility is inherited, not disclaimed: it acts with the same
    /// permissions as the process that started it.
    static func spawnDetached(_ arguments: [String]) throws -> pid_t {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Nothing but the three descriptors above: a holder that inherited
        // the host's lock file kept the lock after the host left, and the
        // next host could not start.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, environ)
        guard status == 0 else {
            throw AmcuError(.stageUnavailable, "could not start \(arguments.dropFirst().prefix(2).joined(separator: " ")): \(String(cString: strerror(status)))")
        }
        return pid
    }

    /// A fresh copy of `source` (this binary unless given) at `target` — a
    /// clone on APFS, signature included — swapped in atomically, so a
    /// process still running from the old copy keeps its file.
    static func cloneExecutable(from source: URL = URL(fileURLWithPath: Responsibility.executablePath).resolvingSymlinksInPath(), to target: URL) throws -> String {
        guard source.path != target.path else { return source.path }
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = target.deletingLastPathComponent().appendingPathComponent(".amcu-\(getpid())")
        try? manager.removeItem(at: staging)
        do {
            try manager.copyItem(at: source, to: staging)
        } catch {
            throw AmcuError(.stageUnavailable, "could not copy \(source.path) to \(target.path) for the stage: \(error.localizedDescription)")
        }
        guard rename(staging.path, target.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? manager.removeItem(at: staging)
            throw AmcuError(.stageUnavailable, "could not put the stage's copy of amcu in place at \(target.path): \(reason)")
        }
        return target.path
    }

    /// A pointer that moves the user's cursor would have to cross onto a
    /// display they cannot see, where the cursor guard pulls it straight back.
    public static func refuseForegroundPointer(at point: CGPoint) throws {
        guard let stage = display(), stage.bounds.contains(point) else { return }
        throw AmcuError(.unsupported, "--mode foreground would move the user's cursor onto the stage, a display they cannot see (and the cursor guard pulls it straight back)", nextSteps: [
            "Leave --mode at auto: background delivery works on windows on the stage.",
            "If only a real cursor will do, bring the window back first with `amcu stage release --app <selector>`, and ask the user before taking their cursor."
        ])
    }
}

/// A window on the stage, as the host reports it.
public struct StageWindow: Codable, Sendable {
    public enum Origin: String, Codable, Sendable {
        /// Moved by `amcu stage put`.
        case put
        /// Opened later by an application being followed, and moved over.
        case followed
        /// On the stage but not moved there by amcu.
        case found
    }

    public let windowID: UInt32
    public let pid: Int32
    public let app: String
    public let bundleID: String?
    public let title: String?
    public let frame: FrameJSON
    /// Where it came from, and where `release` puts it back.
    public let home: FrameJSON?
    public let origin: Origin
}

/// One window moved onto or off the stage.
public struct StageMove: Codable, Sendable {
    public let windowID: UInt32
    public let app: String
    public let title: String?
    public let from: FrameJSON?
    public let to: FrameJSON?
    public let ok: Bool
    public let note: String?

    public init(windowID: UInt32, app: String, title: String?, from: FrameJSON?, to: FrameJSON?, ok: Bool, note: String?) {
        self.windowID = windowID
        self.app = app
        self.title = title
        self.from = from
        self.to = to
        self.ok = ok
        self.note = note
    }
}

/// A window the user took off the stage to work in.
public struct StageTakeover: Codable, Sendable {
    public let windowID: UInt32
    public let pid: Int32
    public let app: String
    public let bundleID: String?
    public let title: String?
    public let since: Date
    /// Where it was on the stage; hand-back puts it there again.
    public let stageFrame: FrameJSON
}

struct StageTakeoverFile: Codable {
    let hostPID: Int32
    let takeovers: [StageTakeover]
}

public struct StageFollow: Codable, Sendable {
    public let pid: Int32
    public let app: String
    public let bundleID: String?
}

public struct StageAsk: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        case open, done
        case handedBack = "handed-back"
        case released, gone, cancelled
    }

    public let id: Int
    public let session: String
    public let text: String
    public let pid: Int32
    public let windowID: UInt32
    public let at: Date
    public var state: State
    public var endedAt: Date?

    public init(id: Int, session: String, text: String, pid: Int32, windowID: UInt32, at: Date = Date(), state: State = .open, endedAt: Date? = nil) {
        self.id = id
        self.session = session
        self.text = text
        self.pid = pid
        self.windowID = windowID
        self.at = at
        self.state = state
        self.endedAt = endedAt
    }

    public var isOpen: Bool { state == .open }
}

public struct StageStatus: Codable, Sendable {
    public let version: String
    public let hostPID: Int32
    public let displayID: UInt32
    public let bounds: FrameJSON
    public let scale: Int
    public let contact: StageGeometry.Contact
    public let since: Date
    /// The process TCC attributes the host's permission checks to.
    public let answersFor: String?
    public let accessibility: Bool
    public let screenRecording: Bool
    public let cursorPullbacks: Int
    public let windows: [StageWindow]
    /// Windows the user took off the stage; their applications are left
    /// alone until handed back.
    public let takenOver: [StageTakeover]
    public let following: [StageFollow]
    /// Recent events worth knowing about, oldest first.
    public let notes: [String]
    /// What agents did to windows on the stage lately, oldest first.
    public let activity: [StageActivity]
    /// The process that keeps the display, when it is not the host itself.
    public let holderPID: Int32?
    public let asks: [StageAsk]

    public init(version: String, hostPID: Int32, displayID: UInt32, bounds: FrameJSON, scale: Int, contact: StageGeometry.Contact, since: Date, answersFor: String?, accessibility: Bool, screenRecording: Bool, cursorPullbacks: Int, windows: [StageWindow], takenOver: [StageTakeover], following: [StageFollow], notes: [String], activity: [StageActivity] = [], holderPID: Int32? = nil, asks: [StageAsk] = []) {
        self.version = version
        self.hostPID = hostPID
        self.displayID = displayID
        self.bounds = bounds
        self.scale = scale
        self.contact = contact
        self.since = since
        self.answersFor = answersFor
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.cursorPullbacks = cursorPullbacks
        self.windows = windows
        self.takenOver = takenOver
        self.following = following
        self.notes = notes
        self.activity = activity
        self.holderPID = holderPID
        self.asks = asks
    }

    /// A host started by an older amcu keeps running across an upgrade, so
    /// fields added later decode as empty rather than failing the command.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        hostPID = try c.decode(Int32.self, forKey: .hostPID)
        displayID = try c.decode(UInt32.self, forKey: .displayID)
        bounds = try c.decode(FrameJSON.self, forKey: .bounds)
        scale = try c.decode(Int.self, forKey: .scale)
        contact = try c.decode(StageGeometry.Contact.self, forKey: .contact)
        since = try c.decode(Date.self, forKey: .since)
        answersFor = try c.decodeIfPresent(String.self, forKey: .answersFor)
        accessibility = try c.decode(Bool.self, forKey: .accessibility)
        screenRecording = try c.decode(Bool.self, forKey: .screenRecording)
        cursorPullbacks = try c.decode(Int.self, forKey: .cursorPullbacks)
        windows = try c.decode([StageWindow].self, forKey: .windows)
        takenOver = try c.decodeIfPresent([StageTakeover].self, forKey: .takenOver) ?? []
        following = try c.decodeIfPresent([StageFollow].self, forKey: .following) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        activity = try c.decodeIfPresent([StageActivity].self, forKey: .activity) ?? []
        holderPID = try c.decodeIfPresent(Int32.self, forKey: .holderPID)
        asks = try c.decodeIfPresent([StageAsk].self, forKey: .asks) ?? []
    }
}

public struct StageReply: Codable, Sendable {
    public let status: StageStatus
    public let moves: [StageMove]
    public var ask: StageAsk? = nil
}

public struct StageParams: Codable, Sendable {
    public var pid: Int32?
    public var windowIDs: [UInt32]?
    public var follow: Bool?
    public var activate: Bool?
    /// The session on whose behalf, for what the stage window shows.
    public var by: String?
    public var activity: StageActivity?
    public var text: String?
    public var ask: Int?

    public init(pid: Int32? = nil, windowIDs: [UInt32]? = nil, follow: Bool? = nil, activate: Bool? = nil, by: String? = nil, activity: StageActivity? = nil, text: String? = nil, ask: Int? = nil) {
        self.pid = pid
        self.windowIDs = windowIDs
        self.follow = follow
        self.activate = activate
        self.by = by
        self.activity = activity
        self.text = text
        self.ask = ask
    }
}

struct StageRequest: Codable {
    let id: Int
    let method: String
    let params: StageParams
}

struct StageWireError: Codable {
    let code: String
    let message: String
    let nextSteps: [String]
}

struct StageResponse: Codable {
    let id: Int
    let ok: Bool
    let result: StageReply?
    let error: StageWireError?
}

enum StageWire {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func writeLine<T: Encodable>(_ fd: Int32, _ value: T) -> Bool {
        guard var data = try? encoder().encode(value) else { return false }
        data.append(0x0A)
        return RelaySockets.writeAll(fd, data)
    }
}

/// The CLI side: find the host, start it, ask it things.
public enum StageClient {
    public static func isRunning() -> Bool {
        guard let fd = RelaySockets.connectUnix(path: Stage.socketURL.path) else { return false }
        close(fd)
        return true
    }

    public static func request(_ method: String, _ params: StageParams = StageParams(), timeout: TimeInterval = 30) throws -> StageReply {
        guard let fd = RelaySockets.connectUnix(path: Stage.socketURL.path) else {
            throw AmcuError(.stageUnavailable, "no stage is running", nextSteps: [
                "`amcu stage put --app <selector>` starts one and moves a window onto it; `amcu stage start` starts an empty one."
            ])
        }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard StageWire.writeLine(fd, StageRequest(id: 1, method: method, params: params)) else {
            throw AmcuError(.stageUnavailable, "could not write to the stage host")
        }
        var buffer = Data()
        guard let line = RelaySockets.readLine(fd, buffer: &buffer, timeout: timeout) else {
            throw AmcuError(.timeout, "the stage host did not answer '\(method)' within \(Int(timeout))s", nextSteps: [
                "See \(Stage.logURL.path); `amcu stage stop` and a new `amcu stage start` replace a wedged host."
            ])
        }
        let response = try StageWire.decoder().decode(StageResponse.self, from: line)
        if response.ok, let result = response.result { return result }
        let error = response.error ?? StageWireError(code: "stage_unavailable", message: "the stage host answered without a result", nextSteps: [])
        throw AmcuError(AmcuError.Code(rawValue: error.code) ?? .stageUnavailable, error.message, nextSteps: error.nextSteps)
    }

    /// Starts the host unless one answers already, and waits for its display.
    /// Returns the host's status and whether this call started it.
    public static func start(pointSize: CGSize? = nil, scale: Int? = nil, wait: TimeInterval = 15) throws -> (reply: StageReply, started: Bool) {
        if isRunning() { return (try request("status"), false) }
        if let reason = VirtualDisplay.unavailableReason {
            throw AmcuError(.unsupported, "this macOS cannot create a virtual display: \(reason)", nextSteps: [
                "Work without the stage: windows on another desktop are still driven in the background."
            ])
        }
        let pid = try spawnHost(pointSize: pointSize, scale: scale)
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            usleep(150_000)
            if isRunning() { return (try request("status"), true) }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid || kill(pid, 0) != 0 {
                if isRunning() { return (try request("status"), false) }
                throw AmcuError(.stageUnavailable, "the stage host exited during start-up: \(lastLogLine() ?? "no log line")", nextSteps: [
                    "Read \(Stage.logURL.path) for the whole story."
                ])
            }
        }
        throw AmcuError(.timeout, "the stage did not come up within \(Int(wait))s", nextSteps: [
            "Read \(Stage.logURL.path); `amcu stage stop` cleans up a half-started host."
        ])
    }

    private static func spawnHost(pointSize: CGSize?, scale: Int?) throws -> pid_t {
        try FileManager.default.createDirectory(at: Stage.cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = URL(fileURLWithPath: Responsibility.executablePath).resolvingSymlinksInPath()
        let executable = try StageBundle.install(from: source)
        // The host watches the binary it was copied from and hands the stage
        // to a new copy when that changes, so an install takes effect.
        var arguments = [executable, "stage", "serve", "--source", source.path]
        if let pointSize { arguments += ["--size", "\(Int(pointSize.width))x\(Int(pointSize.height))"] }
        if let scale { arguments += ["--scale", String(scale)] }
        return try Stage.spawnDetached(arguments)
    }

    /// Tells the host what an acting verb just did. Never waits for an
    /// answer and never fails the verb: no stage, no report.
    public static func report(_ activity: StageActivity) {
        tell("activity", StageParams(activity: activity))
    }

    public static func note(_ text: String) {
        tell("note", StageParams(text: text))
    }

    private static func tell(_ method: String, _ params: StageParams) {
        guard let fd = RelaySockets.connectUnix(path: Stage.socketURL.path) else { return }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = StageWire.writeLine(fd, StageRequest(id: 1, method: method, params: params))
    }

    /// A new host from this binary takes over the running stage: the display
    /// and every window on it stay where they are. Returns the new host's
    /// status, or nil when the running host cannot hand over (it keeps the
    /// display itself, as amcu before 0.13 did).
    public static func handOver(wait: TimeInterval = 15) throws -> StageReply? {
        let before = try request("status")
        guard before.status.holderPID != nil else { return nil }
        _ = try request("handover", timeout: 10)
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline, kill(before.status.hostPID, 0) == 0 || isRunning() {
            usleep(100_000)
        }
        return try start().reply
    }

    static func lastLogLine() -> String? {
        guard let text = try? String(contentsOf: Stage.logURL, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last.map(String.init)
    }
}
