import Foundation

/// Element identity across snapshots, index reuse, diffs and query filtering.
///
/// An index is stable for as long as the element it names keeps the same
/// identity: role, subrole, AXIdentifier and label, its ordinal among
/// same-looking siblings, and the same for every ancestor. Value, state and
/// frame are excluded on purpose — a field whose text changed is the *same*
/// field, and the diff reports it as changed rather than as removed+added.
public enum SnapshotIdentity {
    /// FNV-1a; `Hasher` is seeded per process and identities must survive a
    /// round trip through the session file.
    static func fnv(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func key(role: String, subrole: String?, identifier: String?, label: String?) -> String {
        [role, subrole ?? "", identifier ?? "", label ?? ""].joined(separator: "\u{1f}")
    }

    /// Identities for nodes in tree order, using `depth` to find each node's
    /// rendered parent.
    public static func assign(
        roles: [(role: String, subrole: String?, identifier: String?, label: String?, depth: Int)]
    ) -> [String] {
        var out: [String] = []
        out.reserveCapacity(roles.count)
        // stack[d] = (identity of the open node at depth d, sibling key counts under it)
        var stack: [(identity: String, ordinals: [String: Int])] = []
        for node in roles {
            while stack.count > node.depth { stack.removeLast() }
            let key = key(role: node.role, subrole: node.subrole, identifier: node.identifier, label: node.label)
            let parent = stack.last?.identity ?? ""
            var ordinal = 0
            if !stack.isEmpty {
                ordinal = stack[stack.count - 1].ordinals[key, default: 0]
                stack[stack.count - 1].ordinals[key] = ordinal + 1
            }
            let identity = fnv(parent + "/" + key + "#" + String(ordinal))
            out.append(identity)
            stack.append((identity, [:]))
        }
        return out
    }

    /// Chooses the index each new node gets. Matching identities keep their
    /// previous index; new nodes continue after the previous maximum so a
    /// removed index is never recycled within one session. When too little
    /// matches (a different window, or the interface was rebuilt) numbering
    /// restarts at 0 and the caller shows a full snapshot instead of a diff.
    public static func reuseIndices(identities: [String], previous: Snapshot?) -> (indices: [Int], continued: Bool) {
        guard let previous, previous.nodes.contains(where: { $0.origin == .accessibility }) else {
            return (Array(0..<identities.count), false)
        }
        var previousIndex: [String: Int] = [:]
        for node in previous.nodes { if let identity = node.identity { previousIndex[identity] = node.index } }
        guard !previousIndex.isEmpty else { return (Array(0..<identities.count), false) }
        let matched = identities.filter { previousIndex[$0] != nil }.count
        let enough = identities.count <= 20 ? matched > 0 : Double(matched) >= 0.4 * Double(identities.count)
        guard enough else { return (Array(0..<identities.count), false) }
        var next = (previous.nodes.map(\.index).max() ?? -1) + 1
        var used = Set<Int>()
        var out: [Int] = []
        for identity in identities {
            if let index = previousIndex[identity], !used.contains(index) {
                out.append(index)
                used.insert(index)
            } else {
                out.append(next)
                used.insert(next)
                next += 1
            }
        }
        return (out, true)
    }
}

public struct SnapshotDiff: Codable, Sendable {
    public let changed: Int
    public let added: Int
    public let removed: Int
    public let text: String
    /// True when the change was too large to express as a diff and `text`
    /// holds the full snapshot instead.
    public let full: Bool

    public init(changed: Int, added: Int, removed: Int, text: String, full: Bool) {
        self.changed = changed; self.added = added; self.removed = removed; self.text = text; self.full = full
    }

    public var isEmpty: Bool { changed == 0 && added == 0 && removed == 0 && !full }
}

extension Snapshot {
    /// True when `previous` describes the same window, captured with the same
    /// shaping, so its indices are comparable with this snapshot's.
    public func isComparable(with previous: Snapshot) -> Bool {
        previous.app.pid == app.pid
            && previous.window.windowID == window.windowID
            && previous.window.index == window.index
            && previous.shaped == shaped
            && !previous.nodes.contains(where: { $0.origin == .vision })
            && !nodes.contains(where: { $0.origin == .vision })
    }

    /// Lines that differ from `previous`. `~` changed, `+` added, `- [a..b]`
    /// removed by index range. A change touching more than 60 % of the tree
    /// is rendered as a full snapshot, because a diff that size is harder to
    /// read than the tree itself.
    public func diff(from previous: Snapshot, maxLines: Int = 400) -> SnapshotDiff {
        guard isComparable(with: previous), indicesContinued else {
            return SnapshotDiff(changed: 0, added: 0, removed: 0, text: "# interface changed too much for a diff; full snapshot follows\n" + renderText(), full: true)
        }
        var old: [Int: SnapshotNode] = [:]
        for node in previous.nodes { old[node.index] = node }
        var lines: [String] = []
        var changed = 0, added = 0
        var seen = Set<Int>()
        for node in nodes {
            seen.insert(node.index)
            if let before = old[node.index] {
                if before.changeSignature != node.changeSignature {
                    lines.append("~ " + renderLine(node))
                    changed += 1
                }
            } else {
                lines.append("+ " + renderLine(node))
                added += 1
            }
        }
        let removedIndices = previous.nodes.map(\.index).filter { !seen.contains($0) }.sorted()
        if !removedIndices.isEmpty { lines.append("- " + Snapshot.ranges(removedIndices)) }
        let indexed = nodes.count
        if indexed > 20, Double(changed + added) > 0.6 * Double(indexed) {
            return SnapshotDiff(changed: changed, added: added, removed: removedIndices.count, text: "# interface changed too much for a diff; full snapshot follows\n" + renderText(), full: true)
        }
        if lines.isEmpty {
            var text = "# no change since the previous snapshot"
            if truncated { text += " (truncated: node budget reached)" }
            return SnapshotDiff(changed: 0, added: 0, removed: 0, text: text, full: false)
        }
        var body = lines
        if body.count > maxLines {
            let extra = body.count - maxLines
            body = Array(body.prefix(maxLines)) + ["… \(extra) more changed lines omitted; take a full `amcu snapshot`, or narrow with --query"]
        }
        let header = "# diff vs previous snapshot: ~\(changed) changed, +\(added) added, -\(removedIndices.count) removed"
        var text = ([header] + body).joined(separator: "\n")
        if truncated { text += "\n(truncated: node budget reached)" }
        return SnapshotDiff(changed: changed, added: added, removed: removedIndices.count, text: text, full: false)
    }

    public static func ranges(_ sorted: [Int]) -> String {
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(j > i ? "[\(sorted[i])..\(sorted[j])]" : "[\(sorted[i])]")
            i = j + 1
        }
        return parts.joined(separator: " ")
    }

    /// Nodes whose role, label or value matches `query` (case-insensitive
    /// substring, or `/regex/`), plus every ancestor so the hierarchy stays
    /// readable. Ancestors are found through `depth`: the nearest earlier
    /// node with a smaller depth.
    public func filtered(query: String) throws -> (kept: [SnapshotNode], matches: Int) {
        let matcher: (String) -> Bool
        if query.count >= 2, query.hasPrefix("/"), query.hasSuffix("/") {
            let pattern = String(query.dropFirst().dropLast())
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                throw AmcuError(.invalidArgument, "--query '\(query)' is not a valid regular expression")
            }
            matcher = { text in regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        } else {
            let needle = query.lowercased()
            matcher = { $0.lowercased().contains(needle) }
        }
        var keep = [Bool](repeating: false, count: nodes.count)
        var matches = 0
        for (position, node) in nodes.enumerated() {
            let fields = [node.role, node.subrole, node.label, node.value, node.identifier].compactMap { $0 }
            guard fields.contains(where: matcher) else { continue }
            matches += 1
            keep[position] = true
            var depth = node.depth
            var cursor = position - 1
            while cursor >= 0, depth > 0 {
                if nodes[cursor].depth < depth {
                    keep[cursor] = true
                    depth = nodes[cursor].depth
                }
                cursor -= 1
            }
        }
        return (nodes.enumerated().filter { keep[$0.offset] }.map(\.element), matches)
    }
}

extension SnapshotNode {
    /// What a `~` line reacts to. Frame is excluded: scrolling moves every
    /// element and would turn each diff into the whole tree.
    var changeSignature: String {
        [role, subrole ?? "", label ?? "", value ?? "", enabled ? "1" : "0", focused ? "1" : "0", actions.joined(separator: ",")].joined(separator: "\u{1f}")
    }
}
