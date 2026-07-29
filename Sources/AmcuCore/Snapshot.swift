import ApplicationServices
import CoreGraphics
import Foundation

public struct SnapshotLimits: Sendable {
    public var maxNodes: Int
    public var maxDepth: Int
    /// Without a per-node cap, one long table can consume the entire node
    /// budget and push the rest of the window out of the snapshot.
    public var maxChildrenPerNode: Int

    public init(maxNodes: Int = 1500, maxDepth: Int = 64, maxChildrenPerNode: Int = 250) {
        self.maxNodes = max(1, maxNodes)
        self.maxDepth = max(1, maxDepth)
        self.maxChildrenPerNode = max(1, maxChildrenPerNode)
    }
}

/// Where a node came from, because the two sources carry very different
/// guarantees: an accessibility element can be re-resolved and re-verified
/// before it is acted on, while a recognised piece of text can only be trusted
/// as long as the capture it came from is fresh.
public enum NodeOrigin: String, Codable, Sendable {
    case accessibility
    case vision
}

/// One addressable element. `path` is the chain of child indices from the window
/// element down; it is what makes an index from an earlier snapshot re-resolvable
/// — and, when the UI has changed underneath it, detectably stale.
public struct SnapshotNode: Codable, Sendable {
    public let index: Int
    public let role: String
    public let subrole: String?
    /// AXIdentifier when the application publishes one. It is the only part of
    /// an element's identity that is meant to be stable across layout changes.
    public let identifier: String?
    public let label: String?
    public let value: String?
    public let enabled: Bool
    public let focused: Bool
    public let frame: FrameJSON?
    public let actions: [String]
    public let depth: Int
    public let path: [Int]
    /// Absent in snapshots written before optical fallback existed, which were
    /// all accessibility-derived.
    public var origin: NodeOrigin { originRaw ?? .accessibility }
    let originRaw: NodeOrigin?

    public init(
        index: Int,
        role: String,
        subrole: String?,
        identifier: String? = nil,
        label: String?,
        value: String?,
        enabled: Bool,
        focused: Bool,
        frame: FrameJSON?,
        actions: [String],
        depth: Int,
        path: [Int],
        origin: NodeOrigin = .accessibility
    ) {
        self.index = index
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.label = label
        self.value = value
        self.enabled = enabled
        self.focused = focused
        self.frame = frame
        self.actions = actions
        self.depth = depth
        self.path = path
        self.originRaw = origin
    }

    enum CodingKeys: String, CodingKey {
        case index, role, subrole, identifier, label, value, enabled, focused, frame, actions, depth, path
        case originRaw = "origin"
    }
}

public struct Snapshot: Codable, Sendable {
    public let app: AppInfo
    public let window: WindowInfo
    public let nodes: [SnapshotNode]
    public let focusedIndex: Int?
    public let truncated: Bool
    public let maxDepthReached: Bool
    /// Absent in snapshots written before the per-node cap existed.
    public var childrenTruncated: Bool { childrenTruncatedRaw ?? false }
    let childrenTruncatedRaw: Bool?
    /// Structural containers skipped by tree shaping. Absent in snapshots
    /// written before shaping existed, which hid nothing.
    public var elidedCount: Int { elidedCountRaw ?? 0 }
    let elidedCountRaw: Int?
    /// Table/outline/list rows dropped by viewport culling.
    public var rowsOmitted: Int { rowsOmittedRaw ?? 0 }
    let rowsOmittedRaw: Int?
    public let capturedAt: Date

    public init(
        app: AppInfo,
        window: WindowInfo,
        nodes: [SnapshotNode],
        focusedIndex: Int?,
        truncated: Bool,
        maxDepthReached: Bool,
        childrenTruncated: Bool = false,
        elidedCount: Int = 0,
        rowsOmitted: Int = 0,
        capturedAt: Date
    ) {
        self.app = app
        self.window = window
        self.nodes = nodes
        self.focusedIndex = focusedIndex
        self.truncated = truncated
        self.maxDepthReached = maxDepthReached
        self.childrenTruncatedRaw = childrenTruncated
        self.elidedCountRaw = elidedCount
        self.rowsOmittedRaw = rowsOmitted
        self.capturedAt = capturedAt
    }

    enum CodingKeys: String, CodingKey {
        case app, window, nodes, focusedIndex, truncated, maxDepthReached, capturedAt
        case childrenTruncatedRaw = "childrenTruncated"
        case elidedCountRaw = "elidedCount"
        case rowsOmittedRaw = "rowsOmitted"
    }

    /// Compact indented text, one line per element, sized for a model's context
    /// rather than for a human reading a debugger.
    public func renderText() -> String {
        var lines: [String] = []
        lines.append("app: \(app.name) [\(app.bundleID ?? "pid:\(app.pid)")]")
        let frame = window.frame
        lines.append("window: \(window.title ?? "(untitled)") id=\(window.windowID.map(String.init) ?? "?") frame=(\(Int(frame.x)),\(Int(frame.y)) \(Int(frame.width))x\(Int(frame.height)))")
        lines.append("coordinates: window-relative")
        for node in nodes {
            var parts: [String] = []
            parts.append(String(repeating: "  ", count: node.depth) + "\(node.index) \(shortRole(node.role))")
            if let subrole = node.subrole { parts.append("[\(shortRole(subrole))]") }
            if let label = node.label, !label.isEmpty { parts.append("\"\(truncate(label))\"") }
            if let value = node.value, !value.isEmpty { parts.append("= \"\(truncate(value))\"") }
            if !node.enabled { parts.append("(disabled)") }
            if node.focused { parts.append("(focused)") }
            if let frame = node.frame {
                parts.append("@\(Int(frame.x)),\(Int(frame.y)) \(Int(frame.width))x\(Int(frame.height))")
            }
            if node.origin == .vision { parts.append("(text)") }
            let extraActions = node.actions.filter { $0 != kAXPressAction as String }
            if !extraActions.isEmpty {
                parts.append("actions:" + extraActions.map { shortRole($0) }.joined(separator: ","))
            }
            lines.append(parts.joined(separator: " "))
        }
        if focusedIndex == nil { lines.append("(no element currently focused)") }
        if looksAccessibilityBlind {
            lines.append("(this window exposes no actionable accessibility elements — it may render its own interface; try `amcu scan` for an optical fallback)")
        }
        if truncated { lines.append("(truncated: node budget reached — narrow the target with --window-id)") }
        if maxDepthReached { lines.append("(truncated: depth budget reached)") }
        if childrenTruncated { lines.append("(truncated: some elements have more children than were listed)") }
        // Anything the shaping pass hid must be announced: a model reading a
        // silently thinned tree would conclude the missing rows do not exist.
        if elidedCount > 0 || rowsOmitted > 0 {
            var hidden: [String] = []
            if elidedCount > 0 { hidden.append("\(elidedCount) structural containers") }
            if rowsOmitted > 0 { hidden.append("\(rowsOmitted) offscreen rows") }
            lines.append("(hidden: " + hidden.joined(separator: ", ") + ")")
        }
        return lines.joined(separator: "\n")
    }

    /// True when the window publishes a hierarchy but nothing in it can be
    /// acted on — the signature of a canvas-rendered or otherwise
    /// accessibility-opaque interface. Reporting this is the difference between
    /// "this window is empty" and "amcu cannot see into this window".
    public var looksAccessibilityBlind: Bool {
        guard nodes.contains(where: { $0.origin == .accessibility }) else { return false }
        // `AXShowMenu` counts as actionable here for the same reason it saves a
        // node from elision (see `TreeShaping.elisionIgnoredActions`): a window
        // whose only affordance is context menus can still be driven through
        // `action --action AXShowMenu`, and calling it blind while the snapshot
        // lists that very action would be self-contradictory.
        let actionable = nodes.filter { node in
            node.origin == .accessibility
                && node.actions.contains { $0 != "AXRaise" && $0 != "AXScrollToVisible" }
        }
        return actionable.isEmpty
    }

    private func shortRole(_ role: String) -> String {
        role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }

    private func truncate(_ text: String, limit: Int = 80) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: "⏎")
        return flattened.count <= limit ? flattened : String(flattened.prefix(limit)) + "…"
    }
}

/// Hashable identity for an AXUIElement, so membership tests against a rows
/// list are set lookups instead of O(rows) CFEqual scans per child — a table
/// can hold thousands of rows and hundreds of children.
private struct AXIdentity: Hashable {
    let element: AXUIElement

    static func == (lhs: AXIdentity, rhs: AXIdentity) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

public enum SnapshotBuilder {
    public static func capture(
        app: AppInfo,
        window: WindowInfo,
        windowElement: AXUIElement,
        limits: SnapshotLimits = SnapshotLimits(),
        shaping: Bool = true
    ) -> Snapshot {
        var nodes: [SnapshotNode] = []
        var truncated = false
        var depthReached = false
        var childrenTruncated = false
        var elidedCount = 0
        var rowsOmitted = 0
        var focusedIndex: Int?
        let origin = window.frame.cgRect.origin

        func walk(_ element: AXUIElement, depth: Int, path: [Int], ancestors: [AXUIElement]) {
            if nodes.count >= limits.maxNodes { truncated = true; return }
            // The depth budget guards recursion, so it is measured against the
            // real hierarchy (`path` grows once per level regardless of
            // elision), while `depth` only drives indentation and skips elided
            // wrappers so the rendered tree has no phantom indent levels.
            if path.count > limits.maxDepth { depthReached = true; return }
            // Some hierarchies point back at an ancestor. Following one is an
            // unbounded recursion that ends in a stack overflow, not an error.
            if ancestors.contains(where: { CFEqual($0, element) }) { return }

            let role = AX.string(element, kAXRoleAttribute as String) ?? "AXUnknown"
            let focused = AX.bool(element, kAXFocusedAttribute as String) ?? false
            let nodeLabel = label(of: element)
            let nodeValue = redactedValue(of: element, role: role)
            let actions = AX.actions(element)

            // A meaningless wrapper is skipped but its subtree is not: the
            // children keep their real AXChildren indices in `path`, so
            // `resolve` — which replays the path over AXChildren — still lands
            // on the right element. The focused element is never elided, or
            // `focusedIndex` would have nothing to point at.
            let elided = shaping && !focused && TreeShaping.shouldElide(role: role, label: nodeLabel, value: nodeValue, actions: actions)
            var childDepth = depth
            if elided {
                elidedCount += 1
            } else {
                var frame: FrameJSON?
                if let absolute = AX.frame(element) {
                    // Window-relative so that moving the window does not invalidate
                    // every coordinate in a snapshot the caller is still holding.
                    frame = FrameJSON(CGRect(
                        x: absolute.origin.x - origin.x,
                        y: absolute.origin.y - origin.y,
                        width: absolute.size.width,
                        height: absolute.size.height
                    ))
                }
                let index = nodes.count
                if focused { focusedIndex = index }
                nodes.append(SnapshotNode(
                    index: index,
                    role: role,
                    subrole: AX.string(element, kAXSubroleAttribute as String),
                    identifier: AX.string(element, "AXIdentifier"),
                    label: nodeLabel,
                    value: nodeValue,
                    enabled: AX.bool(element, kAXEnabledAttribute as String) ?? true,
                    focused: focused,
                    frame: frame,
                    actions: actions,
                    depth: depth,
                    path: path
                ))
                if shaping, TreeShaping.shouldSuppressChildren(role: role, label: nodeLabel) {
                    // Suppression must yield to focus for the same reason
                    // elision does: a hidden focused element leaves
                    // `focusedIndex` with nothing to point at. Only direct
                    // children are probed — the focused control inside a
                    // compact wrapper (a combo box's editable text field) is
                    // a direct child in AppKit, and a full subtree search
                    // would cost exactly the traversal suppression exists to
                    // avoid. A focus buried deeper stays hidden; that is the
                    // accepted trade-off.
                    let focusYields = AX.children(element).contains {
                        AX.bool($0, kAXFocusedAttribute as String) ?? false
                    }
                    if !focusYields { return }
                }
                childDepth = depth + 1
            }

            let children = AX.children(element)
            var kept = Array(children.enumerated())
            if shaping, TreeShaping.usesRowViewport(role: role),
               let rows = AX.attribute(element, "AXRows") as? [AXUIElement],
               !rows.isEmpty {
                // AXRows indexes a different space than AXChildren, so row
                // indices must never leak into `path`. The rows list is used
                // only to decide *which* elements to keep; the walk below
                // still iterates AXChildren, so every recorded path index is
                // an AXChildren index and `resolve` stays correct.
                //
                // Which rows count as visible, in order of trust:
                // 1. `AXVisibleRows` — the toolkit's own answer to exactly
                //    this question; no geometry needed.
                // 2. Rows intersecting the nearest AXScrollArea ancestor's
                //    frame. The table's *own* frame is useless as a viewport:
                //    an NSTableView is the scroll view's document view, so
                //    its AX frame spans all content including everything
                //    scrolled offscreen — every row intersects it, and
                //    culling against it keeps the first rows in AXRows order
                //    instead of the rows on screen. The scroll area is the
                //    clip through which the user actually looks.
                // 3. Neither available: cull nothing. A wrong cull shows the
                //    model rows the user cannot see and hides the ones they
                //    can, which is strictly worse than a big snapshot.
                let visible: [AXUIElement]?
                if let toolkitVisible = AX.attribute(element, "AXVisibleRows") as? [AXUIElement],
                   !toolkitVisible.isEmpty {
                    visible = toolkitVisible
                } else if let viewport = nearestScrollAreaFrame(ancestors: ancestors) {
                    visible = rows.filter { row in
                        guard let rowFrame = AX.frame(row) else { return false }
                        return rowFrame.intersects(viewport)
                    }
                } else {
                    visible = nil
                }
                if let visible {
                    let allRows = Set(rows.map(AXIdentity.init))
                    let keptRows = Set(visible.prefix(TreeShaping.maxVisibleRows).map(AXIdentity.init))
                    let beforeCull = kept.count
                    kept = kept.filter { _, child in
                        let identity = AXIdentity(element: child)
                        // Non-row children (headers, columns, scrollers) pass through.
                        return !allRows.contains(identity) || keptRows.contains(identity)
                    }
                    // Counted from children actually dropped, not from
                    // `rows.count`: an outline nests rows under rows, so not
                    // every AXRows entry is a direct child, and the footer
                    // must never claim culling that did not happen.
                    rowsOmitted += beforeCull - kept.count
                }
            }
            // The per-node cap counts surviving children, not raw ones —
            // otherwise a table scrolled past its first few hundred rows
            // would have its visible rows capped away with the culled ones.
            if kept.count > limits.maxChildrenPerNode { childrenTruncated = true }
            let lineage = ancestors + [element]
            for (childIndex, child) in kept.prefix(limits.maxChildrenPerNode) {
                walk(child, depth: childDepth, path: path + [childIndex], ancestors: lineage)
            }
        }

        walk(windowElement, depth: 0, path: [], ancestors: [])

        return Snapshot(
            app: app,
            window: window,
            nodes: nodes,
            focusedIndex: focusedIndex,
            truncated: truncated,
            maxDepthReached: depthReached,
            childrenTruncated: childrenTruncated,
            elidedCount: elidedCount,
            rowsOmitted: rowsOmitted,
            capturedAt: Date()
        )
    }

    /// The frame of the innermost AXScrollArea above a row container. The
    /// *innermost* one, because scroll views nest (a table inside a scrollable
    /// inspector pane) and only the nearest clip decides which rows are on
    /// screen; an outer one would admit rows the inner clip hides.
    private static func nearestScrollAreaFrame(ancestors: [AXUIElement]) -> CGRect? {
        for ancestor in ancestors.reversed() {
            guard AX.string(ancestor, kAXRoleAttribute as String) == "AXScrollArea" else { continue }
            return AX.frame(ancestor)
        }
        return nil
    }

    /// Wraps recognised text in the same snapshot shape as accessibility
    /// elements, so a caller addresses either kind with `--element N`.
    public static func fromVision(
        app: AppInfo,
        window: WindowInfo,
        marks: [VisionMark]
    ) -> Snapshot {
        let nodes = marks.enumerated().map { index, mark in
            SnapshotNode(
                index: index,
                role: "AmcuText",
                subrole: nil,
                identifier: nil,
                label: mark.text,
                value: nil,
                enabled: true,
                focused: false,
                frame: FrameJSON(mark.frame),
                actions: [],
                depth: 0,
                path: [],
                origin: .vision
            )
        }
        return Snapshot(
            app: app,
            window: window,
            nodes: nodes,
            focusedIndex: nil,
            truncated: false,
            maxDepthReached: false,
            capturedAt: Date()
        )
    }

    /// AppKit's own secure fields publish no value, but nothing guarantees that
    /// for a custom control, a web input or an Electron form. A snapshot is
    /// handed straight to a model and often into a transcript, so anything that
    /// announces itself as secret-bearing has its value withheld rather than
    /// trusted to be masked at the source.
    static func redactedValue(of element: AXUIElement, role: String) -> String? {
        guard let value = AX.string(element, kAXValueAttribute as String), !value.isEmpty else { return nil }
        let descriptors = [
            role,
            AX.string(element, kAXSubroleAttribute as String),
            AX.string(element, kAXTitleAttribute as String),
            AX.string(element, kAXDescriptionAttribute as String),
            AX.string(element, kAXPlaceholderValueAttribute as String),
            AX.string(element, "AXIdentifier")
        ].compactMap { $0 }
        return Redaction.holdsSecret(descriptors: descriptors) ? Redaction.placeholder : value
    }

    static func label(of element: AXUIElement) -> String? {
        for attribute in [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            "AXLabel",
            kAXHelpAttribute as String
        ] {
            if let text = AX.string(element, attribute), !text.isEmpty { return text }
        }
        return nil
    }

    /// Re-resolves a recorded node against the live hierarchy, refusing to act
    /// when the element at that path is no longer the one that was described.
    /// A snapshot index is a promise about what is there; this is where the
    /// promise gets checked instead of silently clicking the wrong control.
    public static func resolve(node: SnapshotNode, windowElement: AXUIElement) throws -> AXUIElement {
        guard node.origin == .accessibility else {
            throw AmcuError(.unsupported, "element \(node.index) came from an optical scan and has no accessibility element behind it", nextSteps: [
                "Optically located targets can only be clicked by coordinate; that is what `amcu click --element` does for them automatically.",
                "This error means something asked for a semantic action on recognised text."
            ])
        }
        var current = windowElement
        for step in node.path {
            let children = AX.children(current)
            guard step < children.count else {
                throw AmcuError(.staleSnapshot, "element \(node.index) no longer exists at its recorded position", nextSteps: [
                    "Re-run `amcu snapshot` and use the new indices.",
                    "Snapshot indices are only valid until the interface changes."
                ])
            }
            current = children[step]
        }
        let role = AX.string(current, kAXRoleAttribute as String) ?? "AXUnknown"
        guard role == node.role else {
            throw AmcuError(.staleSnapshot, "element \(node.index) changed role (\(node.role) -> \(role))", nextSteps: [
                "Re-run `amcu snapshot`; the interface changed after it was captured."
            ])
        }
        let subrole = AX.string(current, kAXSubroleAttribute as String)
        guard subrole == node.subrole else {
            throw AmcuError(.staleSnapshot, "element \(node.index) changed subrole (\(node.subrole ?? "none") -> \(subrole ?? "none"))", nextSteps: [
                "Re-run `amcu snapshot`; the interface changed after it was captured."
            ])
        }
        // An identifier is the strongest signal available, so when the
        // application publishes one it decides the question on its own.
        let identifier = AX.string(current, "AXIdentifier")
        guard identifier == node.identifier else {
            throw AmcuError(.staleSnapshot, "element \(node.index) changed identifier (\(node.identifier ?? "none") -> \(identifier ?? "none"))", nextSteps: [
                "Re-run `amcu snapshot`; the interface changed after it was captured."
            ])
        }
        // Compared as optionals: a label appearing or disappearing is as much a
        // change of identity as a label being edited, and skipping the check
        // when either side is nil would let an unlabelled element of the same
        // role silently take the place of the one that was described.
        let currentLabel = label(of: current)
        if node.label != currentLabel {
            let recorded = node.label.map { "\"\($0)\"" } ?? "no label"
            let live = currentLabel.map { "\"\($0)\"" } ?? "no label"
            throw AmcuError(.staleSnapshot, "element \(node.index) changed label (\(recorded) -> \(live))", nextSteps: [
                "Re-run `amcu snapshot`; the interface changed after it was captured."
            ])
        }
        return current
    }
}
