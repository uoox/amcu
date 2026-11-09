import AppKit
import CoreGraphics
import Foundation
import AmcuCore

/// `amcu stage` — a display the user never sees, for the windows an agent drives.
enum StageCommands {
    static let help = """
    amcu stage — a display the user never sees, for the windows you drive

    WHAT IT IS
      A virtual display amcu adds diagonally off the corner of the user's
      screen. Windows on it are fully drawn — screenshots and scans are
      current, unlike a minimised window — every amcu verb works on them as
      usual, and the user does not see them. While a stage runs, an amcu app
      sits in the user's Dock (no menu bar icon). Its window has a tab per
      window on the stage, along the top or down the left as the user
      chooses: a live picture of the window, what agents just did to it and
      which session did it (a ring where a click landed), a browser window's
      tabs (the ones amcu's debugger is on marked), and a way to close the
      stage. Quitting the app closes the stage. The cursor is kept off the
      stage. The display is kept by a process of its own, so upgrading amcu
      or `stage restart` replaces the host without the windows ever leaving
      the stage.

    LINKS THE USER OPENS STAY OFF THE STAGE
      A link the user opens from another application (chat, mail, Finder)
      goes to the browser's last active window, which can be one on the
      stage. The extension moves such a tab to the window they used last
      (another profile's if that is the one), or into a new window on their
      screen, and puts the staged window's own tab back in front. Tabs you
      open (`amcu browser tab --new`), links clicked inside a page and
      anything in a window the user holds stay where they are.

    PROMPTS GO TO THE USER
      A permission or password prompt from macOS (UserNotificationCenter,
      SecurityAgent, …) that lands on the stage, as windows can while the
      user's display sleeps, is moved to the middle of their screen: it is
      theirs to answer.

    THE USER CAN TAKE A WINDOW OVER
      Clicking a window's picture in the stage window (or its "take over"
      button) brings it to the user's screen, the clicked spot under the
      pointer, and switches to it. "Hand back" puts it back where it was on
      the stage (the status bar's button does it for every window they
      hold); "release" lets them keep it for good, off the stage. An acting verb on a window the user holds —
      click, type, set-value, key, scroll, drag, window, a page action in its
      browser tab, … — hands that window back to the stage first, then acts:
      acting on it is taking it back, so be sure you need it. Other windows
      of the same application are not affected, nor is reading (snapshot,
      scan, screenshot), which works on held windows where they are.
      `taken_over` now only means handing back failed.

    VERBS
      put      --app S [--window-id N | --window-index N | --all] [--no-follow] [--force]
               move the application's main window (or the one chosen, or all of
               them) onto the stage, starting the stage if needed. Windows it
               opens later are moved over too unless --no-follow. Refused for
               the application the user is working in unless --force.
      release  --app S [--window-id N] [--activate] | --all
               bring windows back to where they were before `put`; a window
               the user holds stays where it is, off the stage for good. The
               application is no longer followed once none of its windows is
               left on the stage. --activate hands the window to the user
               instead (ask first): raised and switched to, and taken over —
               acting on it would take it back, so leave it until they say
               they are done.
      status   the display, the windows on it (whoever put them there), who is
               followed, recent events
      show     [--hide]
               bring up the stage window for the user (a tab per window, live
               pictures, take-over and hand-back buttons) without taking their
               keyboard; they move, resize, minimise or close it like any
               window, and the Dock icon brings it back; --hide closes it
      start    [--size WxH] [--scale 1|2]
               start an empty stage; the default matches the user's main display
      restart  a new host from this amcu takes over the stage; the display and
               its windows stay (a host from before 0.13 keeps the display
               itself: then its windows come back to the user's screen for a
               moment and are put back). An upgraded amcu does this by itself
               a few seconds after it is installed.
      stop     bring every window back and remove the display

    NOTES
      Stage applications you drive, not ones the user is using — a window of
      their browser or chat moved away is a disturbance, not a courtesy.
      Close or quit what you staged before `stop`, or its windows come back
      onto the user's screen. An empty stage removes itself after 15 minutes.
      `--mode foreground` is refused on the stage: it would put the user's
      cursor on a display they cannot see.
    """

    static func run(_ flags: Flags) throws {
        let verb = flags.positional.first ?? "help"
        switch verb {
        case "help": print(help)
        case "start": try start(flags)
        case "status": try status(flags)
        case "put": try put(flags)
        case "release": try release(flags)
        case "stop": try stop(flags)
        case "restart": try restart(flags)
        case "show": try show(flags)
        // Hidden: the resident process `start` spawns, and the one that keeps
        // the display.
        case "serve":
            let size = try flags.string("size").map(parseSize)
            StageHost.run(pointSize: size, scale: try scale(flags), source: flags.string("source"))
        case "preview":
            let size = try flags.string("size").map(parseSize) ?? CGSize(width: 1280, height: 820)
            let out = flags.string("out") ?? FileManager.default.temporaryDirectory.appendingPathComponent("amcu-stage-preview.png").path
            let tabs = flags.string("tabs") ?? "top"
            guard tabs == "top" || tabs == "left" else { throw AmcuError(.invalidArgument, "--tabs expects top or left, got '\(tabs)'") }
            try StagePreview.render(to: URL(fileURLWithPath: out), size: size, dark: flags.has("dark"), tabsOnLeft: tabs == "left", selected: try flags.int("select") ?? 0)
            print("wrote \(out)")
        case "hold":
            let size = try parseSize(try flags.required("size"))
            StageDisplayHolder.run(pointSize: size, scale: try scale(flags) ?? 2)
        default:
            throw AmcuError(.invalidArgument, "unknown stage verb '\(verb)'", nextSteps: ["Run `amcu stage help` for the verbs."])
        }
    }

    private static func parseSize(_ raw: String) throws -> CGSize {
        guard let size = StageGeometry.parseSize(raw) else {
            throw AmcuError(.invalidArgument, "--size expects WIDTHxHEIGHT in points between 640x480 and 8192x8192, got '\(raw)'")
        }
        return size
    }

    private static func scale(_ flags: Flags) throws -> Int? {
        guard let value = try flags.int("scale") else { return nil }
        guard value == 1 || value == 2 else {
            throw AmcuError(.invalidArgument, "--scale expects 1 or 2, got \(value)")
        }
        return value
    }

    // MARK: - Verbs

    private static func start(_ flags: Flags) throws {
        let size = try flags.string("size").map(parseSize)
        let (reply, started) = try StageClient.start(pointSize: size, scale: try scale(flags))
        struct Payload: Encodable {
            let ok = true
            let started: Bool
            let stage: StageStatus
        }
        Output.emit(Payload(started: started, stage: reply.status)) {
            var lines = [started ? "stage started" : "a stage is already running\(size.map { _ in " (stop it first to change its size)" } ?? "")"]
            lines += render(reply.status)
            return lines.joined(separator: "\n")
        }
    }

    private static func status(_ flags: Flags) throws {
        guard StageClient.isRunning() else {
            struct Payload: Encodable {
                let ok = true
                let running = false
                let available: Bool
                let reason: String?
            }
            let reason = VirtualDisplay.unavailableReason
            Output.emit(Payload(available: reason == nil, reason: reason)) {
                reason.map { "no stage running; this macOS cannot make one: \($0)" }
                    ?? "no stage running — `amcu stage put --app <selector>` starts one"
            }
            return
        }
        let reply = try StageClient.request("status")
        struct Payload: Encodable {
            let ok = true
            let running = true
            let stage: StageStatus
        }
        Output.emit(Payload(stage: reply.status)) { render(reply.status).joined(separator: "\n") }
    }

    private static func put(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let selector = try flags.required("app", hint: "Pass --app with a bundle id, pid:N, or application name. `amcu apps` lists them.")
        let app = try Commands.resolveApp(flags, selector)
        let name = app.localizedName ?? selector
        let windows: [WindowInfo]
        if flags.has("all") {
            windows = try Target.windows(of: app).map(\.info)
        } else {
            let windowID = try flags.int("window-id").map { CGWindowID($0) }
            windows = [try Target.selectWindow(of: app, windowID: windowID, windowIndex: try flags.int("window-index")).info]
        }
        let ids = windows.compactMap(\.windowID)
        guard !ids.isEmpty, ids.count == windows.count else {
            throw AmcuError(.windowNotFound, "\(windows.count - ids.count) of the chosen windows of '\(name)' have no window id, so the stage cannot track them", nextSteps: [
                "Run `amcu windows --app \(selector)` and pass --window-id for a window that has one."
            ])
        }
        // A window the user holds goes back like any acting verb takes it
        // back; anything else of the application they are working in stays.
        let held = Set(Stage.takeovers().filter { $0.pid == app.processIdentifier }.map(\.windowID))
        if app.isActive && !flags.has("force") && !ids.allSatisfy(held.contains) {
            throw AmcuError(.unsupported, "'\(name)' is the application the user is working in; moving its window away would take it out from under them", nextSteps: [
                "Ask the user first, or wait until they have moved on to something else.",
                "If you launched it and it brought itself to the front, re-run with --force."
            ])
        }
        let (_, started) = try StageClient.start()
        let reply = try StageClient.request("put", StageParams(pid: app.processIdentifier, windowIDs: ids, follow: !flags.has("no-follow"), by: Commands.session(flags)))
        try report("put", reply: reply, started: started, emptyMessage: nil)
    }

    private static func release(_ flags: Flags) throws {
        var params = StageParams(activate: flags.has("activate"))
        var subject = "everything"
        if let selector = flags.string("app") {
            let app = try Commands.resolveApp(flags, selector)
            params.pid = app.processIdentifier
            subject = app.localizedName ?? selector
            if let windowID = try flags.int("window-id") { params.windowIDs = [UInt32(windowID)] }
        } else if let windowID = try flags.int("window-id") {
            params.windowIDs = [UInt32(windowID)]
            subject = "window \(windowID)"
        } else if !flags.has("all") {
            throw AmcuError(.invalidArgument, "release needs --app S (optionally with --window-id N), or --all", nextSteps: [
                "`amcu stage status` lists what is on the stage."
            ])
        }
        let reply = try StageClient.request("release", params)
        try report("release", reply: reply, started: false, emptyMessage: "nothing of \(subject) is on the stage")
    }

    private static func show(_ flags: Flags) throws {
        let hide = flags.has("hide")
        let reply = try StageClient.request(hide ? "hide" : "show")
        struct Payload: Encodable {
            let ok = true
            let shown: Bool
            let stage: StageStatus
        }
        Output.emit(Payload(shown: !hide, stage: reply.status)) {
            hide ? "stage window closed" : "stage window open (\(reply.status.windows.count) window\(reply.status.windows.count == 1 ? "" : "s") on the stage); the user's keyboard stays where it was"
        }
    }

    private static func stop(_ flags: Flags) throws {
        guard StageClient.isRunning() else {
            struct Payload: Encodable { let ok = true; let running = false }
            Output.emit(Payload()) { "no stage running" }
            return
        }
        let reply = try StageClient.request("stop")
        struct Payload: Encodable {
            let ok = true
            let moves: [StageMove]
        }
        Output.emit(Payload(moves: reply.moves)) {
            var lines = ["stage stopped; the display is gone"]
            if !reply.moves.isEmpty {
                lines.append("windows back on the user's screen:")
                lines += reply.moves.map(render)
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func restart(_ flags: Flags) throws {
        guard StageClient.isRunning() else {
            struct Payload: Encodable { let ok = true; let running = false }
            Output.emit(Payload()) { "no stage running — `amcu stage put --app <selector>` starts one" }
            return
        }
        let before = try StageClient.request("status").status
        if let reply = try StageClient.handOver() {
            struct Payload: Encodable {
                let ok = true
                let handedOver = true
                let stage: StageStatus
            }
            Output.emit(Payload(stage: reply.status)) {
                let count = reply.status.windows.count
                var lines = ["stage host restarted (amcu \(before.version) → \(reply.status.version)); the display and the \(count) window\(count == 1 ? "" : "s") on it stayed put"]
                lines += render(reply.status)
                return lines.joined(separator: "\n")
            }
            return
        }
        try restartOwningHost(before)
    }

    /// A host from before 0.13 keeps the display itself: stopping it drops
    /// its windows onto the user's screen until a new stage takes them.
    private static func restartOwningHost(_ before: StageStatus) throws {
        try Permissions.requireAccessibility()
        let following = Set(before.following.map(\.pid))
        let stopped = Date()
        _ = try StageClient.request("stop")
        let gone = Date().addingTimeInterval(10)
        while Date() < gone, StageClient.isRunning() || Stage.display() != nil { usleep(100_000) }
        var moves: [StageMove] = []
        var left: [String] = []
        for (pid, group) in Dictionary(grouping: before.windows, by: \.pid) {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { continue }
            // An application that came to the front by itself in the gap is
            // not the user working in it; one they touched since might be.
            func userIsInIt() -> Bool {
                Stage.focusedApplicationPID() == pid && Stage.secondsSinceUserInput() < Date().timeIntervalSince(stopped)
            }
            let patience = Date().addingTimeInterval(30)
            while userIsInIt(), Date() < patience { usleep(250_000) }
            if userIsInIt() {
                left.append(app.localizedName ?? "pid \(pid)")
                continue
            }
            _ = try StageClient.start()
            moves += try StageClient.request("put", StageParams(pid: pid, windowIDs: group.map(\.windowID), follow: following.contains(pid))).moves
        }
        let after = try StageClient.start().reply.status
        struct Payload: Encodable {
            let ok: Bool
            let handedOver = false
            let moves: [StageMove]
            let leftWithUser: [String]
            let stage: StageStatus
        }
        Output.emit(Payload(ok: left.isEmpty && moves.allSatisfy(\.ok), moves: moves, leftWithUser: left, stage: after)) {
            var lines = ["the old stage kept its display itself, so it was stopped and its windows put on a new one (\(String(format: "%.1f", Date().timeIntervalSince(stopped)))s on the user's screen); from now on a restart keeps them on the stage"]
            lines += moves.map(render)
            if !left.isEmpty { lines.append("left on the user's screen, they are working in it: " + left.joined(separator: ", ")) }
            lines += render(after)
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Rendering

    private static func report(_ action: String, reply: StageReply, started: Bool, emptyMessage: String?) throws {
        let failed = reply.moves.filter { !$0.ok }
        struct Payload: Encodable {
            let ok: Bool
            let started: Bool
            let moves: [StageMove]
            let stage: StageStatus
        }
        if !reply.moves.isEmpty, failed.count == reply.moves.count {
            throw AmcuError(.unsupported, "\(action) moved nothing: " + failed.map { "\($0.app) (\($0.note ?? "unknown reason"))" }.joined(separator: "; "), nextSteps: [
                "`amcu stage status` shows what is on the stage now."
            ])
        }
        Output.emit(Payload(ok: failed.isEmpty, started: started, moves: reply.moves, stage: reply.status)) {
            var lines: [String] = []
            if started { lines.append("stage started") }
            if reply.moves.isEmpty, let emptyMessage { lines.append(emptyMessage) }
            lines += reply.moves.map(render)
            lines += render(reply.status)
            return lines.joined(separator: "\n")
        }
    }

    private static func render(_ move: StageMove) -> String {
        let name = move.title.map { "\(move.app) — \($0)" } ?? move.app
        let from = move.from.map { "\(Int($0.x)),\(Int($0.y))" } ?? "?"
        let to = move.to.map { "\(Int($0.x)),\(Int($0.y))" } ?? "?"
        if move.ok {
            return "  [ok] id=\(move.windowID) \(name): \(from) → \(to)\(move.note.map { " (\($0))" } ?? "")"
        }
        return "  [  ] id=\(move.windowID) \(name): \(move.note ?? "not moved")"
    }

    static func render(_ status: StageStatus) -> [String] {
        let bounds = status.bounds
        let contact: String
        switch status.contact {
        case .corner: contact = "touches the user's screen only at a corner"
        case .edge: contact = "shares an edge with the user's screen (the cursor guard keeps the pointer out)"
        case .apart: contact = "does not touch the user's screen"
        }
        var lines = [
            "stage: display \(status.displayID), \(Int(bounds.width))x\(Int(bounds.height))@\(status.scale)x at \(Int(bounds.x)),\(Int(bounds.y)) — \(contact); cursor pulled back \(status.cursorPullbacks)×"
        ]
        var host = "host: pid \(status.hostPID), amcu \(status.version)"
        if let answersFor = status.answersFor { host += ", answers for \(answersFor)" }
        host += status.holderPID.map { "; display kept by pid \($0)" } ?? "; the host keeps the display itself"
        if !status.accessibility { host += " — NOT trusted for Accessibility: it cannot move windows" }
        if !status.screenRecording { host += " — no Screen Recording: the stage window shows no pictures" }
        lines.append(host)
        if status.version != AmcuVersion.string {
            lines.append(status.holderPID == nil
                ? "note: the stage runs amcu \(status.version) and this is \(AmcuVersion.string); `amcu stage restart` puts its windows on a stage of this version (they come back to the user's screen for a moment)"
                : "note: the stage runs amcu \(status.version) and this is \(AmcuVersion.string); `amcu stage restart` hands it to this version, the display and its windows staying put")
        }
        if status.windows.isEmpty {
            lines.append("windows on the stage: none")
        } else {
            lines.append("windows on the stage (\(status.windows.count)):")
            for window in status.windows {
                let name = window.title.map { "\(window.app) — \($0)" } ?? window.app
                let origin: String
                switch window.origin {
                case .put: origin = "put"
                case .followed: origin = "followed"
                case .found: origin = "not put here by amcu"
                }
                let home = window.home.map { ", home \(Int($0.x)),\(Int($0.y))" } ?? ""
                lines.append("  id=\(window.windowID) pid=\(window.pid) \(name)  (\(origin)\(home))")
            }
        }
        if !status.takenOver.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            lines.append("taken over by the user (\(status.takenOver.count)) — an acting verb on one of these windows hands it back to the stage first:")
            for held in status.takenOver {
                let name = held.title.map { "\(held.app) — \($0)" } ?? held.app
                lines.append("  id=\(held.windowID) pid=\(held.pid) \(name)  (since \(formatter.string(from: held.since)), returns to \(Int(held.stageFrame.x)),\(Int(held.stageFrame.y)) on the stage)")
            }
        }
        if !status.following.isEmpty {
            lines.append("following: " + status.following.map { "\($0.app) (pid \($0.pid))" }.joined(separator: ", ") + " — new windows move to the stage unless the user is working in that app")
        }
        if !status.activity.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            lines.append("agents lately:")
            lines += status.activity.suffix(6).map { entry in
                "  \(formatter.string(from: entry.at)) \(StageActivity.sessionLabel(entry.session)): \(entry.summary(chinese: false))\(entry.windowID.map { " (id=\($0))" } ?? "")"
            }
        }
        if !status.notes.isEmpty {
            lines.append("recent:")
            lines += status.notes.map { "  \($0)" }
        }
        return lines
    }
}
