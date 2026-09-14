import CoreGraphics
import Foundation
import AmcuCore

func runSnapshotDiffTests(_ t: Harness) {
    t.suite("element identity and index reuse")

    func node(_ index: Int, _ role: String, _ label: String?, depth: Int, value: String? = nil, identity: String? = nil) -> SnapshotNode {
        SnapshotNode(index: index, role: role, subrole: nil, identifier: nil, label: label, value: value, enabled: true, focused: false,
                     frame: nil, actions: ["AXPress"], depth: depth, path: [], identity: identity)
    }
    func snapshot(_ nodes: [SnapshotNode], windowID: CGWindowID? = 42, continued: Bool = true, shaped: Bool = true) -> Snapshot {
        Snapshot(
            app: AppInfo(pid: 1, name: "Test", bundleID: "com.example.test", active: false, hasWindows: true),
            window: WindowInfo(windowID: windowID, index: 0, title: "W", frame: FrameJSON(CGRect(x: 0, y: 0, width: 10, height: 10)), minimized: false, main: true),
            nodes: nodes, focusedIndex: nil, truncated: false, maxDepthReached: false, capturedAt: Date(),
            shaped: shaped, maxNodes: 1500, indicesContinued: continued
        )
    }
    /// Builds a snapshot the way `SnapshotBuilder.capture` does: identities
    /// from the tree, indices reused from `previous`.
    func build(_ shape: [(role: String, label: String?, depth: Int, value: String?)], previous: Snapshot?) -> Snapshot {
        let identities = SnapshotIdentity.assign(roles: shape.map { ($0.role, nil, nil, $0.label, $0.depth) })
        let (indices, continued) = SnapshotIdentity.reuseIndices(identities: identities, previous: previous)
        let nodes = shape.enumerated().map { position, item in
            node(indices[position], item.role, item.label, depth: item.depth, value: item.value, identity: identities[position])
        }
        return snapshot(nodes, continued: continued)
    }

    do {
        let a = SnapshotIdentity.assign(roles: [("AXWindow", nil, nil, "W", 0), ("AXButton", nil, nil, "OK", 1), ("AXButton", nil, nil, "OK", 1)])
        t.expect(a[1] != a[2], "two same-looking siblings get distinct identities (ordinal)")
        let b = SnapshotIdentity.assign(roles: [("AXWindow", nil, nil, "W", 0), ("AXButton", nil, nil, "OK", 1), ("AXButton", nil, nil, "OK", 1)])
        t.expectEqual(a, b, "identities are deterministic across runs")
        let c = SnapshotIdentity.assign(roles: [("AXWindow", nil, nil, "W", 0), ("AXGroup", nil, nil, nil, 1), ("AXButton", nil, nil, "OK", 2)])
        t.expect(c[2] != a[1], "the same control under a different parent has a different identity")
    }

    do {
        let first = build([("AXWindow", "W", 0, nil), ("AXTextField", "Name", 1, ""), ("AXButton", "Save", 1, nil)], previous: nil)
        t.expectEqual(first.nodes.map(\.index), [0, 1, 2], "a first capture numbers from zero")
        t.expect(!first.indicesContinued, "a first capture does not claim to continue anything")

        // Same tree, value changed: same indices, `~` in the diff.
        let second = build([("AXWindow", "W", 0, nil), ("AXTextField", "Name", 1, "Ada"), ("AXButton", "Save", 1, nil)], previous: first)
        t.expectEqual(second.nodes.map(\.index), [0, 1, 2], "matching elements keep their indices")
        t.expect(second.indicesContinued, "a matching capture continues the numbering")
        let d = second.diff(from: first)
        t.expectEqual(d.changed, 1, "a changed value is one changed line")
        t.expect(d.text.contains("~   1 TextField \"Name\" = \"Ada\""), "the changed line carries the stable index")

        // A new element inserted before an old one: the old one keeps 2, the new one gets 3.
        let third = build([("AXWindow", "W", 0, nil), ("AXTextField", "Name", 1, "Ada"), ("AXButton", "Cancel", 1, nil), ("AXButton", "Save", 1, nil)], previous: second)
        t.expectEqual(third.nodes.map(\.index), [0, 1, 3, 2], "an inserted element gets a fresh index and does not shift the others")
        let d2 = third.diff(from: second)
        t.expectEqual(d2.added, 1, "an insertion is one added line")
        t.expectEqual(d2.changed, 0, "an insertion changes nothing else")
        t.expect(d2.text.contains("+   3 Button \"Cancel\""), "the added line carries the new index")

        // Removal is summarised by index range.
        let fourth = build([("AXWindow", "W", 0, nil), ("AXTextField", "Name", 1, "Ada")], previous: third)
        let d3 = fourth.diff(from: third)
        t.expectEqual(d3.removed, 2, "two removed elements are counted")
        t.expect(d3.text.contains("- [2..3]"), "consecutive removed indices collapse into a range")

        let same = build([("AXWindow", "W", 0, nil), ("AXTextField", "Name", 1, "Ada")], previous: fourth)
        t.expect(same.diff(from: fourth).isEmpty, "an identical capture diffs to nothing")
        t.expect(same.diff(from: fourth).text.hasPrefix("# no change"), "no change is stated in one line")
    }

    do {
        // A different window restarts numbering and refuses to diff.
        let first = build([("AXWindow", "W", 0, nil), ("AXButton", "Save", 1, nil)], previous: nil)
        let other = build([("AXWindow", "Other", 0, nil), ("AXButton", "Go", 1, nil)], previous: first)
        t.expect(!other.indicesContinued, "a rebuilt interface restarts numbering")
        t.expect(other.diff(from: first).full, "a non-continued snapshot is shown in full rather than diffed")
    }

    t.expectEqual(Snapshot.ranges([1, 2, 3, 7, 9, 10]), "[1..3] [7] [9..10]", "index ranges collapse runs")

    t.suite("snapshot --query")
    do {
        let s = snapshot([
            node(0, "AXWindow", "W", depth: 0),
            node(1, "AXGroup", nil, depth: 1),
            node(2, "AXButton", "Save", depth: 2),
            node(3, "AXButton", "Cancel", depth: 2),
            node(4, "AXTextField", "Search", depth: 1, value: "save later")
        ])
        let (kept, matches) = try! s.filtered(query: "save")
        t.expectEqual(matches, 2, "substring query matches labels and values, case-insensitively")
        t.expectEqual(kept.map(\.index), [0, 1, 2, 4], "ancestors are kept, siblings are not")
        let (regex, rmatches) = try! s.filtered(query: "/^AXButton$/")
        t.expectEqual(rmatches, 2, "a /regex/ query matches roles")
        t.expectEqual(regex.map(\.index), [0, 1, 2, 3], "regex results keep the hierarchy")
        t.expectThrows("an invalid regex is refused") { _ = try s.filtered(query: "/[/") }
    }

    t.suite("policy file")
    do {
        let p = Policy.parse([
            "sensitive": ["deny": ["com.example.vault"], "allow": ["com.apple.Passwords"]],
            "immune": ["com.example.wall"],
            "settle": ["min": 0.1, "quiet": 99, "max": 0]
        ])
        t.expectEqual(p.sensitiveDeny, ["com.example.vault"], "deny list is read")
        t.expectEqual(p.sensitiveAllow, ["com.apple.Passwords"], "allow list is read")
        t.expectEqual(p.immune, ["com.example.wall"], "immune list is read")
        t.expectEqual(p.settle.min, 0.1, "settle.min is read")
        t.expectEqual(p.settle.quiet, 5, "settle.quiet is clamped to its ceiling")
        t.expectEqual(p.settle.max, 0.2, "settle.max is clamped to its floor")
        let empty = Policy.parse([:])
        t.expectEqual(empty.settle.quiet, 0.3, "an empty policy keeps defaults")
    }

    t.suite("event tagging")
    if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
        t.expect(!EventTag.isOurs(event), "a fresh event is not recognised as ours")
        EventTag.stamp(event)
        t.expect(EventTag.isOurs(event), "a stamped event is recognised as ours")
    }
}
