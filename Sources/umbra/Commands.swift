import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UmbraCore

enum Commands {
    // MARK: - Shared resolution

    struct ResolvedTarget {
        let app: NSRunningApplication
        let appInfo: AppInfo
        let windowElement: AXUIElement
        let windowInfo: WindowInfo
    }

    static func resolveTarget(_ flags: Flags) throws -> ResolvedTarget {
        let selector = try flags.required("app", hint: "Pass --app with a bundle id, pid:N, or application name. `umbra apps` lists them.")
        let app = try Target.resolveApp(selector)
        let windowID = try flags.int("window-id").map { CGWindowID($0) }
        let windowIndex = try flags.int("window-index")
        let selected = try Target.selectWindow(of: app, windowID: windowID, windowIndex: windowIndex)
        return ResolvedTarget(
            app: app,
            appInfo: AppInfo(
                pid: app.processIdentifier,
                name: app.localizedName ?? "(unnamed)",
                bundleID: app.bundleIdentifier,
                active: app.isActive,
                hasWindows: true
            ),
            windowElement: selected.element,
            windowInfo: selected.info
        )
    }

    static func session(_ flags: Flags) -> String {
        flags.string("session") ?? "default"
    }

    /// Chooses how an event will be delivered.
    ///
    /// `auto` refuses to silently fall back to foreground delivery: taking the
    /// user's focus is a visible side effect, so it has to be asked for.
    static func deliveryMode(_ flags: Flags, requiresRouting: Bool) throws -> DeliveryMode {
        let raw = flags.string("mode") ?? "auto"
        switch raw {
        case "background":
            return .background
        case "foreground":
            return .foreground
        case "auto":
            guard requiresRouting else { return .background }
            let check = SelfCheck.ensure()
            guard check.usable else {
                throw UmbraError(.unsupported, "background pointer delivery is not usable on this system: \(check.summary)", nextSteps: [
                    "Run `umbra doctor` for the full verdict.",
                    "Re-run with --mode foreground to accept moving the cursor and taking focus.",
                    "Or address the element semantically: `umbra snapshot` then `umbra click --element N`."
                ])
            }
            return .background
        default:
            throw UmbraError(.invalidArgument, "unknown --mode '\(raw)'", nextSteps: ["Use one of: auto, background, foreground."])
        }
    }

    /// Foreground delivery posts to the global event tap, which sends the event
    /// to whatever is frontmost — not necessarily the application named in
    /// `--app`. Acting anyway would click a stranger's interface, so a
    /// foreground request against a background application is refused rather
    /// than silently misdirected.
    static func assertForegroundIsSafe(_ mode: DeliveryMode, app: NSRunningApplication) throws {
        guard mode == .foreground, !app.isActive else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another application"
        throw UmbraError(.unsupported, "--mode foreground would deliver to '\(frontmost)', not '\(app.localizedName ?? "the target")'", nextSteps: [
            "Use --mode background so the event is routed to the target window regardless of what is frontmost.",
            "Or bring the target to the front yourself first, if taking focus is acceptable."
        ])
    }

    /// Snapshot coordinates are window-relative; `--screen` opts into absolute
    /// Quartz coordinates for callers that already have them.
    static func globalPoint(_ point: CGPoint, window: WindowInfo, isScreenSpace: Bool) -> CGPoint {
        guard !isScreenSpace else { return point }
        let frame = window.frame.cgRect
        return CGPoint(x: frame.minX + point.x, y: frame.minY + point.y)
    }

    // MARK: - Inspection

    static func apps(_ flags: Flags) throws {
        let list = Target.runningApps()
        struct Payload: Encodable { let ok = true; let apps: [AppInfo] }
        Output.emit(Payload(apps: list)) {
            list.map { app in
                let marks = [app.active ? "active" : nil, app.hasWindows ? nil : "no-windows"].compactMap { $0 }
                let suffix = marks.isEmpty ? "" : "  (\(marks.joined(separator: ", ")))"
                return "\(app.pid)\t\(app.bundleID ?? "-")\t\(app.name)\(suffix)"
            }.joined(separator: "\n")
        }
    }

    static func windows(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let selector = try flags.required("app")
        let app = try Target.resolveApp(selector)
        let list = try Target.windows(of: app).map(\.info)
        struct Payload: Encodable { let ok = true; let windows: [WindowInfo] }
        Output.emit(Payload(windows: list)) {
            list.map { window in
                let frame = window.frame
                let marks = [window.main ? "main" : nil, window.minimized ? "minimized" : nil].compactMap { $0 }
                let suffix = marks.isEmpty ? "" : "  (\(marks.joined(separator: ", ")))"
                return "index=\(window.index)\tid=\(window.windowID.map(String.init) ?? "-")\t\(Int(frame.x)),\(Int(frame.y)) \(Int(frame.width))x\(Int(frame.height))\t\(window.title ?? "(untitled)")\(suffix)"
            }.joined(separator: "\n")
        }
    }

    static func snapshot(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let target = try resolveTarget(flags)
        var limits = SnapshotLimits()
        if let maxNodes = try flags.int("max-nodes") { limits.maxNodes = maxNodes }
        if let maxDepth = try flags.int("max-depth") { limits.maxDepth = maxDepth }

        let snapshot = SnapshotBuilder.capture(
            app: target.appInfo,
            window: target.windowInfo,
            windowElement: target.windowElement,
            limits: limits
        )
        try SessionStore.save(snapshot, session: session(flags))
        Output.emit(snapshot) { snapshot.renderText() }
    }

    // MARK: - Acting

    static func click(_ flags: Flags) throws {
        try Permissions.requireAccessibility()

        let button: CGMouseButton
        switch flags.string("button") ?? "left" {
        case "left": button = .left
        case "right": button = .right
        case "middle": button = .center
        case let other:
            throw UmbraError(.invalidArgument, "unknown --button '\(other)'", nextSteps: ["Use one of: left, right, middle."])
        }
        let clickCount = try flags.int("count") ?? 1

        // Element addressing: prefer the semantic action the element itself
        // advertises. It needs no coordinates, survives window movement, and is
        // the only path that works when a control is scrolled out of view.
        if let elementIndex = try flags.int("element") {
            let sessionName = session(flags)
            let (snapshot, node) = try SessionStore.node(index: elementIndex, session: sessionName)
            let app = try Target.resolveApp("pid:\(snapshot.app.pid)")
            let window = try Target.selectWindow(of: app, windowID: snapshot.window.windowID, windowIndex: nil)
            let element = try SnapshotBuilder.resolve(node: node, windowElement: window.element)

            let wantsCoordinates = (flags.string("mode") == "foreground") || flags.has("raw")
            let action = button == .right ? "AXShowMenu" : (kAXPressAction as String)
            if !wantsCoordinates, node.actions.contains(action) {
                try AX.perform(element, action)
                let result = ActionResult(action: "click", mode: "ax:\(action)", target: "element \(elementIndex)", detail: node.label)
                Output.emit(result) { result.text }
                return
            }

            guard let frame = node.frame?.cgRect else {
                throw UmbraError(.unsupported, "element \(elementIndex) advertises no '\(action)' action and has no frame to click", nextSteps: [
                    "Inspect the element's actions in `umbra snapshot` output.",
                    "Try `umbra action --element \(elementIndex) --action <name>` with a listed action."
                ])
            }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let mode = try deliveryMode(flags, requiresRouting: true)
            try assertForegroundIsSafe(mode, app: app)
            let global = globalPoint(center, window: window.info, isScreenSpace: false)
            try PointerInput.click(PointerInput.ClickRequest(
                pid: app.processIdentifier,
                windowID: window.info.windowID,
                windowFrame: window.info.frame.cgRect,
                global: global,
                button: button,
                clickCount: clickCount,
                mode: mode
            ))
            let result = ActionResult(action: "click", mode: mode.rawValue, target: "element \(elementIndex)", detail: "coordinate fallback")
            Output.emit(result) { result.text }
            return
        }

        // Coordinate addressing.
        guard let point = try flags.point("at") else {
            throw UmbraError(.invalidArgument, "click needs either --element N or --at x,y", nextSteps: [
                "Run `umbra snapshot --app <selector>` and click by element index — it is stable and needs no coordinates.",
                "Coordinates are window-relative unless --screen is passed."
            ])
        }
        let target = try resolveTarget(flags)
        let mode = try deliveryMode(flags, requiresRouting: true)
        try assertForegroundIsSafe(mode, app: target.app)
        let global = globalPoint(point, window: target.windowInfo, isScreenSpace: flags.has("screen"))
        try PointerInput.click(PointerInput.ClickRequest(
            pid: target.app.processIdentifier,
            windowID: target.windowInfo.windowID,
            windowFrame: target.windowInfo.frame.cgRect,
            global: global,
            button: button,
            clickCount: clickCount,
            mode: mode
        ))
        let result = ActionResult(action: "click", mode: mode.rawValue, target: "\(Int(global.x)),\(Int(global.y))", detail: nil)
        Output.emit(result) { result.text }
    }

    static func action(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        guard let elementIndex = try flags.int("element") else {
            throw UmbraError(.invalidArgument, "--element is required", nextSteps: ["Run `umbra snapshot` first to get element indices."])
        }
        let name = try flags.required("action", hint: "Pass an action listed for that element in `umbra snapshot`.")
        let (snapshot, node) = try SessionStore.node(index: elementIndex, session: session(flags))
        let app = try Target.resolveApp("pid:\(snapshot.app.pid)")
        let window = try Target.selectWindow(of: app, windowID: snapshot.window.windowID, windowIndex: nil)
        let element = try SnapshotBuilder.resolve(node: node, windowElement: window.element)
        try AX.perform(element, name)
        let result = ActionResult(action: "action", mode: "ax:\(name)", target: "element \(elementIndex)", detail: node.label)
        Output.emit(result) { result.text }
    }

    static func setValue(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        guard let elementIndex = try flags.int("element") else {
            throw UmbraError(.invalidArgument, "--element is required", nextSteps: ["Run `umbra snapshot` first to get element indices."])
        }
        let value = try flags.required("value")
        let (snapshot, node) = try SessionStore.node(index: elementIndex, session: session(flags))
        let app = try Target.resolveApp("pid:\(snapshot.app.pid)")
        let window = try Target.selectWindow(of: app, windowID: snapshot.window.windowID, windowIndex: nil)
        let element = try SnapshotBuilder.resolve(node: node, windowElement: window.element)
        guard AX.isSettable(element, kAXValueAttribute as String) else {
            throw UmbraError(.unsupported, "element \(elementIndex) does not accept a value", nextSteps: [
                "Use `umbra type --app <selector> --text ...` after focusing the field.",
                "Check the snapshot: read-only elements cannot be set."
            ])
        }
        try AX.setValue(element, kAXValueAttribute as String, value as CFTypeRef)
        let result = ActionResult(action: "set-value", mode: "ax:AXValue", target: "element \(elementIndex)", detail: nil)
        Output.emit(result) { result.text }
    }

    static func type(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let text = try flags.required("text")
        let app = try Target.resolveApp(try flags.required("app"))
        let mode = try deliveryMode(flags, requiresRouting: false)
        try assertForegroundIsSafe(mode, app: app)
        try KeyboardInput.type(text: text, pid: app.processIdentifier, mode: mode)
        let result = ActionResult(action: "type", mode: mode.rawValue, target: app.localizedName ?? "pid:\(app.processIdentifier)", detail: "\(text.count) characters")
        Output.emit(result) { result.text }
    }

    static func key(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let key = try flags.required("key", hint: "For example --key return, --key escape, --key a.")
        let modifiers = flags.list("mod")
        let app = try Target.resolveApp(try flags.required("app"))
        let mode = try deliveryMode(flags, requiresRouting: false)
        try assertForegroundIsSafe(mode, app: app)
        try KeyboardInput.press(key: key, modifiers: modifiers, pid: app.processIdentifier, mode: mode)
        let combination = (modifiers + [key]).joined(separator: "+")
        let result = ActionResult(action: "key", mode: mode.rawValue, target: app.localizedName ?? "pid:\(app.processIdentifier)", detail: combination)
        Output.emit(result) { result.text }
    }

    static func paste(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let text = try flags.required("text")
        let app = try Target.resolveApp(try flags.required("app"))
        let mode = try deliveryMode(flags, requiresRouting: false)
        try assertForegroundIsSafe(mode, app: app)
        // Pasting sidesteps input methods entirely, which matters for CJK text
        // and for any layout where synthesised keystrokes would be recomposed.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        try KeyboardInput.press(key: "v", modifiers: ["cmd"], pid: app.processIdentifier, mode: mode)
        let result = ActionResult(action: "paste", mode: mode.rawValue, target: app.localizedName ?? "pid:\(app.processIdentifier)", detail: "\(text.count) characters via pasteboard")
        Output.emit(result) { result.text }
    }

    static func scroll(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let target = try resolveTarget(flags)
        let deltaX = Int32(try flags.int("dx") ?? 0)
        let deltaY = Int32(try flags.int("dy") ?? 0)
        guard deltaX != 0 || deltaY != 0 else {
            throw UmbraError(.invalidArgument, "scroll needs --dx and/or --dy", nextSteps: ["Positive --dy scrolls up, negative scrolls down."])
        }
        let windowFrame = target.windowInfo.frame.cgRect
        let point = try flags.point("at") ?? CGPoint(x: windowFrame.width / 2, y: windowFrame.height / 2)
        let mode = try deliveryMode(flags, requiresRouting: true)
        try assertForegroundIsSafe(mode, app: target.app)
        let global = globalPoint(point, window: target.windowInfo, isScreenSpace: flags.has("screen"))
        try PointerInput.scroll(
            pid: target.app.processIdentifier,
            windowID: target.windowInfo.windowID,
            windowFrame: windowFrame,
            global: global,
            deltaX: deltaX,
            deltaY: deltaY,
            mode: mode
        )
        let result = ActionResult(action: "scroll", mode: mode.rawValue, target: "\(Int(global.x)),\(Int(global.y))", detail: "dx=\(deltaX) dy=\(deltaY)")
        Output.emit(result) { result.text }
    }

    static func drag(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let target = try resolveTarget(flags)
        guard let from = try flags.point("from"), let to = try flags.point("to") else {
            throw UmbraError(.invalidArgument, "drag needs --from x,y and --to x,y")
        }
        let mode = try deliveryMode(flags, requiresRouting: true)
        try assertForegroundIsSafe(mode, app: target.app)
        let isScreenSpace = flags.has("screen")
        try PointerInput.drag(
            pid: target.app.processIdentifier,
            windowID: target.windowInfo.windowID,
            windowFrame: target.windowInfo.frame.cgRect,
            from: globalPoint(from, window: target.windowInfo, isScreenSpace: isScreenSpace),
            to: globalPoint(to, window: target.windowInfo, isScreenSpace: isScreenSpace),
            steps: try flags.int("steps") ?? 12,
            mode: mode
        )
        let result = ActionResult(action: "drag", mode: mode.rawValue, target: target.appInfo.name, detail: nil)
        Output.emit(result) { result.text }
    }

    static func screenshot(_ flags: Flags) throws {
        let target = try resolveTarget(flags)
        guard let windowID = target.windowInfo.windowID else {
            throw UmbraError(.windowNotFound, "the selected window has no capturable id", nextSteps: [
                "Run `umbra windows --app <selector>` and pass an explicit --window-id."
            ])
        }
        let image = try Capture.window(id: windowID)
        let path = flags.string("out") ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-\(windowID).png").path
        try Capture.writePNG(image, to: URL(fileURLWithPath: path))
        struct Payload: Encodable {
            let ok = true
            let path: String
            let width: Int
            let height: Int
        }
        let payload = Payload(path: path, width: image.width, height: image.height)
        Output.emit(payload) { "wrote \(image.width)x\(image.height) capture to \(path)" }
    }

    // MARK: - Diagnostics

    static func doctor(_ flags: Flags) throws {
        if flags.has("request") { Permissions.request() }
        let permissions = Permissions.all()
        let check = flags.has("force") ? SelfCheck.probe() : SelfCheck.ensure()
        if flags.has("force") { SelfCheck.store(check) }

        struct Payload: Encodable {
            let ok: Bool
            let permissions: [PermissionState]
            let windowRouting: SelfCheckResult
            let axWindowIDs: Bool
            let osBuild: String
        }
        let payload = Payload(
            ok: permissions.allSatisfy(\.granted) && check.usable,
            permissions: permissions,
            windowRouting: check,
            axWindowIDs: AX.canResolveWindowID,
            osBuild: SelfCheck.osBuild
        )
        Output.emit(payload) {
            var lines = ["umbra doctor — \(SelfCheck.osBuild)"]
            for permission in permissions {
                lines.append("  [\(permission.granted ? "ok" : "  ")] \(permission.id): \(permission.detail)")
            }
            lines.append("  [\(AX.canResolveWindowID ? "ok" : "  ")] ax window ids: \(AX.canResolveWindowID ? "resolvable" : "unavailable — background pointer events cannot be routed")")
            lines.append("  [\(check.usable ? "ok" : "  ")] background pointer delivery: \(check.summary)")
            if !check.usable {
                lines.append("  next: use --mode foreground, or drive elements semantically via `umbra snapshot` + `umbra click --element N`.")
            }
            return lines.joined(separator: "\n")
        }
    }
}
