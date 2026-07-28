import CoreGraphics
import Foundation
import UmbraCore

/// Tree-shaping policy tests. Defined here and wired into main.swift by the
/// runner, so this file stays additive while other work touches main.swift.
func runTreeShapingTests(_ t: Harness) {
    t.suite("tree shaping: elision")

    // The whole point of elision is anonymous wrapper groups; a group that
    // says or does anything is information, not scaffolding.
    t.expect(
        TreeShaping.shouldElide(role: "AXGroup", label: nil, value: nil, actions: []),
        "a bare group is elided"
    )
    t.expect(
        TreeShaping.shouldElide(role: "AXUnknown", label: "", value: "", actions: []),
        "empty strings count as no label and no value"
    )
    t.expect(
        TreeShaping.shouldElide(role: "AXSplitGroup", label: nil, value: nil, actions: ["AXScrollToVisible", "AXRaise"]),
        "presentational actions do not save a group from elision"
    )
    t.expect(
        !TreeShaping.shouldElide(role: "AXGroup", label: "Sidebar", value: nil, actions: []),
        "a labelled group is kept"
    )
    t.expect(
        !TreeShaping.shouldElide(role: "AXGroup", label: nil, value: "3 items", actions: []),
        "a group with a value is kept"
    )
    t.expect(
        !TreeShaping.shouldElide(role: "AXGroup", label: nil, value: nil, actions: ["AXPress"]),
        "a pressable group is kept"
    )
    t.expect(
        !TreeShaping.shouldElide(role: "AXButton", label: nil, value: nil, actions: []),
        "elision only applies to structural roles"
    )

    t.suite("tree shaping: child suppression")

    t.expect(
        TreeShaping.shouldSuppressChildren(role: "AXButton", label: "Save"),
        "a labelled button's subtree is cut"
    )
    // An unlabelled button's inner text may be the only thing that names it.
    t.expect(
        !TreeShaping.shouldSuppressChildren(role: "AXButton", label: nil),
        "an unlabelled button is still expanded"
    )
    t.expect(
        !TreeShaping.shouldSuppressChildren(role: "AXCheckBox", label: ""),
        "an empty label does not count as a label for suppression"
    )
    t.expect(
        TreeShaping.shouldSuppressChildren(role: "AXStaticText", label: nil),
        "static text is never expanded — its content lives in its value"
    )
    t.expect(
        TreeShaping.shouldSuppressChildren(role: "AXMenuBarItem", label: nil),
        "a menu bar item is never expanded, labelled or not"
    )
    t.expect(
        !TreeShaping.shouldSuppressChildren(role: "AXGroup", label: "Toolbar"),
        "suppression does not apply to container roles"
    )
    for role in ["AXComboBox", "AXPopUpButton", "AXRadioButton", "AXMenuItem", "AXDisclosureTriangle"] {
        t.expect(
            TreeShaping.shouldSuppressChildren(role: role, label: "x"),
            "\(role) with a label is cut"
        )
    }

    t.suite("tree shaping: viewport and actions")

    for role in ["AXTable", "AXOutline", "AXList"] {
        t.expect(TreeShaping.usesRowViewport(role: role), "\(role) is row-viewport culled")
    }
    t.expect(!TreeShaping.usesRowViewport(role: "AXScrollArea"), "a scroll area is not row-culled itself")
    t.expectEqual(TreeShaping.maxVisibleRows, 20, "at most 20 rows survive culling")

    t.expectEqual(
        TreeShaping.meaningfulActions(["AXPress", "AXScrollToVisible", "AXRaise", "AXShowMenu", "AXConfirm"]),
        ["AXPress", "AXConfirm"],
        "presentational actions are filtered, real ones kept in order"
    )
    t.expectEqual(TreeShaping.meaningfulActions([]), [], "no actions filter to no actions")

    t.suite("tree shaping: snapshot accounting")

    func statsSnapshot(elided: Int, rows: Int) -> Snapshot {
        Snapshot(
            app: AppInfo(pid: 1, name: "Test", bundleID: nil, active: false, hasWindows: true),
            window: WindowInfo(windowID: 1, index: 0, title: nil, frame: FrameJSON(.zero), minimized: false, main: true),
            nodes: [], focusedIndex: nil, truncated: false, maxDepthReached: false,
            elidedCount: elided, rowsOmitted: rows, capturedAt: Date()
        )
    }

    // Hiding without saying so would read as "this is the whole interface".
    let both = statsSnapshot(elided: 37, rows: 120).renderText()
    t.expect(both.contains("(hidden: 37 structural containers, 120 offscreen rows)"), "elision and culling are both announced")
    let onlyElided = statsSnapshot(elided: 3, rows: 0).renderText()
    t.expect(onlyElided.contains("(hidden: 3 structural containers)"), "elision alone omits the rows clause")
    t.expect(!onlyElided.contains("offscreen"), "zero omitted rows are not mentioned")
    t.expect(!statsSnapshot(elided: 0, rows: 0).renderText().contains("hidden:"), "an unshaped snapshot announces nothing")

    // Snapshots cached before shaping existed carry no counters and must
    // still decode, or an upgrade would strand every session on disk.
    let legacy = """
    {"app":{"pid":1,"name":"Test","active":false,"hasWindows":true},
     "window":{"index":0,"frame":{"x":0,"y":0,"width":100,"height":100},"minimized":false,"main":true},
     "nodes":[],"truncated":false,"maxDepthReached":false,"capturedAt":"1970-01-01T00:00:00Z"}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        let decoded = try decoder.decode(Snapshot.self, from: Data(legacy.utf8))
        t.expectEqual(decoded.elidedCount, 0, "a legacy snapshot reads as nothing elided")
        t.expectEqual(decoded.rowsOmitted, 0, "a legacy snapshot reads as no rows omitted")
    } catch {
        t.expect(false, "legacy snapshot failed to decode: \(error)")
    }
}
