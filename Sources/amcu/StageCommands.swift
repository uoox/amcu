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
      usual, and the user does not see them. A menu bar icon shows the user
      how many windows are there; clicking it opens a window with a live
      picture of each one, a browser window's tabs under its picture (the
      ones amcu's debugger is on marked), and a way to close the stage. The
      cursor is kept off the stage.

    THE USER CAN TAKE A WINDOW OVER
      Clicking a window's picture in the stage window (or its "take over"
      button) brings it to the user's screen, the clicked spot under the
      pointer, and switches to it. From then on every acting verb
      on that application — click, type, set-value, key, scroll, drag, window,
      stage put, … — is refused with `taken_over` until the user presses
      "hand back", which puts the window where it was on the stage. Reading
      (snapshot, scan, screenshot) still works. Wait, or ask the user; never
      move the window back yourself.

    VERBS
      put      --app S [--window-id N | --window-index N | --all] [--no-follow] [--force]
               move the application's main window (or the one chosen, or all of
               them) onto the stage, starting the stage if needed. Windows it
               opens later are moved over too unless --no-follow. Refused for
               the application the user is working in unless --force.
      release  --app S [--window-id N] [--activate] | --all
               bring windows back to where they were before `put`. The
               application is no longer followed once none of its windows is
               left on the stage. --activate hands the window to the user
               instead (ask first): raised and switched to, and taken over —
               amcu then leaves the application alone until the user hands it
               back from the stage window.
      status   the display, the windows on it (whoever put them there), who is
               followed, recent events
      show     [--hide]
               bring up the stage window for the user (live pictures, tabs,
               take-over and hand-back buttons) without taking their
               keyboard; they move, resize, minimise or close it like any
               window; --hide closes it
      start    [--size WxH] [--scale 1|2]
               start an empty stage; the default matches the user's main display
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
        case "show": try show(flags)
        // Hidden: the resident process `start` spawns.
        case "serve":
            let size = try flags.string("size").map(parseSize)
            StageHost.run(pointSize: size, scale: try scale(flags))
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
        try Stage.refuseIfTakenOver(pid: app.processIdentifier)
        if app.isActive && !flags.has("force") {
            throw AmcuError(.unsupported, "'\(name)' is the application the user is working in; moving its window away would take it out from under them", nextSteps: [
                "Ask the user first, or wait until they have moved on to something else.",
                "If you launched it and it brought itself to the front, re-run with --force."
            ])
        }
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
        let (_, started) = try StageClient.start()
        let reply = try StageClient.request("put", StageParams(pid: app.processIdentifier, windowIDs: ids, follow: !flags.has("no-follow")))
        try report("put", reply: reply, started: started, emptyMessage: nil)
    }

    private static func release(_ flags: Flags) throws {
        var params = StageParams(activate: flags.has("activate"))
        var subject = "everything"
        if let selector = flags.string("app") {
            let app = try Commands.resolveApp(flags, selector)
            try Stage.refuseIfTakenOver(pid: app.processIdentifier)
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
        if !status.accessibility { host += " — NOT trusted for Accessibility: it cannot move windows" }
        if !status.screenRecording { host += " — no Screen Recording: the menu bar view stays dark" }
        lines.append(host)
        if status.version != AmcuVersion.string {
            lines.append("note: the stage runs amcu \(status.version) and this is \(AmcuVersion.string); `amcu stage stop` and start it again to update it")
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
            lines.append("taken over by the user (\(status.takenOver.count)) — acting on these applications is refused until they are handed back:")
            for held in status.takenOver {
                let name = held.title.map { "\(held.app) — \($0)" } ?? held.app
                lines.append("  id=\(held.windowID) pid=\(held.pid) \(name)  (since \(formatter.string(from: held.since)), returns to \(Int(held.stageFrame.x)),\(Int(held.stageFrame.y)) on the stage)")
            }
        }
        if !status.following.isEmpty {
            lines.append("following: " + status.following.map { "\($0.app) (pid \($0.pid))" }.joined(separator: ", ") + " — new windows move to the stage unless the user is working in that app")
        }
        if !status.notes.isEmpty {
            lines.append("recent:")
            lines += status.notes.map { "  \($0)" }
        }
        return lines
    }
}
