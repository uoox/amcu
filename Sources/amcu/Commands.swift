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

    /// How a pointer-shaped command will reach the target, resolved from
    /// `--mode` and, for `auto`, from the SelfCheck verdict.
    enum ResolvedDelivery {
        case background
        case foreground
        /// Routed background delivery is not usable on this system. Clicks fall
        /// back to pressing through the accessibility tree at the target point
        /// — still no cursor movement — and refuse when nothing there is
        /// pressable. Scroll and drag have no such equivalent and refuse.
        case hitTest

        /// The event-posting mode, for the deliveries that post events at all.
        var pointerMode: DeliveryMode? {
            switch self {
            case .background: return .background
            case .foreground: return .foreground
            case .hitTest: return nil
            }
        }
    }

    /// Chooses how an event will be delivered.
    ///
    /// `auto` never silently falls back to foreground delivery: taking the
    /// user's focus is a visible side effect, so it has to be asked for. When
    /// routed background delivery is broken it resolves to `.hitTest` instead.
    static func deliveryMode(_ flags: Flags, requiresRouting: Bool) throws -> ResolvedDelivery {
        let raw = flags.string("mode") ?? "auto"
        switch raw {
        case "background":
            return .background
        case "foreground":
            return .foreground
        case "auto":
            guard requiresRouting else { return .background }
            return SelfCheck.ensure().usable ? .background : .hitTest
        default:
            throw AmcuError(.invalidArgument, "unknown --mode '\(raw)'", nextSteps: ["Use one of: auto, background, foreground."])
        }
    }

    /// Delivers a positioned click without disturbing the user, whichever way
    /// this system supports: verified window routing where SelfCheck passed,
    /// otherwise a semantic press on the element found at that point.
    /// Foreground only ever happens because `--mode foreground` asked for it.
    /// Returns the mode label for the result line and, when a background
    /// click activated its target anyway, the note that says so.
    static func deliverClick(
        _ delivery: ResolvedDelivery,
        app: NSRunningApplication,
        windowInfo: WindowInfo,
        global: CGPoint,
        button: CGMouseButton,
        clickCount: Int
    ) throws -> (mode: String, note: String?) {
        guard let mode = delivery.pointerMode else {
            let check = SelfCheck.ensure()
            let action = button == .right ? "AXShowMenu" : (kAXPressAction as String)
            guard button != .center, clickCount == 1 else {
                throw AmcuError(.unsupported, "background pointer delivery is not usable on this system (\(check.summary)), and only a plain left or right click can fall back to an accessibility press", nextSteps: [
                    "Address the element semantically: `amcu snapshot` then `amcu click --element N`.",
                    "Re-run with --mode foreground to accept moving the cursor and taking focus."
                ])
            }
            guard let pressed = try AXHitTest.press(pid: app.processIdentifier, at: global, action: action) else {
                throw AmcuError(.unsupported, "background pointer delivery is not usable on this system (\(check.summary)), and nothing at \(Int(global.x)),\(Int(global.y)) can be pressed through the accessibility tree", nextSteps: [
                    "Address the element semantically: `amcu snapshot` then `amcu click --element N`.",
                    "Re-run with --mode foreground to accept moving the cursor and taking focus."
                ])
            }
            return ("ax:\(pressed.action)@point", nil)
        }
        let focus = focusGuard(app, mode: mode)
        try PointerInput.click(PointerInput.ClickRequest(
            pid: app.processIdentifier,
            windowID: windowInfo.windowID,
            windowFrame: windowInfo.frame.cgRect,
            global: global,
            button: button,
            clickCount: clickCount,
            mode: mode
        ))
        return (mode.rawValue, focus?.note())
    }

    /// Background delivery promises not to touch the user's focus; AppKit can
    /// break that promise by activating the target on a mouse-down or a key.
    /// The guard records who was frontmost before the event and, afterwards,
    /// produces the note for the result when the target took over. Foreground
    /// delivery takes focus by definition and needs no guard.
    static func focusGuard(_ app: NSRunningApplication, mode: DeliveryMode) -> FocusGuard? {
        mode == .background ? FocusGuard(targetPID: app.processIdentifier) : nil
    }

    /// Applications known to discard synthesized input wholesale — clicks,
    /// scrolls and keys posted to them vanish without an error, however they
    /// are routed (verified empirically against WeChat's own windows and its
    /// mini-program windows: shell process, content process, with and without
    /// a preceding move, all ignored). Anti-automation by design. The events
    /// are still sent — a subset of controls could react — but the result
    /// carries this note so the caller re-checks and reports honestly instead
    /// of retrying forever or silently escalating to the user's cursor.
    static func syntheticInputImmunityNote(_ app: NSRunningApplication) -> String? {
        let immune: Set<String> = ["com.tencent.xinwechat", "com.tencent.flue.wechatappex"]
        guard let id = app.bundleIdentifier?.lowercased(), immune.contains(id) else { return nil }
        return "warning: this application is known to discard synthesized input; verify with a re-scan, and if nothing changed only --mode foreground (visible, moves the cursor) reaches it — ask the user first"
    }

    /// Foreground delivery posts to the global event tap, which sends the event
    /// to whatever is frontmost — not necessarily the application named in
    /// `--app`. Acting anyway would click a stranger's interface, so a
    /// foreground request against a background application is refused rather
    /// than silently misdirected.
    static func assertForegroundIsSafe(_ mode: ResolvedDelivery, app: NSRunningApplication) throws {
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

    /// Re-selects the window a snapshot was captured in, for the commands that
    /// replay a recorded element path against the live hierarchy.
    ///
    /// A recorded CGWindowID is authoritative. But `AX.windowID` rides on a
    /// private function and legitimately comes back nil for some sheets and
    /// panels — and in that case `Target.selectWindow` would silently fall back
    /// to the main window. Replaying AXChildren indices in a look-alike window
    /// resolves cleanly onto a control in the *wrong* window and reports
    /// success, so the fallback instead pins the window by its recorded index
    /// and cross-checks the title before any path is replayed.
    private static func snapshotWindow(
        for snapshot: Snapshot,
        app: NSRunningApplication
    ) throws -> (element: AXUIElement, info: WindowInfo) {
        if snapshot.window.windowID != nil {
            return try Target.selectWindow(of: app, windowID: snapshot.window.windowID, windowIndex: nil)
        }
        let selected = try Target.selectWindow(of: app, windowID: nil, windowIndex: snapshot.window.index)
        guard selected.info.title == snapshot.window.title else {
            let recorded = snapshot.window.title.map { "'\($0)'" } ?? "(untitled)"
            let live = selected.info.title.map { "'\($0)'" } ?? "(untitled)"
            throw AmcuError(.staleSnapshot, "the snapshot's window cannot be re-identified: index \(snapshot.window.index) is now \(live), the snapshot recorded \(recorded)", nextSteps: [
                "The application's window order or titles changed since the snapshot was captured.",
                "Re-run `amcu snapshot` and use the new indices."
            ])
        }
        return selected
    }

    /// Refuses to act on an element whose *live* AXEnabled is false:
    /// `AXUIElementPerformAction` on a disabled control returns success while
    /// the application ignores the press entirely — exactly the "report success
    /// on a no-op" failure this tool promises never to commit. The coordinate
    /// fallback is just as silent about it, so both paths consult this check.
    /// The snapshot's recorded state is deliberately not used: enablement flips
    /// as the application's preconditions change, and only the state at act
    /// time decides whether the event can land.
    ///
    /// A missing AXEnabled attribute counts as enabled — many elements never
    /// publish it, and refusing them all would make the tool unusable.
    ///
    /// Returns the annotation to surface in the result when `--force` overrode
    /// the check, so a forced act is never dressed up as an ordinary success.
    private static func requireEnabled(_ element: AXUIElement, elementIndex: Int, flags: Flags) throws -> String? {
        guard AX.bool(element, kAXEnabledAttribute as String) == false else { return nil }
        guard flags.has("force") else {
            throw AmcuError(.unsupported, "element \(elementIndex) is currently disabled; the application would ignore the event while amcu reported success", nextSteps: [
                "A disabled control usually means a precondition is unmet: select the item, fill the field, or change whatever state it depends on, then re-run `amcu snapshot`.",
                "If the application wrongly reports a usable control as disabled, re-run with --force to act anyway; the override is annotated in the result."
            ])
        }
        return "forced: element reports disabled"
    }

    /// Joins the optional fragments an action result wants in its detail slot,
    /// so a forced-override annotation never displaces the element's label.
    private static func combinedDetail(_ parts: String?...) -> String? {
        let kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: "; ")
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
            let window = try snapshotWindow(for: snapshot, app: app)

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
                let delivered = try deliverClick(mode, app: app, windowInfo: window.info, global: center, button: button, clickCount: clickCount)
                let immunityNote = mode == .foreground ? nil : syntheticInputImmunityNote(app)
                let result = ActionResult(action: "click", mode: delivered.mode, target: "text \(elementIndex)", detail: combinedDetail(node.label.map { "\"\($0)\"" }, immunityNote, delivered.note))
                Output.emit(result) { result.text }
                return
            }

            let element = try SnapshotBuilder.resolve(node: node, windowElement: window.element)
            let forcedNote = try requireEnabled(element, elementIndex: elementIndex, flags: flags)

            let wantsCoordinates = (flags.string("mode") == "foreground") || flags.has("raw")
            let action = button == .right ? "AXShowMenu" : (kAXPressAction as String)
            if !wantsCoordinates, node.actions.contains(action) {
                try AX.perform(element, action)
                let result = ActionResult(action: "click", mode: "ax:\(action)", target: "element \(elementIndex)", detail: combinedDetail(node.label, forcedNote))
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
            let delivered = try deliverClick(mode, app: app, windowInfo: window.info, global: global, button: button, clickCount: clickCount)
            let result = ActionResult(
                action: "click",
                mode: delivered.mode,
                target: "element \(elementIndex)",
                detail: combinedDetail(
                    liveFrame == nil ? "coordinate fallback (recorded frame)" : "coordinate fallback (live frame)",
                    forcedNote,
                    mode == .foreground ? nil : syntheticInputImmunityNote(app),
                    delivered.note
                )
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
        let delivered = try deliverClick(mode, app: target.app, windowInfo: target.windowInfo, global: global, button: button, clickCount: clickCount)
        let result = ActionResult(action: "click", mode: delivered.mode, target: "\(Int(global.x)),\(Int(global.y))", detail: combinedDetail(mode == .foreground ? nil : syntheticInputImmunityNote(target.app), delivered.note))
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
        let window = try snapshotWindow(for: snapshot, app: app)
        let element = try SnapshotBuilder.resolve(node: node, windowElement: window.element)
        let forcedNote = try requireEnabled(element, elementIndex: elementIndex, flags: flags)
        try AX.perform(element, name)
        let result = ActionResult(action: "action", mode: "ax:\(name)", target: "element \(elementIndex)", detail: combinedDetail(node.label, forcedNote))
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
        let window = try snapshotWindow(for: snapshot, app: app)
        let element = try SnapshotBuilder.resolve(node: node, windowElement: window.element)
        let forcedNote = try requireEnabled(element, elementIndex: elementIndex, flags: flags)
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
            detail: forcedNote,
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
        let window = try snapshotWindow(for: snapshot, app: app)
        let element = try SnapshotBuilder.resolve(node: node, windowElement: window.element)
        let forcedNote = try requireEnabled(element, elementIndex: elementIndex, flags: flags)
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
            detail: combinedDetail(node.label, forcedNote),
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
        let delivery = try deliveryMode(flags, requiresRouting: false)
        try assertForegroundIsSafe(delivery, app: app)
        let mode = delivery.pointerMode ?? .background
        let focus = try focusForTyping(flags, app: app)
        let guarded = focusGuard(app, mode: mode)
        try KeyboardInput.type(text: text, pid: app.processIdentifier, mode: mode)
        let result = ActionResult(action: "type", mode: mode.rawValue, target: app.localizedName ?? "pid:\(app.processIdentifier)", detail: combinedDetail("\(text.count) characters into \(focus.summary)", guarded?.note()))
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
        let delivery = try deliveryMode(flags, requiresRouting: false)
        try assertForegroundIsSafe(delivery, app: app)
        let mode = delivery.pointerMode ?? .background
        let focus = try focusForTyping(flags, app: app)
        let guarded = focusGuard(app, mode: mode)
        try KeyboardInput.press(key: key, modifiers: modifiers, pid: app.processIdentifier, mode: mode)
        let combination = (modifiers + [key]).joined(separator: "+")
        let result = ActionResult(action: "key", mode: mode.rawValue, target: app.localizedName ?? "pid:\(app.processIdentifier)", detail: combinedDetail("\(combination) to \(focus.summary)", guarded?.note()))
        Output.emit(result) { result.text }
    }

    static func paste(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let text = try flags.required("text")
        let app = try resolveApp(flags, try flags.required("app"))
        let delivery = try deliveryMode(flags, requiresRouting: false)
        try assertForegroundIsSafe(delivery, app: app)
        let mode = delivery.pointerMode ?? .background
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
        let guarded = focusGuard(app, mode: mode)
        try KeyboardInput.press(key: "v", modifiers: ["cmd"], pid: app.processIdentifier, mode: mode)
        // Give the target a moment to read the pasteboard before it is restored.
        usleep(120_000)
        let result = ActionResult(action: "paste", mode: mode.rawValue, target: app.localizedName ?? "pid:\(app.processIdentifier)", detail: combinedDetail("\(text.count) characters via pasteboard into \(focus.summary)", guarded?.note()))
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
        let delivery = try deliveryMode(flags, requiresRouting: true)
        try assertForegroundIsSafe(delivery, app: target.app)
        guard let mode = delivery.pointerMode else {
            throw AmcuError(.unsupported, "background scrolling is not usable on this system: \(SelfCheck.ensure().summary)", nextSteps: [
                "Scroll semantically where the application allows it: `amcu snapshot`, then act on the scroll area's elements.",
                "Re-run with --mode foreground to accept moving the cursor and taking focus."
            ])
        }
        let global = globalPoint(point, window: target.windowInfo, isScreenSpace: flags.has("screen"))
        let guarded = focusGuard(target.app, mode: mode)
        try PointerInput.scroll(
            pid: target.app.processIdentifier,
            windowID: target.windowInfo.windowID,
            windowFrame: windowFrame,
            global: global,
            deltaX: deltaX,
            deltaY: deltaY,
            mode: mode
        )
        let result = ActionResult(action: "scroll", mode: mode.rawValue, target: "\(Int(global.x)),\(Int(global.y))", detail: combinedDetail("dx=\(deltaX) dy=\(deltaY)", mode == .foreground ? nil : syntheticInputImmunityNote(target.app), guarded?.note()))
        Output.emit(result) { result.text }
    }

    static func drag(_ flags: Flags) throws {
        try Permissions.requireAccessibility()
        let target = try resolveTarget(flags)
        guard let from = try flags.point("from"), let to = try flags.point("to") else {
            throw AmcuError(.invalidArgument, "drag needs --from x,y and --to x,y")
        }
        let delivery = try deliveryMode(flags, requiresRouting: true)
        try assertForegroundIsSafe(delivery, app: target.app)
        guard let mode = delivery.pointerMode else {
            throw AmcuError(.unsupported, "background dragging is not usable on this system: \(SelfCheck.ensure().summary)", nextSteps: [
                "Re-run with --mode foreground to accept moving the cursor and taking focus."
            ])
        }
        let isScreenSpace = flags.has("screen")
        let guarded = focusGuard(target.app, mode: mode)
        try PointerInput.drag(
            pid: target.app.processIdentifier,
            windowID: target.windowInfo.windowID,
            windowFrame: target.windowInfo.frame.cgRect,
            from: globalPoint(from, window: target.windowInfo, isScreenSpace: isScreenSpace),
            to: globalPoint(to, window: target.windowInfo, isScreenSpace: isScreenSpace),
            steps: try flags.boundedInt("steps", min: 1, max: 500) ?? 12,
            mode: mode
        )
        let result = ActionResult(action: "drag", mode: mode.rawValue, target: target.appInfo.name, detail: guarded?.note())
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
        let host = Responsibility.current()

        // Two TCC subjects can hold grants for the same amcu binary: the host
        // this run answers as (terminal app, dinotty, a launchd service), and
        // the binary itself (consulted only for self-responsible runs). Report
        // both, so "I granted everything" and "doctor says no" stop coexisting.
        let permissions = Permissions.effective(hostName: (host?.isSelf == false) ? host?.name : nil)
        let selfProbe: PermissionProbe? = (host?.isSelf == true)
            ? nil // one subject only; the rows above already answer for amcu
            : Permissions.selfProbe(request: flags.has("request-self"))
        let selfPermissions: [PermissionState]? = selfProbe.map { probe in
            let note = "counts when amcu answers for itself — a launchd service (aaa-daemon) or a disclaimed spawn"
            return [
                PermissionState(
                    id: "accessibility",
                    granted: probe.accessibility,
                    detail: probe.accessibility ? note : "not granted to the amcu binary — \(note)"
                ),
                PermissionState(
                    id: "screen_recording",
                    granted: probe.screenRecording,
                    detail: probe.screenRecording ? note : "not granted to the amcu binary — \(note)"
                ),
            ]
        }
        let check = flags.has("force") ? SelfCheck.probe() : SelfCheck.ensure()
        if flags.has("force") { SelfCheck.store(check) }

        let browsers = BrowserClient.discover()

        struct ResponsibleJSON: Encodable {
            let pid: Int32
            let name: String
            let path: String?
            let isSelf: Bool
        }
        struct Payload: Encodable {
            let ok: Bool
            let permissions: [PermissionState]
            let responsibleProcess: ResponsibleJSON?
            let selfPermissions: [PermissionState]?
            let windowRouting: SelfCheckResult
            let axWindowIDs: Bool
            let osBuild: String
            let browsers: [BrowserEndpoint]
        }
        let payload = Payload(
            ok: permissions.allSatisfy(\.granted) && check.usable,
            permissions: permissions,
            responsibleProcess: host.map { ResponsibleJSON(pid: $0.pid, name: $0.name, path: $0.path, isSelf: $0.isSelf) },
            selfPermissions: selfPermissions,
            windowRouting: check,
            axWindowIDs: AX.canResolveWindowID,
            osBuild: SelfCheck.osBuild,
            browsers: browsers
        )
        Output.emit(payload) {
            var lines = ["amcu doctor — \(SelfCheck.osBuild)"]
            if let host {
                lines.append(host.isSelf
                    ? "  subject: amcu itself (self-responsible run — launchd or disclaimed)"
                    : "  subject: this run answers for \(host.name) (pid \(host.pid)\(host.path.map { ", \($0)" } ?? ""))")
            }
            let hostTag = (host?.isSelf == false) ? host.map { " (\($0.name))" } ?? "" : ""
            for permission in permissions {
                lines.append("  [\(permission.granted ? "ok" : "  ")] \(permission.id)\(hostTag): \(permission.detail)")
            }
            if let selfPermissions {
                for permission in selfPermissions {
                    lines.append("  [\(permission.granted ? "ok" : "  ")] \(permission.id) (amcu itself): \(permission.detail)")
                }
            } else if host?.isSelf != true {
                lines.append("  [ ?] amcu itself: unknown — responsibility disclaim unavailable; only the host rows apply")
            }
            lines.append("  [\(AX.canResolveWindowID ? "ok" : "  ")] ax window ids: \(AX.canResolveWindowID ? "resolvable" : "unavailable — background pointer events cannot be routed")")
            lines.append("  [\(check.usable ? "ok" : "  ")] background pointer delivery: \(check.summary)")
            if !check.usable {
                lines.append("  next: clicks fall back to an accessibility press at the target point (still no cursor movement); scroll and drag need --mode foreground.")
            }
            if browsers.isEmpty {
                lines.append("  [  ] browser bridge: no browser connected — optional; `amcu browser doctor` explains the one-time setup")
            } else {
                lines.append("  [ok] browser bridge: \(browsers.map(\.label).joined(separator: ", ")) connected — `amcu browser` drives web pages")
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
