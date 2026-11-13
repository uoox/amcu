import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The resident stage process (`amcu stage serve`): the stage app (a Dock
/// icon and its tabbed window), the cursor guard, moving windows on and off the stage,
/// following the windows staged applications open later, answering the CLI
/// over `Stage.socketURL`. The display itself is kept by a holder process
/// (`StageDisplayHolder`), so a new host — after an upgrade, or `amcu stage
/// restart` — takes it over with the windows still on it, and carries on
/// from the state the old one wrote (`Stage.stateURL`). Started detached by
/// `StageClient.start`; it inherits the starting command's responsible
/// process, so it acts with the same Accessibility and Screen Recording
/// grants as that command.
public enum StageHost {
    public static func run(pointSize: CGSize?, scale: Int?, source: String?) -> Never {
        signal(SIGPIPE, SIG_IGN)
        if !StageBundle.isCurrentProcessInside { relaunchInsideBundle(pointSize: pointSize, scale: scale, source: source) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runtime = StageRuntime(pointSize: pointSize, scale: scale, source: source)
        stageRuntime = runtime
        app.delegate = runtime
        app.run()
        exit(0)
    }

    private static func relaunchInsideBundle(pointSize: CGSize?, scale: Int?, source: String?) {
        let origin = URL(fileURLWithPath: source ?? Responsibility.executablePath).resolvingSymlinksInPath()
        do {
            var arguments = [try StageBundle.install(from: origin), "stage", "serve"]
            if let source { arguments += ["--source", source] }
            if let pointSize { arguments += ["--size", "\(Int(pointSize.width))x\(Int(pointSize.height))"] }
            if let scale { arguments += ["--scale", String(scale)] }
            _ = try Stage.spawnDetached(arguments)
            exit(0)
        } catch {
            StageRuntime.log("could not start from the stage app at \(StageBundle.appURL.path) (\((error as? AmcuError)?.message ?? String(describing: error))); carrying on outside it")
        }
    }

    public static var isRunningAsApp: Bool { StageBundle.isCurrentProcessInside }

    public static func launchedFromFinder() -> Never {
        if StageClient.isRunning() {
            _ = try? StageClient.request("show", StageParams(activate: true))
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.applicationIconImage = StageIcon.image()
        app.activate()
        let alert = NSAlert()
        alert.messageText = StageText.t("The stage is not running", "舞台没有在运行")
        alert.informativeText = StageText.t(
            "It starts by itself when an agent puts a window on it (`amcu stage put`), and then shows up in the Dock with every window as a tab.",
            "agent 把窗口放上舞台（amcu stage put）时它会自己启动，出现在程序坞里，每个窗口一个标签。"
        )
        alert.addButton(withTitle: StageText.t("OK", "好"))
        alert.runModal()
        exit(0)
    }
}

private var stageRuntime: StageRuntime?

private func stageObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<StageRuntime>.fromOpaque(refcon).takeUnretainedValue().observed(notification as String, element: element)
}

final class StageRuntime: NSObject, NSApplicationDelegate {
    struct Record {
        let windowID: CGWindowID
        let pid: pid_t
        let app: String
        let bundleID: String?
        var title: String?
        /// Where the window was before it came to the stage; nil when it
        /// opened on the stage itself.
        let home: CGRect?
        let origin: StageWindow.Origin
        let element: AXUIElement
    }

    /// A window the user took off the stage to work in. Hand-back puts it
    /// where it was on the stage; an agent acting on it hands it back first.
    struct Takeover {
        let windowID: CGWindowID
        let pid: pid_t
        let app: String
        let bundleID: String?
        let title: String?
        let since: Date
        let stageFrame: CGRect
        let home: CGRect?
        let origin: StageWindow.Origin
        /// The application that had the keyboard before, given it back on
        /// hand-back if the taken-over one still has it.
        let previousFront: pid_t?
    }

    enum Placement {
        /// Where the window was before it came to the stage.
        case home
        /// So that the point the user clicked in the window's thumbnail
        /// rests under the cursor.
        case underCursor(grabbed: CGPoint, cursor: CGPoint)
    }

    struct Follower {
        let pid: pid_t
        let app: String
        let bundleID: String?
        let element: AXUIElement
        let observer: AXObserver
    }

    /// Kinds of new window that are moved after their application: documents,
    /// dialogs, panels. Help tags, drag images and the like are left alone.
    static let followedSubroles: Set<String> = ["AXStandardWindow", "AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow"]

    private let requestedSize: CGSize?
    private let requestedScale: Int?
    /// The binary this host was copied from; when it changes, a new host
    /// from it takes over.
    private let source: String?
    private var sourceStamp: FileStamp?
    private var pendingStamp: (stamp: FileStamp, since: Date)?
    /// Who keeps the display. Without one (no holder could start) the host
    /// keeps it in `ownDisplay`, and a restart cannot keep it.
    private var holder: StageDisplayHolder.Info?
    private var ownDisplay: VirtualDisplay?
    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var stageBounds: CGRect = .zero
    private var stageArea: CGRect = .zero
    private(set) var scale = 1
    private(set) var contact: StageGeometry.Contact = .apart
    private var userDisplays: [CGRect] = []
    private var records: [CGWindowID: Record] = [:]
    private var unresolved: [StageState.SavedRecord] = []
    private var promptsRefused: Set<String> = []
    private var followers: [pid_t: Follower] = [:]
    private var takeovers: [CGWindowID: Takeover] = [:]
    private(set) var pullbacks = 0
    private var notes: [String] = []
    /// When the stage came up, carried across hosts.
    private var since = Date()
    private let launched = Date()
    private(set) var activity: [StageActivity] = []
    private var activitySeq = 0
    private var asks: [StageAsk] = []
    private var askSeq = 0
    /// Which tabs are in which browser window on the stage, for placing a
    /// browser verb's activity; refreshed by the stage window and on demand.
    private var tabPairing: [CGWindowID: StageTabs.Paired] = [:]
    private var pairingTabs = false
    private var lastPersisted: Data?
    private var app: StageApp?
    private var monitors: [Any] = []
    private var timers: [Timer] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var lockFD: Int32 = -1
    private var listenFD: Int32 = -1
    private var emptySince: Date?
    private var stopping = false
    private var lastPlacement = Date.distantPast

    init(pointSize: CGSize?, scale: Int?, source: String?) {
        requestedSize = pointSize
        requestedScale = scale
        self.source = source
    }

    // MARK: - Start-up

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try takeLock()
        } catch {
            StageRuntime.log("another stage host holds \(Stage.lockURL.path); leaving it in charge")
            exit(0)
        }
        do {
            try attachDisplay()
        } catch {
            StageRuntime.log("cannot create the stage display: \(error)")
            exit(2)
        }
        // NSScreen learns about a new display a moment after CoreGraphics
        // does; the usable area below the stage's menu bar comes from NSScreen.
        waitForScreen(deadline: Date().addingTimeInterval(3)) { [weak self] in
            self?.finishStart()
        }
    }

    /// The lock is only held by a host that is running or on its way out
    /// (handing over, stopping): nobody asks for a new host while one
    /// answers. So waiting a little for it is right.
    private func takeLock(wait: TimeInterval = 10) throws {
        try FileManager.default.createDirectory(at: Stage.cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(Stage.lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AmcuError(.stageUnavailable, "cannot open \(Stage.lockURL.path)") }
        let deadline = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                close(fd)
                throw AmcuError(.stageUnavailable, "another stage host is running")
            }
            usleep(100_000)
        }
        lockFD = fd
    }

    /// Takes over the display a holder keeps, or has one made.
    private func attachDisplay() throws {
        if let kept = StageDisplayHolder.current() {
            holder = kept
            displayID = kept.displayID
            scale = kept.scale
            refreshDisplays()
            StageRuntime.log("taking over display \(displayID), kept by pid \(kept.pid) since \(ISO8601DateFormatter().string(from: kept.since))")
            return
        }
        // A display whose keeper just went takes a moment to disappear.
        let deadline = Date().addingTimeInterval(5)
        while Stage.display() != nil, Date() < deadline { usleep(100_000) }
        if let stray = Stage.display() {
            // Kept by a process with no record; making a second display with
            // the same identity would confuse every amcu process.
            displayID = stray.id
            scale = max(1, Int((CGDisplayCopyDisplayMode(stray.id).map { Double($0.pixelWidth) / Double(max(1, $0.width)) } ?? 1).rounded()))
            refreshDisplays()
            StageRuntime.log("display \(displayID) is up with no holder on record; using it as it is")
            return
        }
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let size = requestedSize ?? mainBounds.size
        let scale = requestedScale ?? Int(NSScreen.screens.first?.backingScaleFactor ?? 2)
        do {
            let started = try StageDisplayHolder.start(pointSize: size, scale: scale)
            holder = started
            displayID = started.displayID
        } catch {
            StageRuntime.log("no display holder (\(error)); keeping the display in the host, so a restart will not keep it")
            let display = try VirtualDisplay(identity: Stage.identity, pointSize: size, scale: scale) { [weak self] in
                self?.displayTerminated()
            }
            ownDisplay = display
            displayID = display.displayID
        }
        self.scale = scale >= 2 ? 2 : 1
        refreshDisplays()
        let corner = StageGeometry.cornerOrigin(of: userDisplays)
        if stageBounds.origin != corner {
            let wasEdge = contact == .edge
            place()
            if wasEdge {
                note("macOS first put the stage beside the user's screen; it is at the corner now (a Dock on that side may have flickered once — later starts in this login come up at the corner directly)")
            }
        }
    }

    /// Moves the stage to the corner for the whole login session, not just
    /// this process: WindowServer then brings the same display up at the
    /// corner directly next time, instead of beside the main display first
    /// (measured on 27.2: there, a right-hand Dock jumped onto it for most of
    /// a second until it was moved).
    private func place() {
        lastPlacement = Date()
        let corner = StageGeometry.cornerOrigin(of: userDisplays)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayOrigin(config, displayID, Int32(corner.x), Int32(corner.y))
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result != .success { StageRuntime.log("placing the stage at \(Int(corner.x)),\(Int(corner.y)) failed: CGError \(result.rawValue)") }
        refreshDisplays()
    }

    private func refreshDisplays() {
        stageBounds = CGDisplayBounds(displayID)
        userDisplays = Stage.onlineDisplays().filter { $0 != displayID }.map(CGDisplayBounds)
        contact = StageGeometry.contact(of: stageBounds, with: userDisplays)
        refreshArea()
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }

    private var mainHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    private func refreshArea() {
        if let screen = screen(for: displayID) {
            stageArea = StageGeometry.quartzRect(fromCocoa: screen.visibleFrame, mainDisplayHeight: mainHeight)
        } else {
            stageArea = CGRect(x: stageBounds.minX, y: stageBounds.minY + 40, width: stageBounds.width, height: max(0, stageBounds.height - 40))
        }
    }

    /// The user's main display minus menu bar and Dock, in Quartz coordinates.
    private func mainUsableArea() -> CGRect {
        guard let screen = NSScreen.screens.first else { return CGDisplayBounds(CGMainDisplayID()) }
        return StageGeometry.quartzRect(fromCocoa: screen.visibleFrame, mainDisplayHeight: mainHeight)
    }

    private func waitForScreen(deadline: Date, then: @escaping () -> Void) {
        if screen(for: displayID) != nil || Date() > deadline {
            if screen(for: displayID) == nil { StageRuntime.log("NSScreen did not list the stage within 3s; using its bounds minus a menu bar") }
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForScreen(deadline: deadline, then: then)
        }
    }

    private func finishStart() {
        refreshDisplays()
        let restored = restoreState()
        if !restored.done { try? FileManager.default.removeItem(at: Stage.takeoversURL) }
        sourceStamp = source.flatMap(FileStamp.init(path:))
        do {
            listenFD = try RelaySockets.listenUnix(path: Stage.socketURL.path)
        } catch {
            StageRuntime.log("cannot listen on \(Stage.socketURL.path): \(error)")
            exit(3)
        }
        let acceptor = Thread { [unowned self] in self.acceptLoop() }
        acceptor.name = "amcu-stage-accept"
        acceptor.start()

        let app = StageApp(runtime: self, tabs: restored.tabs)
        self.app = app
        NSApp.setActivationPolicy(.regular)
        startCursorGuard()
        observeSystem()
        handleSignals()
        repeatOnMain(every: 2) { [weak self] in self?.tick() }
        StageRuntime.log("stage up: display \(displayID), \(Int(stageBounds.width))x\(Int(stageBounds.height))@\(scale)x at \(Int(stageBounds.minX)),\(Int(stageBounds.minY)), \(contact.rawValue) contact; answers for \(answersFor ?? "?")\(holder.map { "; display kept by pid \($0.pid)" } ?? "")")
        if restored.shown { app.show() }
        changed()
    }

    // MARK: - Requests

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                usleep(200_000)
                continue
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let worker = Thread { [unowned self] in self.serve(client) }
            worker.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        while let line = RelaySockets.readLine(fd, buffer: &buffer, timeout: 0) {
            guard let request = try? StageWire.decoder().decode(StageRequest.self, from: line) else {
                _ = StageWire.writeLine(fd, StageResponse(id: 0, ok: false, result: nil, error: StageWireError(code: "invalid_argument", message: "malformed stage request", nextSteps: [])))
                continue
            }
            let response = DispatchQueue.main.sync { self.handle(request) }
            _ = StageWire.writeLine(fd, response)
            if request.method == "stop", response.ok {
                DispatchQueue.main.async { self.exitNow() }
                return
            }
            if request.method == "handover", response.ok {
                DispatchQueue.main.async { self.exitForHandover() }
                return
            }
        }
    }

    private func handle(_ request: StageRequest) -> StageResponse {
        do {
            let moves: [StageMove]
            switch request.method {
            case "status": moves = []
            case "put": moves = try put(request.params)
            case "release": moves = try release(request.params)
            case "stop": moves = stop(reason: "asked to stop")
            case "show":
                app?.show(activate: request.params.activate == true)
                moves = []
            case "hide":
                app?.hide()
                moves = []
            case "handback":
                let ids = request.params.windowIDs ?? []
                moves = ids.isEmpty ? handBackAll(by: request.params.by) : ids.map { handBack($0, by: request.params.by) }
            case "free":
                let ids = request.params.windowIDs ?? []
                moves = (ids.isEmpty ? Array(takeovers.keys) : ids).map { free($0, by: request.params.by) }
            case "activity":
                // Many a second, from verbs that do not wait: no status.
                if let entry = request.params.activity { record(entry) }
                return StageResponse(id: request.id, ok: true, result: nil, error: nil)
            case "note":
                if let text = request.params.text, !text.isEmpty { note(StageActivity.clip(text, 240)) }
                return StageResponse(id: request.id, ok: true, result: nil, error: nil)
            case "ask":
                let made = try ask(request.params)
                changed()
                return StageResponse(id: request.id, ok: true, result: StageReply(status: status(), moves: [], ask: made), error: nil)
            case "answer":
                guard let id = request.params.ask, asks.contains(where: { $0.id == id }) else {
                    throw AmcuError(.invalidArgument, "no request to the user has id \(request.params.ask.map(String.init) ?? "?")", nextSteps: ["`amcu stage status` lists the open ones under \"asking the user\"."])
                }
                end(ask: id, .cancelled)
                changed()
                return StageResponse(id: request.id, ok: true, result: StageReply(status: status(), moves: [], ask: asks.first { $0.id == id }), error: nil)
            case "handover":
                guard holder != nil else {
                    throw AmcuError(.unsupported, "this stage keeps its display in the host itself (no holder could start), so a new host cannot take it over", nextSteps: [
                        "`amcu stage restart` stops it and puts its windows back on a new stage instead."
                    ])
                }
                moves = []
            default: throw AmcuError(.invalidArgument, "unknown stage request '\(request.method)'")
            }
            changed()
            return StageResponse(id: request.id, ok: true, result: StageReply(status: status(), moves: moves), error: nil)
        } catch {
            let failure = error as? AmcuError ?? AmcuError(.unsupported, String(describing: error))
            return StageResponse(id: request.id, ok: false, result: nil, error: StageWireError(code: failure.code.rawValue, message: failure.message, nextSteps: failure.nextSteps))
        }
    }

    var answersFor: String? {
        Responsibility.current().map { $0.isSelf ? "amcu" : $0.name }
    }

    func status() -> StageStatus {
        prune()
        let following = followers.values
            .map { StageFollow(pid: $0.pid, app: $0.app, bundleID: $0.bundleID) }
            .sorted { $0.pid < $1.pid }
        return StageStatus(
            version: AmcuVersion.string,
            hostPID: getpid(),
            displayID: displayID,
            bounds: FrameJSON(stageBounds),
            scale: scale,
            contact: contact,
            since: since,
            answersFor: answersFor,
            accessibility: AXIsProcessTrusted(),
            screenRecording: CGPreflightScreenCaptureAccess(),
            cursorPullbacks: pullbacks,
            windows: windowsOnStage(),
            takenOver: takeovers.values.sorted { $0.since < $1.since }.map(publicTakeover),
            following: following,
            notes: notes,
            // A folded repeat keeps its place in the list but not its time.
            activity: Array(activity.suffix(20)).sorted { $0.at < $1.at },
            holderPID: holder?.pid,
            asks: asks
        )
    }

    private func ask(_ params: StageParams) throws -> StageAsk {
        let text = (params.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AmcuError(.invalidArgument, "say what the user should do", nextSteps: ["Pass --text, in the user's language: what to do and where, e.g. \"type the SMS code into the login page\"."])
        }
        let shown = windowsOnStage().map { (id: CGWindowID($0.windowID), pid: $0.pid) } + takeovers.values.map { (id: $0.windowID, pid: $0.pid) }
        let chosen: (id: CGWindowID, pid: pid_t)?
        if let id = params.windowIDs?.first {
            chosen = shown.first { $0.id == CGWindowID(id) }
        } else if let pid = params.pid {
            chosen = records.values.filter { $0.pid == pid }.map { (id: $0.windowID, pid: $0.pid) }.min { $0.id < $1.id }
                ?? shown.first { $0.pid == pid }
        } else {
            chosen = nil
        }
        guard let chosen else {
            throw AmcuError(.windowNotFound, "that window is neither on the stage nor held by the user, so the stage window cannot show the request", nextSteps: [
                "`amcu stage put --app <selector>` first, or ask the user in your own conversation.",
                "`amcu stage status` lists the windows on the stage."
            ])
        }
        let session = params.by ?? "default"
        for open in asks where open.isOpen && open.session == session && open.windowID == UInt32(chosen.id) {
            end(ask: open.id, .cancelled)
        }
        askSeq = max(askSeq, asks.map(\.id).max() ?? 0) + 1
        let made = StageAsk(id: askSeq, session: session, text: StageActivity.clip(text, 200), pid: chosen.pid, windowID: UInt32(chosen.id))
        asks.append(made)
        keep(StageActivity(kind: .ask, session: session, pid: chosen.pid, windowID: chosen.id, detail: made.text))
        StageRuntime.log("ask \(made.id) from \(session) for window \(chosen.id): \(made.text)")
        app?.asked(made)
        return made
    }

    func end(ask id: Int, _ state: StageAsk.State) {
        guard let index = asks.firstIndex(where: { $0.id == id && $0.isOpen }) else { return }
        asks[index].state = state
        asks[index].endedAt = Date()
        let ended = asks[index]
        keep(StageActivity(kind: .answered, session: ended.session, pid: ended.pid, windowID: CGWindowID(ended.windowID), detail: state.rawValue))
        StageRuntime.log("ask \(id) ended: \(state.rawValue)")
        changed()
    }

    private func endAsks(on id: CGWindowID, _ state: StageAsk.State) {
        for open in asks where open.isOpen && open.windowID == UInt32(id) { end(ask: open.id, state) }
    }

    private func pruneAsks() {
        asks.removeAll { !$0.isOpen && Date().timeIntervalSince($0.endedAt ?? $0.at) > 600 }
        guard asks.contains(where: \.isOpen), !Stage.screenIsLocked else { return }
        let here = Set(windowsOnStage().map { CGWindowID($0.windowID) }).union(records.keys).union(takeovers.keys)
        let existing = Set((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        for open in asks where open.isOpen && !here.contains(CGWindowID(open.windowID)) {
            end(ask: open.id, existing.contains(CGWindowID(open.windowID)) ? .released : .gone)
        }
    }

    private func hostNotTrusted() -> AmcuError {
        AmcuError(.permissionDenied, "the stage host (answering for \(answersFor ?? "its starting process")) is not trusted for Accessibility, so it cannot move windows", nextSteps: [
            "Grant Accessibility to \(answersFor ?? "the application that ran amcu"), then `amcu stage stop` and start the stage again from there.",
            "Run `amcu doctor` to see which application amcu answers for."
        ])
    }

    private func appName(_ app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
    }

    // MARK: - Putting windows on the stage

    func put(_ params: StageParams) throws -> [StageMove] {
        guard !stopping else { throw AmcuError(.stageUnavailable, "the stage is shutting down") }
        guard AXIsProcessTrusted() else { throw hostNotTrusted() }
        guard let pid = params.pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw AmcuError(.appNotFound, "no running application with pid \(params.pid.map(String.init) ?? "-")", nextSteps: ["Run `amcu apps` and pass a current selector."])
        }
        let ids = params.windowIDs ?? []
        guard !ids.isEmpty else { throw AmcuError(.invalidArgument, "put names no window") }
        let appElement = Target.appElement(app)
        AX.setMessagingTimeout(appElement, seconds: 1.5)
        let moves = ids.map { id -> StageMove in
            // Putting a window the user holds back on the stage is handing
            // it back.
            if takeovers[id] != nil { return handBack(id, by: params.by) }
            guard let element = findWindow(app: app, appElement: appElement, id: id) else {
                return StageMove(windowID: id, app: appName(app), title: nil, from: nil, to: nil, ok: false, note: "no such window any more")
            }
            return stage(element, id: id, app: app, origin: .put)
        }
        if params.follow ?? true { follow(app, appElement: appElement) }
        return moves
    }

    private func findWindow(app: NSRunningApplication, appElement: AXUIElement, id: CGWindowID) -> AXUIElement? {
        if let element = AX.windows(appElement).first(where: { AX.windowID($0) == id }) { return element }
        return AX.remoteWindow(pid: app.processIdentifier, windowID: id)
    }

    private func stage(_ element: AXUIElement, id: CGWindowID, app: NSRunningApplication, origin: StageWindow.Origin) -> StageMove {
        let name = appName(app)
        AX.setMessagingTimeout(element, seconds: 1.5)
        let title = StageRuntime.title(of: element)
        func failure(_ note: String, from: CGRect? = nil, to: CGRect? = nil) -> StageMove {
            StageMove(windowID: id, app: name, title: title, from: from.map(FrameJSON.init), to: to.map(FrameJSON.init), ok: false, note: note)
        }
        guard let frame = AX.frame(element) else { return failure("its frame cannot be read") }
        if StageGeometry.isOnStage(frame, stage: stageBounds) {
            if records[id] == nil {
                records[id] = Record(windowID: id, pid: app.processIdentifier, app: name, bundleID: app.bundleIdentifier, title: title, home: nil, origin: origin, element: element)
                watchDestruction(of: element, pid: app.processIdentifier)
            }
            return StageMove(windowID: id, app: name, title: title, from: FrameJSON(frame), to: FrameJSON(frame), ok: true, note: "already on the stage")
        }
        if AX.bool(element, kAXMinimizedAttribute as String) == true {
            return failure("it is minimised: restoring it would animate it out of the user's Dock, so it stays where it is", from: frame)
        }
        let source = userDisplays.first { StageGeometry.isOnStage(frame, stage: $0) } ?? CGDisplayBounds(CGMainDisplayID())
        let target = StageGeometry.carry(frame, from: source, to: stageBounds, within: stageArea)
        do {
            try WindowControl.setPosition(element, to: target)
        } catch {
            return failure("it refused to move: \((error as? AmcuError)?.message ?? String(describing: error))", from: frame)
        }
        let landed = settledFrame(element, target: target)
        guard let landed, StageGeometry.overlap(landed, stageBounds) >= 0.5 else {
            let place = landed.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "an unreadable position"
            return failure("the application kept it at \(place) instead of moving it to the stage", from: frame, to: landed)
        }
        records[id] = Record(windowID: id, pid: app.processIdentifier, app: name, bundleID: app.bundleIdentifier, title: title, home: frame, origin: origin, element: element)
        watchDestruction(of: element, pid: app.processIdentifier)
        return StageMove(windowID: id, app: name, title: title, from: FrameJSON(frame), to: FrameJSON(landed), ok: true, note: nil)
    }

    /// Applications apply a new position asynchronously and some adjust it,
    /// so the frame is read back until it reaches the target or stops moving.
    private func settledFrame(_ element: AXUIElement, target: CGPoint, timeout: TimeInterval = 1.2) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: CGRect?
        var unchanged = 0
        while Date() < deadline {
            usleep(50_000)
            guard let frame = AX.frame(element) else { continue }
            if abs(frame.minX - target.x) <= 1, abs(frame.minY - target.y) <= 1 { return frame }
            unchanged = (last == frame) ? unchanged + 1 : 0
            last = frame
            if unchanged >= 5 { return frame }
        }
        return last ?? AX.frame(element)
    }

    // MARK: - Taking windows back

    func release(_ params: StageParams) throws -> [StageMove] {
        guard AXIsProcessTrusted() else { throw hostNotTrusted() }
        prune()
        let onStage = windowsOnStage()
        var targets: [CGWindowID]
        if let ids = params.windowIDs, !ids.isEmpty {
            targets = ids
        } else if let pid = params.pid {
            targets = onStage.filter { $0.pid == pid }.map(\.windowID)
            targets += records.values.filter { $0.pid == pid && !targets.contains($0.windowID) }.map(\.windowID)
            targets += takeovers.values.filter { $0.pid == pid && !targets.contains($0.windowID) }.map(\.windowID)
        } else {
            targets = onStage.map(\.windowID)
            targets += records.keys.filter { !targets.contains($0) }
        }
        var touched = Set<pid_t>()
        let moves = targets.map { id -> StageMove in
            let entry = onStage.first { $0.windowID == id }
            if let pid = records[id]?.pid ?? entry?.pid ?? takeovers[id]?.pid { touched.insert(pid) }
            // A window the user holds is already on their screen: releasing
            // it lets it stay there for good.
            if let held = takeovers[id] {
                if params.activate == true {
                    return StageMove(windowID: id, app: held.app, title: held.title, from: nil, to: nil, ok: true, note: "the user holds it already")
                }
                return free(id, by: params.by)
            }
            // Handing a window to the user is a take-over like one from the
            // stage window.
            if params.activate == true { return takeOver(id, placement: .home, by: "handed to the user") }
            return unstage(id, entry: entry)
        }
        // An application stops being followed once none of its windows is
        // left on the stage — by this release, or for everything at once —
        // unless the user holds one of them and may hand it back.
        let everything = params.pid == nil && (params.windowIDs ?? []).isEmpty
        if let pid = params.pid { touched.insert(pid) }
        let staying = Set(records.values.map(\.pid)).union(takeovers.values.map(\.pid))
        for pid in Array(followers.keys) where !staying.contains(pid) && (everything || touched.contains(pid)) {
            unfollow(pid)
        }
        return moves
    }

    private func unstage(_ id: CGWindowID, entry: StageWindow?) -> StageMove {
        let record = records[id]
        let name = record?.app ?? entry?.app ?? "window \(id)"
        let title = record?.title ?? entry?.title
        guard let pid = record?.pid ?? entry?.pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            records[id] = nil
            return StageMove(windowID: id, app: name, title: title, from: nil, to: nil, ok: false, note: "its application is gone")
        }
        let element: AXUIElement? = {
            if let record, AX.frame(record.element) != nil { return record.element }
            return findWindow(app: app, appElement: Target.appElement(app), id: id)
        }()
        guard let element, let frame = AX.frame(element) else {
            records[id] = nil
            return StageMove(windowID: id, app: name, title: title, from: nil, to: nil, ok: false, note: "no such window any more")
        }
        var landed: CGRect? = frame
        if StageGeometry.isOnStage(frame, stage: stageBounds) {
            let destination = homeDestination(record?.home, frame: frame)
            do {
                try WindowControl.setPosition(element, to: destination)
                landed = settledFrame(element, target: destination)
            } catch {
                return StageMove(windowID: id, app: name, title: title, from: FrameJSON(frame), to: nil, ok: false, note: "it refused to move: \((error as? AmcuError)?.message ?? String(describing: error))")
            }
        }
        let back = landed.map { !StageGeometry.isOnStage($0, stage: stageBounds) } ?? false
        if back { records[id] = nil }
        return StageMove(windowID: id, app: name, title: title, from: FrameJSON(frame), to: landed.map(FrameJSON.init), ok: back, note: back ? nil : "the application kept it on the stage")
    }

    /// Where a window leaving the stage goes when nothing better is known:
    /// its home if that is still on a user display, else the centre of the
    /// main display's usable area (not put here by amcu, or its display gone).
    private func homeDestination(_ home: CGRect?, frame: CGRect) -> CGPoint {
        if let home, userDisplays.contains(where: { StageGeometry.isOnStage(home, stage: $0) }) {
            return home.origin
        }
        let area = mainUsableArea()
        return StageGeometry.clamp(CGRect(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2, width: frame.width, height: frame.height), into: area)
    }

    /// The usable area (below the menu bar, clear of the Dock) of the user
    /// display under `point`, in Quartz coordinates.
    private func usableArea(containing point: CGPoint) -> CGRect {
        for screen in NSScreen.screens where !Stage.identity.matches((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) {
            let frame = StageGeometry.quartzRect(fromCocoa: screen.frame, mainDisplayHeight: mainHeight)
            if frame.contains(point) { return StageGeometry.quartzRect(fromCocoa: screen.visibleFrame, mainDisplayHeight: mainHeight) }
        }
        return mainUsableArea()
    }

    // MARK: - The user taking windows over, and handing them back

    /// Moves a window off the stage into the user's hands: to its home, or
    /// under their cursor when they clicked its thumbnail, then raises
    /// it and brings its application to the front. Through the accessibility
    /// API rather than NSRunningApplication: since macOS 14 an application
    /// that is not itself active (the host never is) may not hand activation
    /// to another one.
    @discardableResult
    func takeOver(_ id: CGWindowID, placement: Placement, by actor: String = "taken over by the user") -> StageMove {
        let entry = windowsOnStage().first { $0.windowID == id }
        let record = records[id]
        let name = record?.app ?? entry?.app ?? "window \(id)"
        let title = record?.title ?? entry?.title
        func failure(_ note: String) -> StageMove {
            StageMove(windowID: id, app: name, title: title, from: nil, to: nil, ok: false, note: note)
        }
        guard let pid = record?.pid ?? entry?.pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return failure("its application is gone")
        }
        let element: AXUIElement? = {
            if let record, AX.frame(record.element) != nil { return record.element }
            return findWindow(app: app, appElement: Target.appElement(app), id: id)
        }()
        guard let element, let frame = AX.frame(element) else { return failure("no such window any more") }
        guard StageGeometry.isOnStage(frame, stage: stageBounds) else { return failure("it is not on the stage") }
        let previousFront = focusedPID()
        let destination: CGPoint
        switch placement {
        case .home:
            destination = homeDestination(record?.home, frame: frame)
        case let .underCursor(grabbed, cursor):
            destination = StageGeometry.alignedOrigin(window: frame, grabbed: grabbed, cursor: cursor, within: usableArea(containing: cursor))
        }
        do {
            try WindowControl.setPosition(element, to: destination)
        } catch {
            return failure("it refused to move: \((error as? AmcuError)?.message ?? String(describing: error))")
        }
        guard let landed = settledFrame(element, target: destination), !StageGeometry.isOnStage(landed, stage: stageBounds) else {
            return failure("the application kept it on the stage")
        }
        records[id] = nil
        try? AX.setValue(element, kAXMainAttribute as String, kCFBooleanTrue)
        try? AX.perform(element, kAXRaiseAction as String)
        try? AX.setValue(Target.appElement(app), kAXFrontmostAttribute as String, kCFBooleanTrue)
        takeovers[id] = Takeover(
            windowID: id, pid: pid, app: name, bundleID: app.bundleIdentifier, title: title, since: Date(),
            stageFrame: frame, home: record?.home, origin: record?.origin ?? .found,
            previousFront: previousFront == pid ? nil : previousFront
        )
        saveTakeovers()
        note("\(name)\(title.map { " \"\($0)\"" } ?? "") \(actor); an agent acting on it hands it back first")
        changed()
        return StageMove(windowID: id, app: name, title: title, from: FrameJSON(frame), to: FrameJSON(landed), ok: true, note: "\(actor); handed back to the stage when an agent acts on it")
    }

    /// A click in a window's thumbnail, at `fraction` of the window from its
    /// top-left corner: that spot of the window comes to rest under the
    /// cursor.
    func takeOver(_ id: CGWindowID, grabbedAt fraction: CGPoint, cursor: CGPoint) {
        guard let window = windowsOnStage().first(where: { $0.windowID == id }) else {
            note("nothing to take over: window \(id) has left the stage")
            return
        }
        let grabbed = StageGeometry.point(in: window.frame.cgRect, fraction: fraction)
        let move = takeOver(id, placement: .underCursor(grabbed: grabbed, cursor: cursor))
        if !move.ok { note("could not take \(move.app) over: \(move.note ?? "unknown reason")") }
    }

    /// Puts a taken-over window back where it was on the stage: the user
    /// pressed "hand back" (`by` nil), or the session `by` acted on it.
    @discardableResult
    func handBack(_ id: CGWindowID, by session: String? = nil) -> StageMove {
        guard let held = takeovers[id] else {
            return StageMove(windowID: id, app: "window \(id)", title: nil, from: nil, to: nil, ok: false, note: "it is not taken over")
        }
        func finish(_ move: StageMove, release: Bool) -> StageMove {
            if release {
                takeovers[id] = nil
                saveTakeovers()
            }
            changed()
            return move
        }
        guard let app = NSRunningApplication(processIdentifier: held.pid), !app.isTerminated else {
            return finish(StageMove(windowID: id, app: held.app, title: held.title, from: nil, to: nil, ok: false, note: "its application is gone"), release: true)
        }
        guard let element = findWindow(app: app, appElement: Target.appElement(app), id: id), let frame = AX.frame(element) else {
            return finish(StageMove(windowID: id, app: held.app, title: held.title, from: nil, to: nil, ok: false, note: "the window is gone"), release: true)
        }
        let target = StageGeometry.clamp(CGRect(origin: held.stageFrame.origin, size: frame.size), into: stageArea)
        do {
            try WindowControl.setPosition(element, to: target)
        } catch {
            return finish(StageMove(windowID: id, app: held.app, title: held.title, from: FrameJSON(frame), to: nil, ok: false, note: "it refused to move: \((error as? AmcuError)?.message ?? String(describing: error))"), release: false)
        }
        guard let landed = settledFrame(element, target: target), StageGeometry.overlap(landed, stageBounds) >= 0.5 else {
            return finish(StageMove(windowID: id, app: held.app, title: held.title, from: FrameJSON(frame), to: nil, ok: false, note: "the application kept it on the user's screen"), release: false)
        }
        takeovers[id] = nil
        saveTakeovers()
        records[id] = Record(windowID: id, pid: held.pid, app: held.app, bundleID: held.bundleID, title: held.title, home: held.home, origin: held.origin, element: element)
        watchDestruction(of: element, pid: held.pid)
        // The keyboard would otherwise stay with a window that just left the
        // user's screen; it goes back to where it was before the take-over.
        if !takeovers.values.contains(where: { $0.pid == held.pid }), focusedPID() == held.pid,
           let previous = held.previousFront, let previousApp = NSRunningApplication(processIdentifier: previous), !previousApp.isTerminated {
            try? AX.setValue(AXUIElementCreateApplication(previous), kAXFrontmostAttribute as String, kCFBooleanTrue)
        }
        let label = held.title.map { " \"\($0)\"" } ?? ""
        if let session {
            note("\(held.app)\(label) handed back to the stage: \(StageActivity.sessionLabel(session)) acted on it")
            record(StageActivity(kind: .handBack, session: session, pid: held.pid, windowID: id))
        } else {
            note("\(held.app)\(label) handed back to the stage")
        }
        endAsks(on: id, .handedBack)
        return finish(StageMove(windowID: id, app: held.app, title: held.title, from: FrameJSON(frame), to: FrameJSON(landed), ok: true, note: session.map { "handed back before \(StageActivity.sessionLabel($0)) acts on it" } ?? "handed back"), release: false)
    }

    /// "Hand back" in the stage window: everything the user holds.
    @discardableResult
    func handBackAll(by session: String? = nil) -> [StageMove] {
        takeovers.values.sorted { $0.since < $1.since }.map { handBack($0.windowID, by: session) }
    }

    /// Lets a window the user holds go for good: it stays where it is on
    /// their screen and leaves the stage, so nothing hands it back, and amcu
    /// acts on it there like on any other window.
    @discardableResult
    func free(_ id: CGWindowID, by session: String? = nil) -> StageMove {
        guard let held = takeovers.removeValue(forKey: id) else {
            return StageMove(windowID: id, app: records[id]?.app ?? "window \(id)", title: records[id]?.title, from: nil, to: nil, ok: false, note: "it is not taken over")
        }
        records[id] = nil
        saveTakeovers()
        let staying = Set(records.values.map(\.pid)).union(takeovers.values.map(\.pid))
        if !staying.contains(held.pid) { unfollow(held.pid) }
        note("\(held.app)\(held.title.map { " \"\($0)\"" } ?? "") released\(session.map { " by \(StageActivity.sessionLabel($0))" } ?? ""): it stays on the user's screen and is no longer on the stage")
        endAsks(on: id, .released)
        changed()
        return StageMove(windowID: id, app: held.app, title: held.title, from: nil, to: nil, ok: true, note: "stays on the user's screen, off the stage")
    }

    /// Everything the user holds, released.
    @discardableResult
    func freeAll() -> [StageMove] {
        takeovers.values.sorted { $0.since < $1.since }.map { free($0.windowID) }
    }

    /// Clicking the picture of a window the user holds brings it to the
    /// front where it is.
    func focusHeld(_ id: CGWindowID) {
        guard let held = takeovers[id], let app = NSRunningApplication(processIdentifier: held.pid), !app.isTerminated,
              let element = findWindow(app: app, appElement: Target.appElement(app), id: id) else { return }
        try? AX.setValue(element, kAXMainAttribute as String, kCFBooleanTrue)
        try? AX.perform(element, kAXRaiseAction as String)
        try? AX.setValue(Target.appElement(app), kAXFrontmostAttribute as String, kCFBooleanTrue)
    }

    private func publicTakeover(_ held: Takeover) -> StageTakeover {
        StageTakeover(windowID: held.windowID, pid: held.pid, app: held.app, bundleID: held.bundleID, title: held.title, since: held.since, stageFrame: FrameJSON(held.stageFrame))
    }

    /// Every amcu process checks this file before acting on an application.
    private func saveTakeovers() {
        if takeovers.isEmpty {
            try? FileManager.default.removeItem(at: Stage.takeoversURL)
            return
        }
        let file = StageTakeoverFile(hostPID: getpid(), takeovers: takeovers.values.sorted { $0.since < $1.since }.map(publicTakeover))
        guard let data = try? StageWire.encoder().encode(file) else { return }
        try? data.write(to: Stage.takeoversURL, options: .atomic)
    }

    /// Takeovers whose window was closed are over.
    private func pruneTakeovers() {
        guard !takeovers.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return }
        let existing = Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        let gone = takeovers.keys.filter { !existing.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone {
            if let held = takeovers.removeValue(forKey: id) { note("\(held.app)'s taken-over window closed") }
        }
        saveTakeovers()
    }

    private func focusedPID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        AX.setMessagingTimeout(systemWide, seconds: 0.5)
        if let focused = AX.element(systemWide, kAXFocusedApplicationAttribute as String), let pid = AX.pid(focused) { return pid }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    // MARK: - Following new windows

    private func follow(_ app: NSRunningApplication, appElement: AXUIElement) {
        let pid = app.processIdentifier
        guard followers[pid] == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, stageObserverCallback, &created) == .success, let observer = created else {
            note("cannot watch \(appName(app)) for new windows")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        followers[pid] = Follower(pid: pid, app: appName(app), bundleID: app.bundleIdentifier, element: appElement, observer: observer)
        for record in records.values where record.pid == pid {
            AXObserverAddNotification(observer, record.element, kAXUIElementDestroyedNotification as CFString, refcon)
        }
    }

    private func unfollow(_ pid: pid_t) {
        guard let follower = followers.removeValue(forKey: pid) else { return }
        AXObserverRemoveNotification(follower.observer, follower.element, kAXWindowCreatedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(follower.observer), .commonModes)
    }

    private func watchDestruction(of element: AXUIElement, pid: pid_t) {
        guard let follower = followers[pid] else { return }
        AXObserverAddNotification(follower.observer, element, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
    }

    func observed(_ notification: String, element: AXUIElement) {
        if notification == kAXUIElementDestroyedNotification as String {
            if let id = records.first(where: { CFEqual($0.value.element, element) })?.key {
                records[id] = nil
                changed()
            }
            return
        }
        guard notification == kAXWindowCreatedNotification as String, let pid = AX.pid(element) else { return }
        // The window's final frame and id settle a moment after creation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.newWindow(element, pid: pid, attempt: 0)
        }
    }

    private func newWindow(_ element: AXUIElement, pid: pid_t, attempt: Int) {
        guard !stopping, followers[pid] != nil, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        AX.setMessagingTimeout(element, seconds: 1)
        guard AX.string(element, kAXRoleAttribute as String) == kAXWindowRole as String,
              StageRuntime.followedSubroles.contains(AX.string(element, kAXSubroleAttribute as String) ?? "") else { return }
        guard let id = AX.windowID(element), let frame = AX.frame(element), frame.width >= 40, frame.height >= 40 else {
            if attempt < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.newWindow(element, pid: pid, attempt: attempt + 1)
                }
            }
            return
        }
        guard records[id] == nil else { return }
        // The user holds a window of this application: whatever it opens now
        // is theirs.
        guard !takeovers.values.contains(where: { $0.pid == pid }) else { return }
        let name = appName(app)
        if StageGeometry.isOnStage(frame, stage: stageBounds) {
            records[id] = Record(windowID: id, pid: pid, app: name, bundleID: app.bundleIdentifier, title: StageRuntime.title(of: element), home: nil, origin: .followed, element: element)
            watchDestruction(of: element, pid: pid)
            changed()
            return
        }
        if userIsWorking(in: pid) {
            note("a new \(name) window stayed on the user's screen: they are working in \(name)")
            return
        }
        let move = stage(element, id: id, app: app, origin: .followed)
        let label = move.title.map { " \"\($0)\"" } ?? ""
        note(move.ok ? "moved a new \(name) window\(label) onto the stage" : "a new \(name) window\(label) stayed on the user's screen: \(move.note ?? "it could not be moved")")
        changed()
    }

    static func title(of element: AXUIElement) -> String? {
        guard let title = AX.string(element, kAXTitleAttribute as String), !title.isEmpty else { return nil }
        return title
    }

    /// The application with keyboard focus, read from the accessibility
    /// server (current) rather than NSWorkspace (lags by up to a second).
    private func userIsWorking(in pid: pid_t) -> Bool {
        focusedPID() == pid
    }

    // MARK: - What is on the stage

    /// Every window whose centre is on the stage, whoever put it there.
    func windowsOnStage() -> [StageWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let own = getpid()
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        var result: [StageWindow] = []
        for entry in list {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer >= 0, layer < dockLevel,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  rect.width >= 40, rect.height >= 40,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  StageGeometry.isOnStage(rect, stage: stageBounds), !Stage.isAmcu(pid) else { continue }
            // Mission Control's shields, space bars and app icons are not
            // application windows. Listing them creates phantom stage tabs.
            let ownerBundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            guard ownerBundle != "com.apple.WindowManager", ownerBundle != "com.apple.dock" else { continue }
            let record = records[id]
            let saved = record == nil ? unresolved.first { $0.windowID == id } : nil
            let title = (entry[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? record?.title ?? saved?.title
            result.append(StageWindow(
                windowID: id,
                pid: pid,
                app: record?.app ?? saved?.app ?? NSRunningApplication(processIdentifier: pid)?.localizedName ?? (entry[kCGWindowOwnerName as String] as? String) ?? "pid \(pid)",
                bundleID: record?.bundleID ?? saved?.bundleID ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                title: title,
                frame: FrameJSON(rect),
                home: record?.home.map(FrameJSON.init) ?? saved?.home,
                origin: record?.origin ?? saved?.origin ?? .found
            ))
        }
        return result
    }

    /// Forgets windows that closed or left the stage some other way. One that
    /// is merely off screen for now is kept while its frame is still on the
    /// stage: minimised, or anything that briefly empties the on-screen list
    /// (a put window came back "not put here by amcu" after a night, its home
    /// lost).
    private func prune() {
        adoptUnresolved()
        guard !records.isEmpty else { return }
        let present = Set(windowsOnStage().map(\.windowID))
        let absent = records.filter { !present.contains($0.key) }
        guard !absent.isEmpty else { return }
        var bounds: [CGWindowID: CGRect] = [:]
        for entry in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [] {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            bounds[id] = (entry[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .null
        }
        let locked = Stage.screenIsLocked
        for (id, record) in absent {
            guard let rect = bounds[id] else {
                records[id] = nil
                continue
            }
            if locked || StageGeometry.isOnStage(rect, stage: stageBounds) { continue }
            guard let frame = AX.frame(record.element), !StageGeometry.isOnStage(frame, stage: stageBounds) else { continue }
            records[id] = nil
        }
    }

    private func adoptUnresolved() {
        guard !unresolved.isEmpty else { return }
        let existing = Set((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        let locked = Stage.screenIsLocked
        var waiting: [StageState.SavedRecord] = []
        var adopted = 0
        for saved in unresolved {
            guard existing.contains(saved.windowID), records[saved.windowID] == nil,
                  let app = NSRunningApplication(processIdentifier: saved.pid), !app.isTerminated else { continue }
            guard !locked, let element = findWindow(app: app, appElement: Target.appElement(app), id: saved.windowID) else {
                waiting.append(saved)
                continue
            }
            records[saved.windowID] = Record(windowID: saved.windowID, pid: saved.pid, app: saved.app, bundleID: saved.bundleID, title: saved.title, home: saved.home?.cgRect, origin: saved.origin, element: element)
            watchDestruction(of: element, pid: saved.pid)
            adopted += 1
        }
        unresolved = waiting
        if adopted > 0 {
            note("accessibility sees \(adopted == 1 ? "the window" : "the \(adopted) windows") the previous host left again; \(adopted == 1 ? "its record is" : "their records are") back")
        }
    }

    static let promptApps: Set<String> = [
        "com.apple.UserNotificationCenter", "com.apple.SecurityAgent", "com.apple.coreservices.uiagent", "com.apple.accessibility.universalAccessAuthWarn"
    ]

    private func returnPrompts() {
        guard !userDisplays.isEmpty, !Stage.screenIsLocked else { return }
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && StageRuntime.promptApps.contains($0.bundleIdentifier ?? "") }
        let pids = Set(apps.map(\.processIdentifier))
        let list = pids.isEmpty ? [] : CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let showing = Set(list.compactMap { entry -> pid_t? in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  StageGeometry.isOnStage(rect, stage: stageBounds) else { return nil }
            return pid
        })
        guard !showing.isEmpty else {
            promptsRefused = []
            return
        }
        var moved: [String] = []
        for app in apps where showing.contains(app.processIdentifier) {
            for element in AX.windows(Target.appElement(app)) {
                guard let frame = AX.frame(element), StageGeometry.isOnStage(frame, stage: stageBounds) else { continue }
                let key = "\(app.processIdentifier) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
                guard !promptsRefused.contains(key) else { continue }
                let destination = homeDestination(nil, frame: frame)
                guard (try? WindowControl.setPosition(element, to: destination)) != nil,
                      let landed = settledFrame(element, target: destination), !StageGeometry.isOnStage(landed, stage: stageBounds) else {
                    promptsRefused.insert(key)
                    continue
                }
                moved.append(app.localizedName ?? app.bundleIdentifier ?? "a system prompt")
            }
        }
        if !moved.isEmpty {
            note("\(moved.count == 1 ? "a prompt" : "\(moved.count) prompts") from \(Set(moved).sorted().joined(separator: ", ")) had landed on the stage, where the user could not answer \(moved.count == 1 ? "it" : "them"); moved to the middle of their screen")
        }
    }

    // MARK: - The cursor guard

    private func startCursorGuard() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.guardCursor() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.guardCursor()
            return event
        }) {
            monitors.append(local)
        }
        // A backstop for movement no event reported, such as another program
        // warping the cursor.
        repeatOnMain(every: 0.5) { [weak self] in self?.guardCursor() }
    }

    private func guardCursor() {
        guard !stopping, let location = CGEvent(source: nil)?.location, stageBounds.contains(location),
              let back = StageGeometry.nearestPoint(to: location, in: userDisplays) else { return }
        CGWarpMouseCursorPosition(back)
        // Without re-associating, macOS freezes the pointer for a quarter
        // second after a warp.
        CGAssociateMouseAndMouseCursorPosition(1)
        pullbacks += 1
        if pullbacks == 1 || pullbacks % 25 == 0 {
            note("pulled the cursor back off the stage (\(pullbacks) time\(pullbacks == 1 ? "" : "s") so far)")
        }
        changed()
    }

    // MARK: - System events

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            self.unfollow(pid)
            self.records = self.records.filter { $0.value.pid != pid }
            self.unresolved.removeAll { $0.pid == pid }
            if self.takeovers.values.contains(where: { $0.pid == pid }) {
                self.takeovers = self.takeovers.filter { $0.value.pid != pid }
                self.saveTakeovers()
            }
            self.changed()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.screensChanged() }
        }
    }

    private func screensChanged() {
        guard !stopping else { return }
        guard Stage.onlineDisplays().contains(displayID) else {
            displayGone()
            return
        }
        refreshDisplays()
        app?.screensChanged()
        // Another display was plugged in or rearranged and now shares an edge
        // with the stage: back to the corner, at most every few seconds so a
        // system that keeps refusing cannot make this loop.
        if contact == .edge, Date().timeIntervalSince(lastPlacement) > 5 {
            place()
            note("the user's displays changed; the stage went back to the corner (\(contact.rawValue) contact now)")
        }
        changed()
    }

    private func handleSignals() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stopAndExit(reason: "signal \(number)") }
            source.resume()
            signalSources.append(source)
        }
    }

    private func repeatOnMain(every interval: TimeInterval, _ body: @escaping () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in body() }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func tick() {
        guard !stopping else { return }
        guard Stage.onlineDisplays().contains(displayID) else {
            displayGone()
            return
        }
        prune()
        pruneTakeovers()
        returnPrompts()
        pruneAsks()
        // Not empty while amcu still holds a put window, even if the window
        // list cannot see it right now: leaving would dump it on the user.
        if windowsOnStage().isEmpty && records.isEmpty && unresolved.isEmpty && takeovers.isEmpty {
            let start = emptySince ?? Date()
            emptySince = start
            if Date().timeIntervalSince(start) >= Stage.idleExit {
                stopAndExit(reason: "empty for \(Int(Stage.idleExit / 60)) minutes")
                return
            }
        } else {
            emptySince = nil
        }
        changed()
        checkForUpgrade()
    }

    private func displayTerminated() {
        guard !stopping else { return }
        StageRuntime.log("the system ended the stage display; macOS moved its windows to the user's displays")
        stopping = true
        ownDisplay = nil
        exitNow()
    }

    /// The holder ended (or the system ended its display): macOS has moved
    /// the windows to the user's displays already.
    private func displayGone() {
        guard !stopping else { return }
        StageRuntime.log("the stage display went away\(holder.map { " (its holder, pid \($0.pid), ended)" } ?? ""); macOS moved its windows to the user's displays")
        stopping = true
        holder = nil
        exitNow()
    }

    // MARK: - Stopping

    /// Brings every window back and stops following; the display itself goes
    /// in `exitNow`, after the reply has been sent.
    func stop(reason: String) -> [StageMove] {
        guard !stopping else { return [] }
        let moves = (try? release(StageParams())) ?? []
        stopping = true
        for pid in Array(followers.keys) { unfollow(pid) }
        StageRuntime.log("stopping (\(reason)); \(moves.filter(\.ok).count) of \(moves.count) windows back on the user's displays")
        return moves
    }

    func stopAndExit(reason: String) {
        _ = stop(reason: reason)
        exitNow()
    }

    func exitNow() {
        stopping = true
        app?.uninstall()
        app = nil
        // No request reaches a host on its way out.
        if listenFD >= 0 { close(listenFD) }
        unlink(Stage.socketURL.path)
        if let holder { StageDisplayHolder.stop(holder) }
        ownDisplay?.invalidate()
        ownDisplay = nil
        try? FileManager.default.removeItem(at: Stage.takeoversURL)
        try? FileManager.default.removeItem(at: Stage.stateURL)
        exit(0)
    }

    /// Leaves the display and its windows to the next host: what this one
    /// knows is on disk, what the user holds stays held.
    func exitForHandover() {
        guard holder != nil else {
            stopAndExit(reason: "handover without a holder")
            return
        }
        persist()
        stopping = true
        app?.uninstall()
        app = nil
        if listenFD >= 0 { close(listenFD) }
        unlink(Stage.socketURL.path)
        StageRuntime.log("handing the stage over; display \(displayID) stays with pid \(holder?.pid ?? 0)")
        exit(0)
    }

    // MARK: - For the stage app

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        app?.reopen()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        app?.dockMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app, !StageRuntime.systemIsQuitting() else {
            stopAndExit(reason: "the system is logging out or shutting down")
            return .terminateCancel
        }
        app.confirmClose { [weak self] in self?.stopAndExit(reason: "quit by the user") }
        return .terminateCancel
    }

    private static func systemIsQuitting() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: fourCharCode("why?"))?.enumCodeValue else { return false }
        return ["logo", "rlgo", "rrst", "rsdn", "rest", "shut"].map(fourCharCode).contains(reason)
    }

    private static func fourCharCode(_ text: String) -> OSType {
        text.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    func tabsChanged() {
        persist()
    }

    func takeOverFromMenu(_ windowID: UInt32) {
        let move = takeOver(windowID, placement: .home)
        if !move.ok { note("could not take \(move.app) over: \(move.note ?? "unknown reason")") }
    }

    var shownActivity: [StageActivity] { activity }

    func updateTabPairing(_ pairing: [CGWindowID: StageTabs.Paired]) {
        tabPairing = pairing
    }

    // MARK: - What the next host needs

    /// After anything changed: the stage window shows it, and the next host
    /// would find it.
    private func changed() {
        persist()
        app?.refresh()
    }

    private func persist() {
        guard !stopping, let holder else { return }
        let state = StageState(
            version: AmcuVersion.string,
            holderPID: holder.pid,
            displayID: displayID,
            since: since,
            records: (records.values.map {
                StageState.SavedRecord(windowID: $0.windowID, pid: $0.pid, app: $0.app, bundleID: $0.bundleID, title: $0.title, home: $0.home.map(FrameJSON.init), origin: $0.origin)
            } + unresolved.filter { records[$0.windowID] == nil }).sorted { $0.windowID < $1.windowID },
            takeovers: takeovers.values.sorted { $0.windowID < $1.windowID }.map {
                StageState.SavedTakeover(windowID: $0.windowID, pid: $0.pid, app: $0.app, bundleID: $0.bundleID, title: $0.title, since: $0.since, stageFrame: FrameJSON($0.stageFrame), home: $0.home.map(FrameJSON.init), origin: $0.origin, previousFront: $0.previousFront)
            },
            followers: followers.values.sorted { $0.pid < $1.pid }.map { StageFollow(pid: $0.pid, app: $0.app, bundleID: $0.bundleID) },
            notes: notes,
            pullbacks: pullbacks,
            activity: Array(activity.suffix(80)),
            windowShown: app?.isShown ?? false,
            tabs: app?.tabs,
            asks: asks
        )
        guard let data = try? StageWire.encoder().encode(state), data != lastPersisted else { return }
        do {
            try data.write(to: Stage.stateURL, options: .atomic)
            chmod(Stage.stateURL.path, 0o600)
            lastPersisted = data
        } catch {
            StageRuntime.log("cannot write \(Stage.stateURL.path): \(error)")
        }
    }

    /// Carries on from the host that kept this display before: its records,
    /// what it followed and what the user holds, for the windows still there.
    private func restoreState() -> (done: Bool, shown: Bool, tabs: StageState.Tabs?) {
        guard let holder, let data = try? Data(contentsOf: Stage.stateURL),
              let state = try? StageWire.decoder().decode(StageState.self, from: data),
              state.holderPID == holder.pid, state.displayID == displayID else { return (false, false, nil) }
        since = state.since
        pullbacks = state.pullbacks
        notes = state.notes
        activity = state.activity
        activitySeq = activity.map(\.seq).max() ?? 0
        asks = state.asks ?? []
        askSeq = asks.map(\.id).max() ?? 0
        let existing = Set((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        for saved in state.records {
            guard let app = NSRunningApplication(processIdentifier: saved.pid), !app.isTerminated else { continue }
            guard let element = findWindow(app: app, appElement: Target.appElement(app), id: saved.windowID) else {
                if existing.contains(saved.windowID) { unresolved.append(saved) }
                continue
            }
            records[saved.windowID] = Record(windowID: saved.windowID, pid: saved.pid, app: saved.app, bundleID: saved.bundleID, title: saved.title, home: saved.home?.cgRect, origin: saved.origin, element: element)
        }
        for saved in state.takeovers where existing.contains(saved.windowID) {
            guard let app = NSRunningApplication(processIdentifier: saved.pid), !app.isTerminated else { continue }
            takeovers[saved.windowID] = Takeover(windowID: saved.windowID, pid: saved.pid, app: saved.app, bundleID: saved.bundleID, title: saved.title, since: saved.since, stageFrame: saved.stageFrame.cgRect, home: saved.home?.cgRect, origin: saved.origin, previousFront: saved.previousFront)
        }
        for saved in state.followers {
            guard let app = NSRunningApplication(processIdentifier: saved.pid), !app.isTerminated else { continue }
            follow(app, appElement: Target.appElement(app))
        }
        saveTakeovers()
        let waiting = unresolved.isEmpty ? "" : "; \(unresolved.count) more kept until accessibility can see \(unresolved.count == 1 ? "it" : "them")\(Stage.screenIsLocked ? " (the screen is locked)" : "")"
        note("took the stage over from the previous host (amcu \(state.version)): \(records.count) window\(records.count == 1 ? "" : "s"), \(takeovers.count) held by the user, \(followers.count) followed\(waiting)")
        return (true, state.windowShown, state.tabs)
    }

    // MARK: - Upgrading in place

    struct FileStamp: Equatable {
        let inode: UInt64
        let size: Int64
        let modified: TimeInterval

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        }
    }

    /// A new amcu installed where this host was copied from takes over the
    /// stage once the file has stopped changing, unless the user is working
    /// in the stage window right now.
    private func checkForUpgrade() {
        guard let source, holder != nil, Date().timeIntervalSince(launched) > 20, !Stage.screenIsLocked,
              let stamp = FileStamp(path: source), stamp != sourceStamp else {
            pendingStamp = nil
            return
        }
        guard let pending = pendingStamp, pending.stamp == stamp else {
            pendingStamp = (stamp, Date())
            return
        }
        guard Date().timeIntervalSince(pending.since) >= 4, !(app?.isInUse ?? false) else { return }
        upgrade(to: stamp)
    }

    private func upgrade(to stamp: FileStamp) {
        guard let source else { return }
        let executable: String
        do {
            executable = try StageBundle.install(from: URL(fileURLWithPath: source))
        } catch {
            note("amcu at \(source) changed, but copying it for the stage failed: \((error as? AmcuError)?.message ?? String(describing: error))")
            sourceStamp = stamp
            return
        }
        note("amcu at \(source) changed; a host from it takes the stage over (the display and its windows stay)")
        persist()
        do {
            _ = try Stage.spawnDetached([executable, "stage", "serve", "--source", source])
        } catch {
            note("the new stage host could not start: \((error as? AmcuError)?.message ?? String(describing: error)); this one carries on")
            sourceStamp = stamp
            return
        }
        exitForHandover()
    }

    // MARK: - What agents do on the stage

    /// An acting verb's report: kept for the stage window when its window is
    /// on the stage or held, dropped otherwise.
    func record(_ incoming: StageActivity) {
        var entry = incoming
        if entry.windowID == nil, let tab = entry.tabID {
            guard let window = window(ofTab: tab) else {
                pairTabs(for: entry.pid) { [weak self] in
                    guard let self, let window = self.window(ofTab: tab) else { return }
                    entry.windowID = window
                    self.keep(entry)
                }
                return
            }
            entry.windowID = window
        }
        keep(entry)
    }

    private func keep(_ incoming: StageActivity) {
        guard let id = incoming.windowID, records[id] != nil || takeovers[id] != nil || windowsOnStage().contains(where: { $0.windowID == id }) else { return }
        if let index = activity.lastIndex(where: { $0.windowID == id }), activity[index].repeated(by: incoming),
           incoming.at.timeIntervalSince(activity[index].at) < 120 {
            activity[index].repeats = (activity[index].repeats ?? 1) + 1
            activity[index].at = incoming.at
            if let fraction = incoming.fraction { activity[index].fraction = fraction }
            app?.present(activity[index])
            return
        }
        var entry = incoming
        activitySeq += 1
        entry.seq = activitySeq
        activity.append(entry)
        if activity.count > 200 { activity.removeFirst(activity.count - 200) }
        app?.present(entry)
    }

    private func window(ofTab tab: Int) -> CGWindowID? {
        tabPairing.first { $0.value.tabs.contains { $0.id == tab } }?.key
    }

    /// Asks the browser's profiles which tabs are in which of its windows on
    /// the stage, off the main thread.
    private func pairTabs(for pid: pid_t, then: @escaping () -> Void) {
        guard !pairingTabs else { return }
        let staged = windowsOnStage().filter { $0.pid == pid }.map { (windowID: CGWindowID($0.windowID), pid: $0.pid) }
            + takeovers.values.filter { $0.pid == pid }.map { (windowID: $0.windowID, pid: $0.pid) }
        guard !staged.isEmpty else { return }
        pairingTabs = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pairing = StageTabs.collect(for: staged)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pairingTabs = false
                self.tabPairing.merge(pairing) { _, new in new }
                then()
            }
        }
    }

    // MARK: - Notes and log

    func note(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        notes.append("\(formatter.string(from: Date())) \(text)")
        if notes.count > 8 { notes.removeFirst(notes.count - 8) }
        StageRuntime.log(text)
    }

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) amcu stage[\(getpid())]: \(message)\n".utf8))
    }
}

/// What a host leaves for the next one on the same display.
struct StageState: Codable {
    struct SavedRecord: Codable {
        let windowID: CGWindowID
        let pid: pid_t
        let app: String
        let bundleID: String?
        let title: String?
        let home: FrameJSON?
        let origin: StageWindow.Origin
    }

    struct SavedTakeover: Codable {
        let windowID: CGWindowID
        let pid: pid_t
        let app: String
        let bundleID: String?
        let title: String?
        let since: Date
        let stageFrame: FrameJSON
        let home: FrameJSON?
        let origin: StageWindow.Origin
        let previousFront: pid_t?
    }

    struct Tabs: Codable {
        let order: [CGWindowID]
        let selected: CGWindowID?
    }

    let version: String
    let holderPID: Int32
    let displayID: UInt32
    let since: Date
    let records: [SavedRecord]
    let takeovers: [SavedTakeover]
    let followers: [StageFollow]
    let notes: [String]
    let pullbacks: Int
    let activity: [StageActivity]
    let windowShown: Bool
    let tabs: Tabs?
    var asks: [StageAsk]? = nil
}
