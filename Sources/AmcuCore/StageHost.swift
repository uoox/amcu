import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The resident stage process (`amcu stage serve`): owns the virtual display,
/// the menu bar icon and the cursor guard, moves windows on and off the
/// stage, follows the windows staged applications open later, and answers
/// the CLI over `Stage.socketURL`. Started detached by `StageClient.start`;
/// it inherits the starting command's responsible process, so it acts with
/// the same Accessibility and Screen Recording grants as that command.
public enum StageHost {
    public static func run(pointSize: CGSize?, scale: Int?) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runtime = StageRuntime(pointSize: pointSize, scale: scale)
        stageRuntime = runtime
        app.delegate = runtime
        app.run()
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

    /// A window the user took off the stage to work in. amcu leaves its
    /// application alone until the user hands the window back, which puts
    /// it where it was on the stage.
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
    private var display: VirtualDisplay?
    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var stageBounds: CGRect = .zero
    private var stageArea: CGRect = .zero
    private(set) var scale = 1
    private(set) var contact: StageGeometry.Contact = .apart
    private var userDisplays: [CGRect] = []
    private var records: [CGWindowID: Record] = [:]
    private var followers: [pid_t: Follower] = [:]
    private var takeovers: [CGWindowID: Takeover] = [:]
    private(set) var pullbacks = 0
    private var notes: [String] = []
    private let since = Date()
    private var menu: StageMenu?
    private var monitors: [Any] = []
    private var timers: [Timer] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var lockFD: Int32 = -1
    private var listenFD: Int32 = -1
    private var emptySince: Date?
    private var stopping = false
    private var lastPlacement = Date.distantPast

    init(pointSize: CGSize?, scale: Int?) {
        requestedSize = pointSize
        requestedScale = scale
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
            try createDisplay()
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

    private func takeLock() throws {
        try FileManager.default.createDirectory(at: Stage.cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(Stage.lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw AmcuError(.stageUnavailable, "cannot open \(Stage.lockURL.path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw AmcuError(.stageUnavailable, "another stage host is running")
        }
        lockFD = fd
    }

    private func createDisplay() throws {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let size = requestedSize ?? mainBounds.size
        let scale = requestedScale ?? Int(NSScreen.screens.first?.backingScaleFactor ?? 2)
        let display = try VirtualDisplay(identity: Stage.identity, pointSize: size, scale: scale) { [weak self] in
            self?.displayTerminated()
        }
        self.display = display
        self.displayID = display.displayID
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
        userDisplays = Stage.activeDisplays().filter { $0 != displayID }.map(CGDisplayBounds)
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
        try? FileManager.default.removeItem(at: Stage.takeoversURL)
        do {
            listenFD = try RelaySockets.listenUnix(path: Stage.socketURL.path)
        } catch {
            StageRuntime.log("cannot listen on \(Stage.socketURL.path): \(error)")
            exit(3)
        }
        let acceptor = Thread { [unowned self] in self.acceptLoop() }
        acceptor.name = "amcu-stage-accept"
        acceptor.start()

        let menu = StageMenu(runtime: self)
        self.menu = menu
        startCursorGuard()
        observeSystem()
        handleSignals()
        repeatOnMain(every: 2) { [weak self] in self?.tick() }
        StageRuntime.log("stage up: display \(displayID), \(Int(stageBounds.width))x\(Int(stageBounds.height))@\(scale)x at \(Int(stageBounds.minX)),\(Int(stageBounds.minY)), \(contact.rawValue) contact; answers for \(answersFor ?? "?")")
        menu.refresh()
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
                menu?.show()
                moves = []
            case "hide":
                menu?.hide()
                moves = []
            default: throw AmcuError(.invalidArgument, "unknown stage request '\(request.method)'")
            }
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
            notes: notes
        )
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
        if let taken = takeovers.values.first(where: { $0.pid == pid }) { throw Stage.takenOverError(publicTakeover(taken)) }
        let ids = params.windowIDs ?? []
        guard !ids.isEmpty else { throw AmcuError(.invalidArgument, "put names no window") }
        let appElement = Target.appElement(app)
        AX.setMessagingTimeout(appElement, seconds: 1.5)
        let moves = ids.map { id -> StageMove in
            guard let element = findWindow(app: app, appElement: appElement, id: id) else {
                return StageMove(windowID: id, app: appName(app), title: nil, from: nil, to: nil, ok: false, note: "no such window any more")
            }
            return stage(element, id: id, app: app, origin: .put)
        }
        if params.follow ?? true { follow(app, appElement: appElement) }
        menu?.refresh()
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
        if let pid = params.pid, let taken = takeovers.values.first(where: { $0.pid == pid }) {
            throw Stage.takenOverError(publicTakeover(taken))
        }
        prune()
        let onStage = windowsOnStage()
        var targets: [CGWindowID]
        if let ids = params.windowIDs, !ids.isEmpty {
            targets = ids
        } else if let pid = params.pid {
            targets = onStage.filter { $0.pid == pid }.map(\.windowID)
            targets += records.values.filter { $0.pid == pid && !targets.contains($0.windowID) }.map(\.windowID)
        } else {
            targets = onStage.map(\.windowID)
            targets += records.keys.filter { !targets.contains($0) }
        }
        var touched = Set<pid_t>()
        let moves = targets.map { id -> StageMove in
            let entry = onStage.first { $0.windowID == id }
            if let pid = records[id]?.pid ?? entry?.pid { touched.insert(pid) }
            // Handing a window to the user is a take-over like one from the
            // panel: the application is left alone until they hand it back.
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
        menu?.refresh()
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
        note("\(name)\(title.map { " \"\($0)\"" } ?? "") \(actor); amcu leaves \(name) alone until it is handed back")
        menu?.refresh()
        return StageMove(windowID: id, app: name, title: title, from: FrameJSON(frame), to: FrameJSON(landed), ok: true, note: "\(actor); locked for amcu until handed back")
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

    /// Puts a taken-over window back where it was on the stage and lifts
    /// amcu's hands-off once none of the application's windows is held.
    @discardableResult
    func handBack(_ id: CGWindowID) -> StageMove {
        guard let held = takeovers[id] else {
            return StageMove(windowID: id, app: "window \(id)", title: nil, from: nil, to: nil, ok: false, note: "it is not taken over")
        }
        func finish(_ move: StageMove, release: Bool) -> StageMove {
            if release {
                takeovers[id] = nil
                saveTakeovers()
            }
            menu?.refresh()
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
        note("\(held.app)\(held.title.map { " \"\($0)\"" } ?? "") handed back to the stage")
        return finish(StageMove(windowID: id, app: held.app, title: held.title, from: FrameJSON(frame), to: FrameJSON(landed), ok: true, note: "handed back"), release: false)
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
            if let held = takeovers.removeValue(forKey: id) { note("\(held.app)'s taken-over window closed; amcu may act on \(held.app) again") }
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
                menu?.refresh()
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
            menu?.refresh()
            return
        }
        if userIsWorking(in: pid) {
            note("a new \(name) window stayed on the user's screen: they are working in \(name)")
            return
        }
        let move = stage(element, id: id, app: app, origin: .followed)
        let label = move.title.map { " \"\($0)\"" } ?? ""
        note(move.ok ? "moved a new \(name) window\(label) onto the stage" : "a new \(name) window\(label) stayed on the user's screen: \(move.note ?? "it could not be moved")")
        menu?.refresh()
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
                  StageGeometry.isOnStage(rect, stage: stageBounds) else { continue }
            let record = records[id]
            let title = (entry[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? record?.title
            result.append(StageWindow(
                windowID: id,
                pid: pid,
                app: record?.app ?? NSRunningApplication(processIdentifier: pid)?.localizedName ?? (entry[kCGWindowOwnerName as String] as? String) ?? "pid \(pid)",
                bundleID: record?.bundleID ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                title: title,
                frame: FrameJSON(rect),
                home: record?.home.map(FrameJSON.init),
                origin: record?.origin ?? .found
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
        guard !records.isEmpty else { return }
        let present = Set(windowsOnStage().map(\.windowID))
        let absent = records.filter { !present.contains($0.key) }
        guard !absent.isEmpty else { return }
        let existing = Set((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        for (id, record) in absent {
            if existing.contains(id), let frame = AX.frame(record.element), StageGeometry.isOnStage(frame, stage: stageBounds) {
                continue
            }
            records[id] = nil
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
        menu?.refresh()
    }

    // MARK: - System events

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            self.unfollow(pid)
            self.records = self.records.filter { $0.value.pid != pid }
            if self.takeovers.values.contains(where: { $0.pid == pid }) {
                self.takeovers = self.takeovers.filter { $0.value.pid != pid }
                self.saveTakeovers()
            }
            self.menu?.refresh()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.screensChanged() }
        }
    }

    private func screensChanged() {
        guard !stopping, display != nil else { return }
        refreshDisplays()
        // Another display was plugged in or rearranged and now shares an edge
        // with the stage: back to the corner, at most every few seconds so a
        // system that keeps refusing cannot make this loop.
        if contact == .edge, Date().timeIntervalSince(lastPlacement) > 5 {
            place()
            note("the user's displays changed; the stage went back to the corner (\(contact.rawValue) contact now)")
        }
        menu?.refresh()
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
        prune()
        pruneTakeovers()
        // Not empty while amcu still holds a put window, even if the window
        // list cannot see it right now: leaving would dump it on the user.
        if windowsOnStage().isEmpty && records.isEmpty && takeovers.isEmpty {
            let start = emptySince ?? Date()
            emptySince = start
            if Date().timeIntervalSince(start) >= Stage.idleExit {
                stopAndExit(reason: "empty for \(Int(Stage.idleExit / 60)) minutes")
                return
            }
        } else {
            emptySince = nil
        }
        menu?.refresh()
    }

    private func displayTerminated() {
        guard !stopping else { return }
        StageRuntime.log("the system ended the stage display; macOS moved its windows to the user's displays")
        stopping = true
        display = nil
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
        menu?.uninstall()
        menu = nil
        display?.invalidate()
        display = nil
        try? FileManager.default.removeItem(at: Stage.takeoversURL)
        unlink(Stage.socketURL.path)
        exit(0)
    }

    // MARK: - For the menu

    func takeOverFromMenu(_ windowID: UInt32) {
        let move = takeOver(windowID, placement: .home)
        if !move.ok { note("could not take \(move.app) over: \(move.note ?? "unknown reason")") }
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
