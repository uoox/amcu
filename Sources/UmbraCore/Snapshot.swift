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

/// One addressable element. `path` is the chain of child indices from the window
/// element down; it is what makes an index from an earlier snapshot re-resolvable
/// — and, when the UI has changed underneath it, detectably stale.
public struct SnapshotNode: Codable, Sendable {
    public let index: Int
    public let role: String
    public let subrole: String?
    public let label: String?
    public let value: String?
    public let enabled: Bool
    public let focused: Bool
    public let frame: FrameJSON?
    public let actions: [String]
    public let depth: Int
    public let path: [Int]

    public init(
        index: Int,
        role: String,
        subrole: String?,
        label: String?,
        value: String?,
        enabled: Bool,
        focused: Bool,
        frame: FrameJSON?,
        actions: [String],
        depth: Int,
        path: [Int]
    ) {
        self.index = index
        self.role = role
        self.subrole = subrole
        self.label = label
        self.value = value
        self.enabled = enabled
        self.focused = focused
        self.frame = frame
        self.actions = actions
        self.depth = depth
        self.path = path
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
            let extraActions = node.actions.filter { $0 != kAXPressAction as String }
            if !extraActions.isEmpty {
                parts.append("actions:" + extraActions.map { shortRole($0) }.joined(separator: ","))
            }
            lines.append(parts.joined(separator: " "))
        }
        if focusedIndex == nil { lines.append("(no element currently focused)") }
        if truncated { lines.append("(truncated: node budget reached — narrow the target with --window-id)") }
        if maxDepthReached { lines.append("(truncated: depth budget reached)") }
        return lines.joined(separator: "\n")
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
        let currentLabel = label(of: current)
        if let recorded = node.label, let live = currentLabel, recorded != live {
            throw UmbraError(.staleSnapshot, "element \(node.index) changed label (\"\(recorded)\" -> \"\(live)\")", nextSteps: [
                "Re-run `umbra snapshot`; the interface changed after it was captured."
            ])
        }
        return current
    }
}
