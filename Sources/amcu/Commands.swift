import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import AmcuCore

enum Commands {
    // MARK: - Shared resolution

    struct ResolvedTarget {
        let app: NSRunningApplication
        let appInfo: AppInfo
        let windowElement: AXUIElement
        let windowInfo: WindowInfo
    }

    static func resolveTarget(_ flags: Flags) throws -> ResolvedTarget {
        let selector = try flags.required("app", hint: "Pass --app with a bundle id, pid:N, or application name. `amcu apps` lists them.")
        let app = try Target.resolveApp(selector)
        try SensitiveApps.guardAgainst(app, allowed: flags.has("allow-sensitive"))
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

    /// For the commands that resolve an application directly rather than
    /// through `resolveTarget`.
    static func resolveApp(_ flags: Flags, _ selector: String) throws -> NSRunningApplication {
        let app = try Target.resolveApp(selector)
        try SensitiveApps.guardAgainst(app, allowed: flags.has("allow-sensitive"))
        return app
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
                throw AmcuError(.unsupported, "background pointer delivery is not usable on this system: \(check.summary)", nextSteps: [
                    "Run `amcu doctor` for the full verdict.",
                    "Re-run with --mode foreground to accept moving the cursor and taking focus.",
                    "Or address the element semantically: `amcu snapshot` then `amcu click --element N`."
                ])
            }
            return .background
        default:
            throw AmcuError(.invalidArgument, "unknown --mode '\(raw)'", nextSteps: ["Use one of: auto, background, foreground."])
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
        throw AmcuError(.unsupported, "--mode foreground would deliver to '\(frontmost)', not '\(app.localizedName ?? "the target")'", nextSteps: [
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
        let app = try resolveApp(flags, selector)
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
        if let maxNodes = try flags.boundedInt("max-nodes", min: 1, max: 20_000) { limits.maxNodes = maxNodes }
        if let maxDepth = try flags.boundedInt("max-depth", min: 1, max: 200) { limits.maxDepth = maxDepth }
        if let maxChildren = try flags.boundedInt("max-children", min: 1, max: 5_000) { limits.maxChildrenPerNode = maxChildren }

        let snapshot = SnapshotBuilder.capture(
            app: target.appInfo,
            window: target.windowInfo,
            windowElement: target.windowElement,
            limits: limits,
            // The escape hatch for when shaping guesses wrong: every node,
            // every row, no elision — at full token cost.
            shaping: !flags.has("no-shaping")
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
            throw AmcuError(.invalidArgument, "unknown --button '\(other)'", nextSteps: ["Use one of: left, right, middle."])
        }
        let clickCount = try flags.boundedInt("count", min: 1, max: 10) ?? 1

        // Element addressing: prefer the semantic action the element itself
        // advertises. It needs no coordinates, survives window movement, and is
        // the only path that works when a control is scrolled out of view.
        if let elementIndex = try flags.int("element") {
            let sessionName = session(flags)
            let (snapshot, node) = try SessionStore.node(index: elementIndex, session: sessionName)
            let app = try resolveApp(flags, "pid:\(snapshot.app.pid)")
            let window = try Target.selectWindow(of: app, windowID: snapshot.window.windowID, windowIndex: nil)

            // Optically located text has no element behind it to re-resolve, so
            // it cannot be re-verified the way an accessibility element can.
            // Freshness is the only guarantee available, so it is enforced
            // rather than left to the caller to remember.
            if node.origin == .vision {
                let maxAge = try flags.double("max-age") ?? 60
                let age = Date().timeIntervalSince(snapshot.capturedAt)
                guard age <= maxAge else {
                    throw AmcuError(.staleSnapshot, "this optical scan is \(Int(age))s old (limit \(Int(maxAge))s) and cannot be re-verified", nextSteps: [
                        "Re-run `amcu scan` and use the new indices.",
                        "Raise the bound with --max-age SECONDS if the window is known to be static."
                    ])
                }
                guard let frame = node.frame?.cgRect else {
                    throw AmcuError(.elementNotFound, "recognised text \(elementIndex) has no recorded position")
                }
                let mode = try deliveryMode(flags, requiresRouting: true)
                try assertForegroundIsSafe(mode, app: app)
                let center = globalPoint(CGPoint(x: frame.midX, y: frame.midY), window: window.info, isScreenSpace: false)
                try PointerInput.click(PointerInput.ClickRequest(
                    pid: app.processIdentifier,
                    windowID: window.info.windowID,
                    windowFrame: window.info.frame.cgRect,
                    global: center,
                    button: button,
                    clickCount: clickCount,
                    mode: mode
                ))
                let result = ActionResult(action: "click", mode: mode.rawValue, target: "text \(elementIndex)", detail: node.label.map { "\"\($0)\"" })
                Output.emit(result) { result.text }
                return
            }

            let element = try SnapshotBuilder.resolve(node: node, windowElement: window.element)

            let wantsCoordinates = (flags.string("mode") == "foreground") || flags.has("raw")
            let action = button == .right ? "AXShowMenu" : (kAXPressAction as String)
            if !wantsCoordinates, node.actions.contains(action) {
                try AX.perform(element, action)
                let result = ActionResult(action: "click", mode: "ax:\(action)", target: "element \(elementIndex)", detail: node.label)
                Output.emit(result) { result.text }
                return
            }

            // Read the position from the element that was just re-resolved, not
            // from the snapshot: the element can survive a reflow or a scroll
            // with its identity intact while its recorded frame points at
            // whatever now occupies that spot.
            let liveFrame = AX.frame(element)
            guard let target = liveFrame ?? node.frame?.cgRect.offsetBy(
                dx: window.info.frame.cgRect.minX,
                dy: window.info.frame.cgRect.minY
            ) else {
                throw AmcuError(.unsupported, "element \(elementIndex) advertises no '\(action)' action and has no frame to click", nextSteps: [
                    "Inspect the element's actions in `amcu snapshot` output.",
                    "Try `amcu action --element \(elementIndex) --action <name>` with a listed action."
                ])
            }
            let mode = try deliveryMode(flags, requiresRouting: true)
            try assertForegroundIsSafe(mode, app: app)
            let global = CGPoint(x: target.midX, y: target.midY)
            try PointerInput.click(PointerInput.ClickRequest(
                pid: app.processIdentifier,
                windowID: window.info.windowID,
                windowFrame: window.info.frame.cgRect,
                global: global,
                button: button,
                clickCount: clickCount,
                mode: mode
            ))
            let result = ActionResult(
                action: "click",
                mode: mode.rawValue,
                target: "element \(elementIndex)",
                detail: liveFrame == nil ? "coordinate fallback (recorded frame)" : "coordinate fallback (live frame)"
            )
            Output.emit(result) { result.text }
            return
        }

        // Coordinate addressing.
        guard let point = try flags.point("at") else {
            throw AmcuError(.invalidArgument, "click needs either --element N or --at x,y", nextSteps: [
                "Run `amcu snapshot --app <selector>` and click by element index — it is stable and needs no coordinates.",
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
            throw AmcuError(.invalidArgument, "--element is required", nextSteps: ["Run `amcu snapshot` first to get element indices."])
        }
        let name = try flags.required("action", hint: "Pass an action listed for that element in `amcu snapshot`.")
        let (snapshot, node) = try SessionStore.node(index: elementIndex, session: session(flags))
        let app = try resolveApp(flags, "pid:\(snapshot.app.pid)")
        let window = try Target.selectWindow(of: app, windowID: snapshot.window.windowID, windowIndex: nil)
        let element = try SnapshotBuilder.resolve(node: node, windowElement: window.element)
        try AX.perform(element, name)
        let result = ActionResult(action: "action", mode: "ax:\(name)", target: "element \(elementIndex)", detail: node.label)
        Output.emit(result) { result.text }
    }

    static func setValue(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        guard let elementIndex = try flags.int("element") else {
            throw AmcuError(.invalidArgument, "--element is required", nextSteps: ["Run `amcu snapshot` first to get element indices."])
        }
        let value = try flags.required("value")
        let (snapshot, node) = try SessionStore.node(index: elementIndex, session: session(flags))
        let app = try resolveApp(flags, "pid:\(snapshot.app.pid)")
        let window = try Target.selectWindow(of: app, windowID: snapshot.window.windowID, windowIndex: nil)
        let element = try SnapshotBuilder.resolve(node: node, windowElement: window.element)
        guard AX.isSettable(element, kAXValueAttribute as String) else {
            throw AmcuError(.unsupported, "element \(elementIndex) does not accept a value", nextSteps: [
                "Use `amcu type --app <selector> --text ...` after focusing the field.",
                "Check the snapshot: read-only elements cannot be set."
            ])
        }
        let verification = try TextInput.setValue(value, on: element)
        try requireNoMismatch(verification, elementIndex: elementIndex)
        let result = VerifiedActionResult(
            action: "set-value",
            mode: "ax:AXValue",
            target: "element \(elementIndex)",
            detail: nil,
            verification: verification,
            resultingValue: nil
        )
        Output.emit(result) { result.text }
    }

    /// Replaces the selected text of an element through the accessibility
    /// value, needing neither focus nor a frontmost application — the preferred
    /// text path whenever the element supports it.
    static func replace(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        guard let elementIndex = try flags.int("element") else {
            throw AmcuError(.invalidArgument, "--element is required", nextSteps: ["Run `amcu snapshot` first to get element indices."])
        }
        let text = try flags.required("text")
        let (snapshot, node) = try SessionStore.node(index: elementIndex, session: session(flags))
        let app = try resolveApp(flags, "pid:\(snapshot.app.pid)")
        let window = try Target.selectWindow(of: app, windowID: snapshot.window.windowID, windowIndex: nil)
        let element = try SnapshotBuilder.resolve(node: node, windowElement: window.element)
        guard AX.isSettable(element, kAXValueAttribute as String) else {
            throw AmcuError(.unsupported, "element \(elementIndex) does not accept a value", nextSteps: [
                "Use `amcu type --app <selector> --text ...` after focusing the field.",
                "Check the snapshot: read-only elements cannot be set."
            ])
        }
        let (verification, resultingValue, scope) = try TextInput.replaceSelection(with: text, on: element)
        try requireNoMismatch(verification, elementIndex: elementIndex)
        let result = VerifiedActionResult(
            action: "replace",
            mode: "ax:AXValue",
            target: "element \(elementIndex)",
            detail: node.label,
            verification: verification,
            resultingValue: resultingValue,
            // A whole-value overwrite discarded whatever was in the field; the
            // caller must hear that from the result, not discover it later.
            scope: scope
        )
        Output.emit(result) { result.text }
    }

    /// A write whose read-back disagrees is a failure, not a caveat: reporting
    /// success while the value never landed is exactly the silent error class
    /// this tool exists to eliminate. `notReadable` stays a success with a
    /// caveat — there was nothing to compare, which is different from a
    /// comparison that failed.
    static func requireNoMismatch(_ verification: ActionVerification, elementIndex: Int) throws {
        guard case let .unverified(reason, expected, actual) = verification, reason == .valueMismatch else { return }
        throw AmcuError(
            .accessibilityFailure,
            "element \(elementIndex) accepted the write but holds a different value: wrote '\(expected ?? "")', read back '\(actual ?? "")'",
            nextSteps: [
                "The application may normalise input (trimming, reformatting); compare the two values and decide whether the result is acceptable.",
                "If the value was rejected outright, focus the field and use `amcu type` instead."
            ]
        )
    }

    /// Typed input lands on the target's own focused element, so the focus is
    /// resolved and reported rather than assumed.
    static func focusForTyping(_ flags: Flags, app: NSRunningApplication) throws -> FocusInfo {
        if let expectation = flags.string("expect-focus") {
            return try Focus.require(expectation, of: app)
        }
        return Focus.current(of: app)
    }

    static func type(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let text = try flags.required("text")
        let app = try resolveApp(flags, try flags.required("app"))
        let mode = try deliveryMode(flags, requiresRouting: false)
        try assertForegroundIsSafe(mode, app: app)
        let focus = try focusForTyping(flags, app: app)
        try KeyboardInput.type(text: text, pid: app.processIdentifier, mode: mode)
        let result = ActionResult(action: "type", mode: mode.rawValue, target: app.localizedName ?? "pid:\(app.processIdentifier)", detail: "\(text.count) characters into \(focus.summary)")
        Output.emit(result) { result.text }
    }

    static func focus(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let app = try resolveApp(flags, try flags.required("app"))
        let focus = Focus.current(of: app)
        struct Payload: Encodable { let ok = true; let focus: FocusInfo }
        Output.emit(Payload(focus: focus)) { focus.summary }
    }

    // MARK: - Menus

    static func menu(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let app = try resolveApp(flags, try flags.required("app"))
        let depth = try flags.int("depth") ?? 3
        var items = try Menus.list(of: app, maxDepth: depth)
        if let filter = flags.string("filter")?.lowercased() {
            items = items.filter { $0.displayPath.lowercased().contains(filter) }
        }
        struct Payload: Encodable { let ok = true; let items: [MenuItem] }
        Output.emit(Payload(items: items)) {
            items.map { item in
                var line = item.displayPath
                if let shortcut = item.shortcut { line += "\t[\(shortcut)]" }
                if !item.enabled { line += "\t(disabled)" }
                if item.hasSubmenu { line += "\t>" }
                return line
            }.joined(separator: "\n")
        }
    }

    static func menuItem(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let app = try resolveApp(flags, try flags.required("app"))
        let raw = try flags.required("path", hint: "For example --path \"File > Save\".")
        let path = raw.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let item = try Menus.find(path, in: app)

        guard item.enabled else {
            throw AmcuError(.unsupported, "menu item '\(item.displayPath)' is disabled", nextSteps: [
                "The application does not currently allow this command; change the selection or state it depends on first."
            ])
        }

        // A keyboard equivalent reaches the same command without the menu
        // appearing on screen, so it is preferred whenever the item has one.
        let wantsPress = flags.has("press") || item.shortcut == nil
        if !wantsPress, let shortcut = item.shortcut {
            let parts = shortcut.split(separator: "+").map(String.init)
            let key = parts.last ?? ""
            let modifiers = Array(parts.dropLast())
            try KeyboardInput.press(key: key, modifiers: modifiers, pid: app.processIdentifier, mode: .background)
            let result = ActionResult(action: "menu-item", mode: "shortcut:\(shortcut)", target: item.displayPath, detail: nil)
            Output.emit(result) { result.text }
            return
        }

        // Pressing an item goes through the menu itself, which may briefly
        // appear on screen — the reason the shortcut route is preferred.
        let element = try Menus.resolve(item, in: app)
        try AX.perform(element, kAXPressAction as String)
        let result = ActionResult(action: "menu-item", mode: "ax:AXPress", target: item.displayPath, detail: "no keyboard equivalent; the menu may have shown briefly")
        Output.emit(result) { result.text }
    }

    // MARK: - Optical fallback

    static func scan(_ flags: Flags) throws {
        let target = try resolveTarget(flags)
        guard let windowID = target.windowInfo.windowID else {
            throw AmcuError(.windowNotFound, "the selected window has no capturable id", nextSteps: [
                "Run `amcu windows --app <selector>` and pass an explicit --window-id."
            ])
        }
        let image = try Capture.window(id: windowID)
        let windowSize = target.windowInfo.frame.cgRect.size
        let languages = flags.list("lang").isEmpty ? ["zh-Hans", "en-US"] : flags.list("lang")
        let marks = try VisionScan.recognizeText(in: image, windowSize: windowSize, languages: languages)

        let snapshot = SnapshotBuilder.fromVision(app: target.appInfo, window: target.windowInfo, marks: marks)
        try SessionStore.save(snapshot, session: session(flags))

        var annotatedPath: String?
        if let out = flags.string("annotate") {
            guard let annotated = VisionScan.annotate(image, marks: marks, windowSize: windowSize) else {
                throw AmcuError(.captureFailure, "could not render the annotated capture")
            }
            try Capture.writePNG(annotated, to: URL(fileURLWithPath: out))
            annotatedPath = out
        }

        struct Payload: Encodable {
            let ok = true
            let snapshot: Snapshot
            let annotated: String?
        }
        Output.emit(Payload(snapshot: snapshot, annotated: annotatedPath)) {
            var lines = [snapshot.renderText()]
            lines.append("(optical scan: recognised text only — no roles, no state, no actions)")
            if let annotatedPath { lines.append("annotated capture: \(annotatedPath)") }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Window control

    static func window(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let target = try resolveTarget(flags)
        var performed: [String] = []

        if flags.has("raise") {
            try WindowControl.raise(target.windowElement)
            performed.append("raised")
        }
        if let point = try flags.point("move") {
            try WindowControl.setPosition(target.windowElement, to: point)
            performed.append("moved to \(Int(point.x)),\(Int(point.y))")
        }
        if let size = try flags.point("resize") {
            try WindowControl.setSize(target.windowElement, to: CGSize(width: size.x, height: size.y))
            performed.append("resized to \(Int(size.x))x\(Int(size.y))")
        }
        if flags.has("minimize") {
            try WindowControl.setMinimized(target.windowElement, true)
            performed.append("minimized")
        }
        if flags.has("restore") {
            try WindowControl.setMinimized(target.windowElement, false)
            performed.append("restored")
        }

        guard !performed.isEmpty else {
            throw AmcuError(.invalidArgument, "window needs something to do", nextSteps: [
                "Pass one or more of --raise, --move X,Y, --resize W,H, --minimize, --restore.",
                "These visibly disturb the user, which is why no other command does them for you."
            ])
        }
        let result = ActionResult(action: "window", mode: nil, target: target.windowInfo.title ?? "window", detail: performed.joined(separator: ", "))
        Output.emit(result) { result.text }
    }

    static func key(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let key = try flags.required("key", hint: "For example --key return, --key escape, --key a.")
        let modifiers = flags.list("mod")
        let app = try resolveApp(flags, try flags.required("app"))
        let mode = try deliveryMode(flags, requiresRouting: false)
        try assertForegroundIsSafe(mode, app: app)
        let focus = try focusForTyping(flags, app: app)
        try KeyboardInput.press(key: key, modifiers: modifiers, pid: app.processIdentifier, mode: mode)
        let combination = (modifiers + [key]).joined(separator: "+")
        let result = ActionResult(action: "key", mode: mode.rawValue, target: app.localizedName ?? "pid:\(app.processIdentifier)", detail: "\(combination) to \(focus.summary)")
        Output.emit(result) { result.text }
    }

    static func paste(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let text = try flags.required("text")
        let app = try resolveApp(flags, try flags.required("app"))
        let mode = try deliveryMode(flags, requiresRouting: false)
        try assertForegroundIsSafe(mode, app: app)
        let focus = try focusForTyping(flags, app: app)
        // Pasting sidesteps input methods entirely, which matters for CJK text
        // and for any layout where synthesised keystrokes would be recomposed.
        // The pasteboard belongs to the user, so it is borrowed rather than
        // taken: whatever was on it goes back afterwards.
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }
        try KeyboardInput.press(key: "v", modifiers: ["cmd"], pid: app.processIdentifier, mode: mode)
        // Give the target a moment to read the pasteboard before it is restored.
        usleep(120_000)
        let result = ActionResult(action: "paste", mode: mode.rawValue, target: app.localizedName ?? "pid:\(app.processIdentifier)", detail: "\(text.count) characters via pasteboard into \(focus.summary)")
        Output.emit(result) { result.text }
    }

    static func scroll(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let target = try resolveTarget(flags)
        let deltaX = try flags.int32("dx", min: -100_000, max: 100_000) ?? 0
        let deltaY = try flags.int32("dy", min: -100_000, max: 100_000) ?? 0
        guard deltaX != 0 || deltaY != 0 else {
            throw AmcuError(.invalidArgument, "scroll needs --dx and/or --dy", nextSteps: ["Positive --dy scrolls up, negative scrolls down."])
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
            throw AmcuError(.invalidArgument, "drag needs --from x,y and --to x,y")
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
            steps: try flags.boundedInt("steps", min: 1, max: 500) ?? 12,
            mode: mode
        )
        let result = ActionResult(action: "drag", mode: mode.rawValue, target: target.appInfo.name, detail: nil)
        Output.emit(result) { result.text }
    }

    static func screenshot(_ flags: Flags) throws {
        let target = try resolveTarget(flags)
        guard let windowID = target.windowInfo.windowID else {
            throw AmcuError(.windowNotFound, "the selected window has no capturable id", nextSteps: [
                "Run `amcu windows --app <selector>` and pass an explicit --window-id."
            ])
        }
        let image = try Capture.window(id: windowID)
        let path = flags.string("out") ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("amcu-\(windowID).png").path
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
            var lines = ["amcu doctor — \(SelfCheck.osBuild)"]
            for permission in permissions {
                lines.append("  [\(permission.granted ? "ok" : "  ")] \(permission.id): \(permission.detail)")
            }
            lines.append("  [\(AX.canResolveWindowID ? "ok" : "  ")] ax window ids: \(AX.canResolveWindowID ? "resolvable" : "unavailable — background pointer events cannot be routed")")
            lines.append("  [\(check.usable ? "ok" : "  ")] background pointer delivery: \(check.summary)")
            if !check.usable {
                lines.append("  next: use --mode foreground, or drive elements semantically via `amcu snapshot` + `amcu click --element N`.")
            }
            return lines.joined(separator: "\n")
        }
    }
}

/// `ActionResult` plus the proof: whether the write was read back intact, and
/// (for replacements) the full value the element now holds. Lives beside the
/// commands that produce it rather than in Output.swift because only the
/// value-writing commands can offer verification.
struct VerifiedActionResult: Encodable {
    let ok = true
    let action: String
    let mode: String?
    let target: String
    let detail: String?
    let verification: ActionVerification
    let resultingValue: String?
    /// Only `replace` sets this; `set-value` always overwrites by contract, so
    /// there is nothing to disclose there.
    var scope: ReplacementScope? = nil

    var text: String {
        var parts = ["\(action) ok on \(target)"]
        if let mode { parts.append("via \(mode)") }
        if let detail { parts.append("(\(detail))") }
        if let scope { parts.append("(\(scope.label))") }
        parts.append("(\(verification.summary))")
        return parts.joined(separator: " ")
    }
}
