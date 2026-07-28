import ApplicationServices
import CoreGraphics
import Foundation

public struct SnapshotLimits: Sendable {
    public var maxNodes: Int
    public var maxDepth: Int

    public init(maxNodes: Int = 1500, maxDepth: Int = 64) {
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
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
    public let capturedAt: Date

    public init(
        app: AppInfo,
        window: WindowInfo,
        nodes: [SnapshotNode],
        focusedIndex: Int?,
        truncated: Bool,
        maxDepthReached: Bool,
        capturedAt: Date
    ) {
        self.app = app
        self.window = window
        self.nodes = nodes
        self.focusedIndex = focusedIndex
        self.truncated = truncated
        self.maxDepthReached = maxDepthReached
        self.capturedAt = capturedAt
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
            lines.append("(this window exposes no actionable accessibility elements — it may render its own interface; try `umbra scan` for an optical fallback)")
        }
        if truncated { lines.append("(truncated: node budget reached — narrow the target with --window-id)") }
        if maxDepthReached { lines.append("(truncated: depth budget reached)") }
        return lines.joined(separator: "\n")
    }

    /// True when the window publishes a hierarchy but nothing in it can be
    /// acted on — the signature of a canvas-rendered or otherwise
    /// accessibility-opaque interface. Reporting this is the difference between
    /// "this window is empty" and "umbra cannot see into this window".
    public var looksAccessibilityBlind: Bool {
        guard nodes.contains(where: { $0.origin == .accessibility }) else { return false }
        let actionable = nodes.filter { node in
            node.origin == .accessibility
                && node.actions.contains { $0 != "AXShowMenu" && $0 != "AXRaise" && $0 != "AXScrollToVisible" }
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

public enum SnapshotBuilder {
    public static func capture(
        app: AppInfo,
        window: WindowInfo,
        windowElement: AXUIElement,
        limits: SnapshotLimits = SnapshotLimits()
    ) -> Snapshot {
        var nodes: [SnapshotNode] = []
        var truncated = false
        var depthReached = false
        var focusedIndex: Int?
        let origin = window.frame.cgRect.origin

        func walk(_ element: AXUIElement, depth: Int, path: [Int]) {
            if nodes.count >= limits.maxNodes { truncated = true; return }
            if depth > limits.maxDepth { depthReached = true; return }

            let role = AX.string(element, kAXRoleAttribute as String) ?? "AXUnknown"
            let focused = AX.bool(element, kAXFocusedAttribute as String) ?? false
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
                label: label(of: element),
                value: AX.string(element, kAXValueAttribute as String),
                enabled: AX.bool(element, kAXEnabledAttribute as String) ?? true,
                focused: focused,
                frame: frame,
                actions: AX.actions(element),
                depth: depth,
                path: path
            ))

            for (childIndex, child) in AX.children(element).enumerated() {
                walk(child, depth: depth + 1, path: path + [childIndex])
            }
        }

        walk(windowElement, depth: 0, path: [])

        return Snapshot(
            app: app,
            window: window,
            nodes: nodes,
            focusedIndex: focusedIndex,
            truncated: truncated,
            maxDepthReached: depthReached,
            capturedAt: Date()
        )
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
                role: "UmbraText",
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
            throw UmbraError(.unsupported, "element \(node.index) came from an optical scan and has no accessibility element behind it", nextSteps: [
                "Optically located targets can only be clicked by coordinate; that is what `umbra click --element` does for them automatically.",
                "This error means something asked for a semantic action on recognised text."
            ])
        }
        var current = windowElement
        for step in node.path {
            let children = AX.children(current)
            guard step < children.count else {
                throw UmbraError(.staleSnapshot, "element \(node.index) no longer exists at its recorded position", nextSteps: [
                    "Re-run `umbra snapshot` and use the new indices.",
                    "Snapshot indices are only valid until the interface changes."
                ])
            }
            current = children[step]
        }
        let role = AX.string(current, kAXRoleAttribute as String) ?? "AXUnknown"
        guard role == node.role else {
            throw UmbraError(.staleSnapshot, "element \(node.index) changed role (\(node.role) -> \(role))", nextSteps: [
                "Re-run `umbra snapshot`; the interface changed after it was captured."
            ])
        }
        let subrole = AX.string(current, kAXSubroleAttribute as String)
        guard subrole == node.subrole else {
            throw UmbraError(.staleSnapshot, "element \(node.index) changed subrole (\(node.subrole ?? "none") -> \(subrole ?? "none"))", nextSteps: [
                "Re-run `umbra snapshot`; the interface changed after it was captured."
            ])
        }
        // An identifier is the strongest signal available, so when the
        // application publishes one it decides the question on its own.
        let identifier = AX.string(current, "AXIdentifier")
        guard identifier == node.identifier else {
            throw UmbraError(.staleSnapshot, "element \(node.index) changed identifier (\(node.identifier ?? "none") -> \(identifier ?? "none"))", nextSteps: [
                "Re-run `umbra snapshot`; the interface changed after it was captured."
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
            throw UmbraError(.staleSnapshot, "element \(node.index) changed label (\(recorded) -> \(live))", nextSteps: [
                "Re-run `umbra snapshot`; the interface changed after it was captured."
            ])
        }
        return current
    }
}
