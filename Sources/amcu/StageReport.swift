import AppKit
import CoreGraphics
import Foundation
import AmcuCore

/// Tells the stage what an acting verb just did to a window on it, so the
/// stage window can show it under that window's picture: which session, what
/// it did, where. Costs nothing when no stage runs or the window is
/// elsewhere, never waits, never fails the verb, and never carries what was
/// typed — only how much.
enum StageReport {
    private static var verb = ""
    private static var window: (id: CGWindowID, frame: CGRect)?
    private static var point: CGPoint?
    private static var target: String?

    /// Each verb (each batch step) starts with nothing known.
    static func begin(_ verb: String) {
        self.verb = verb
        window = nil
        point = nil
        target = nil
    }

    static func window(_ info: WindowInfo) {
        guard let id = info.windowID else { return }
        window = (id, info.frame.cgRect)
    }

    static func at(_ point: CGPoint) { self.point = point }
    static func on(_ label: String?) { target = label }

    /// After the input was delivered.
    static func send(flags: Flags, app: NSRunningApplication) {
        guard let kind = nativeKind(), let stage = Stage.display() else { return }
        let pid = app.processIdentifier
        let resolved: (id: CGWindowID, frame: CGRect)
        if let window {
            resolved = window
        } else {
            guard let id = Stage.focusedWindowID(pid: pid), let frame = Stage.windowFrame(id) else { return }
            resolved = (id, frame)
        }
        let frame = Stage.windowFrame(resolved.id) ?? resolved.frame
        guard StageGeometry.isOnStage(frame, stage: stage.bounds) else { return }
        var count: Int?
        var keys: String?
        var detail: String?
        switch kind {
        case .type, .paste, .replace: count = flags.string("text")?.count
        case .setValue: count = flags.string("value")?.count
        case .key: keys = (flags.list("mod") + [flags.string("key") ?? ""]).joined(separator: "+")
        case .menu: detail = flags.string("path")
        case .press: detail = flags.string("action")
        case .scroll:
            let dy = (try? flags.int("dy")) ?? nil
            detail = (dy ?? 0) > 0 ? "up" : (dy ?? 0) < 0 ? "down" : "sideways"
        case .window:
            detail = [("raise", "raise"), ("move", "move"), ("resize", "resize"), ("minimize", "minimize"), ("restore", "restore")]
                .filter { flags.has($0.0) || flags.string($0.0) != nil }.map(\.1).joined(separator: ",")
        default: break
        }
        StageClient.report(StageActivity(
            kind: kind, session: Commands.session(flags), pid: pid, windowID: resolved.id,
            target: target, count: count, keys: keys, detail: detail,
            fraction: point.flatMap { StagePoint($0, in: frame) }
        ))
    }

    private static func nativeKind() -> StageActivity.Kind? {
        switch verb {
        case "click": return .click
        case "action": return .press
        case "set-value": return .setValue
        case "replace": return .replace
        case "type": return .type
        case "paste": return .paste
        case "key": return .key
        case "scroll": return .scroll
        case "drag": return .drag
        case "menu-item": return .menu
        case "window": return .window
        default: return nil
        }
    }

    // MARK: - Browser verbs

    /// A browser verb's result names its tab; the host finds the window.
    static func sendBrowser(_ verb: String, flags: Flags, client: BrowserClient, result: JSONValue) {
        guard let kind = browserKind(verb, flags), let tab = result["tab"]["id"].int,
              FileManager.default.fileExists(atPath: Stage.socketURL.path), Stage.display() != nil,
              let pid = Stage.browserPID(for: client.endpoint) else { return }
        var count: Int?
        var keys: String?
        var detail: String?
        switch kind {
        case .type: count = flags.string("text")?.count
        case .fill: count = flags.string("value")?.count
        case .key: keys = (flags.list("mod") + [flags.string("key") ?? ""]).joined(separator: "+")
        case .upload: count = flags.list("file").count
        case .navigate:
            let url = result["tab"]["url"].string ?? flags.string("url") ?? flags.positional.dropFirst().first ?? ""
            detail = StageTabs.host(of: url)
        case .scroll:
            let dy = (try? flags.int("dy")) ?? nil
            detail = (dy ?? 0) > 0 ? "up" : (dy ?? 0) < 0 ? "down" : "sideways"
        case .dialog: detail = flags.has("dismiss") ? "dismiss" : "accept"
        case .tab: detail = flags.has("new") ? "new" : flags.has("close") ? "close" : "activate"
        default: break
        }
        let point = result["windowPoint"]
        let fraction = point["x"].double.flatMap { x in point["y"].double.map { StagePoint(x: x, y: $0) } }
        StageClient.report(StageActivity(
            kind: kind, session: SessionName.resolve(explicit: flags.string("session")).name, pid: pid, tabID: tab,
            target: result["description"].string, count: count, keys: keys, detail: detail,
            fraction: fraction.flatMap { (0...1).contains($0.x) && (0...1).contains($0.y) ? $0 : nil }
        ))
    }

    private static func browserKind(_ verb: String, _ flags: Flags) -> StageActivity.Kind? {
        switch verb {
        case "click": return .click
        case "hover": return .hover
        case "type": return .type
        case "fill": return .fill
        case "select-option", "select": return .select
        case "key", "press": return .key
        case "scroll": return .scroll
        case "drag": return .drag
        case "upload": return .upload
        case "navigate", "goto", "open": return .navigate
        case "back": return .back
        case "forward": return .forward
        case "reload": return .reload
        case "eval", "evaluate": return .script
        case "dialog": return .dialog
        case "resize": return .resize
        case "tab": return (flags.has("new") || flags.has("activate")) ? .tab : nil
        default: return nil
        }
    }
}
