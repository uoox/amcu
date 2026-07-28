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
    /// nothing about whether an element is worth showing. The list matches the
    /// one `looksAccessibilityBlind` uses, so "kept because actionable" and
    /// "window is blind" cannot disagree about what actionable means.
    private static let presentationalActions: Set<String> = ["AXRaise", "AXScrollToVisible", "AXShowMenu"]

    /// Rows beyond this many survive viewport culling only as a count.
    public static let maxVisibleRows: Int = 20

    /// A structural container with nothing to read and nothing to do is pure
    /// nesting: skip the node itself but keep walking, so its descendants
    /// appear without the wrapper spending an index.
    public static func shouldElide(role: String, label: String?, value: String?, actions: [String]) -> Bool {
        guard structuralRoles.contains(role) else { return false }
        if let label, !label.isEmpty { return false }
        if let value, !value.isEmpty { return false }
        return meaningfulActions(actions).isEmpty
    }

    /// Whether descending into this element's subtree could reveal anything
    /// its own snapshot line does not already carry. An unlabelled compact
    /// control still gets expanded — its inner text may be the only way to
    /// tell two buttons apart. Menu bar items are cut unconditionally because
    /// their subtree is the entire menu, which `umbra menu` covers on its own.
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
