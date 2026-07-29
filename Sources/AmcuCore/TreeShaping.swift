import Foundation

/// Policy for which parts of an accessibility hierarchy earn a place in a
/// snapshot. Every rule here exists to spend the node budget on elements a
/// model can act on instead of on scaffolding: real windows nest a dozen
/// anonymous groups around every control, and one scrolled table can hold
/// thousands of rows of which twenty are on screen.
///
/// Pure functions over plain values, so the policy is testable without a live
/// window — the walk in `SnapshotBuilder` supplies the AX plumbing.
public enum TreeShaping {
    /// Container roles that carry structure but no meaning of their own.
    private static let structuralRoles: Set<String> = ["AXGroup", "AXUnknown", "AXSplitGroup"]

    /// Controls whose one-line snapshot entry already says everything their
    /// subtree would repeat (a button's inner static text is its label again).
    private static let compactRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXComboBox", "AXPopUpButton",
        "AXRadioButton", "AXStaticText", "AXMenuItem", "AXDisclosureTriangle"
    ]

    /// Actions the system attaches to almost everything; their presence says
    /// nothing about whether an element is worth showing.
    ///
    /// `AXShowMenu` sits in this list for *rendering* (a context menu is not
    /// worth a line in every node's action list) but not in
    /// `elisionIgnoredActions`: an unlabelled group whose only affordance is a
    /// context menu is the sole addressable carrier of that menu, and eliding
    /// it would make the menu unreachable through `action --action AXShowMenu`.
    /// The two filters answer different questions — "is this worth printing?"
    /// versus "can this node do anything its children cannot?" — so they are
    /// allowed to disagree about `AXShowMenu` and only about it.
    private static let presentationalActions: Set<String> = ["AXRaise", "AXScrollToVisible", "AXShowMenu"]

    /// Actions that never save a node from elision. Matches the ignore list in
    /// `Snapshot.looksAccessibilityBlind`, so "kept because actionable" and
    /// "window is blind" cannot disagree about what actionable means.
    private static let elisionIgnoredActions: Set<String> = ["AXRaise", "AXScrollToVisible"]

    /// Rows beyond this many survive viewport culling only as a count.
    public static let maxVisibleRows: Int = 20

    /// A structural container with nothing to read and nothing to do is pure
    /// nesting: skip the node itself but keep walking, so its descendants
    /// appear without the wrapper spending an index.
    public static func shouldElide(role: String, label: String?, value: String?, actions: [String]) -> Bool {
        guard structuralRoles.contains(role) else { return false }
        if let label, !label.isEmpty { return false }
        if let value, !value.isEmpty { return false }
        return !advertisesRealAction(actions)
    }

    /// Whether an action list promises anything beyond what the system attaches
    /// to everything. This is the `elisionIgnoredActions` notion of actionable
    /// (AXShowMenu counts), not the `presentationalActions` one: child
    /// suppression uses it to decide whether hiding a subtree would hide the
    /// only carrier of a real affordance, which is exactly the question elision
    /// answers — a combo box's inner drop-down button must survive for the same
    /// reason a context-menu-only group does.
    public static func advertisesRealAction(_ actions: [String]) -> Bool {
        !actions.allSatisfy { elisionIgnoredActions.contains($0) }
    }

    /// Whether descending into this element's subtree could reveal anything
    /// its own snapshot line does not already carry. An unlabelled compact
    /// control still gets expanded — its inner text may be the only way to
    /// tell two buttons apart. Menu bar items are cut unconditionally because
    /// their subtree is the entire menu, which `amcu menu` covers on its own.
    public static func shouldSuppressChildren(role: String, label: String?) -> Bool {
        if role == "AXMenuBarItem" { return true }
        guard compactRoles.contains(role) else { return false }
        // Static text carries its content in its value, not its label, so a
        // missing label is not a reason to go looking underneath it.
        if role == "AXStaticText" { return true }
        if let label, !label.isEmpty { return true }
        return false
    }

    /// Roles whose children are homogeneous rows, where visibility rather
    /// than position in the hierarchy decides what a model can use.
    public static func usesRowViewport(role: String) -> Bool {
        role == "AXTable" || role == "AXOutline" || role == "AXList"
    }

    public static func meaningfulActions(_ actions: [String]) -> [String] {
        actions.filter { !presentationalActions.contains($0) }
    }
}
