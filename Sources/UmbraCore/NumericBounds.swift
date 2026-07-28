import Foundation

/// Narrowing conversions on caller-supplied numbers.
///
/// `Int32(someInt)` traps when the value does not fit, which takes the whole
/// process down. A number someone typed on the command line is input to be
/// validated, not a programmer error to assert on — so the narrowing is done
/// with `exactly:` and an out-of-range value becomes a reportable failure.
public enum NumericBounds {
    public static func narrow(_ value: Int, min lower: Int32, max upper: Int32) -> Int32? {
        guard let narrowed = Int32(exactly: value), narrowed >= lower, narrowed <= upper else { return nil }
        return narrowed
    }

    /// For budgets where any positive number is meaningful and the caller mostly
    /// means "as much as you can" — clamping serves them better than an error.
    public static func clamp(_ value: Int, min lower: Int, max upper: Int) -> Int {
        Swift.max(lower, Swift.min(upper, value))
    }
}
