import Foundation

/// Works out whether the text we just inserted is still sitting untouched right
/// before the caret — the only situation in which two-phase delivery may edit a
/// field the user is actively typing in.
///
/// The bar is deliberately absolute: the delivered string must occupy exactly
/// the characters ending at the caret. If the user typed one more letter, moved
/// the caret, or the app reformatted the text, there is no match and the refine
/// is abandoned. A wrong range here would silently eat the user's own words,
/// which is far worse than leaving slightly-less-polished text on screen.
///
/// Ranges are in UTF-16 units because that is what Accessibility speaks.
public enum RefinementPlanner {

    /// The range to replace, or nil when it can't be proven safe.
    ///
    /// - Parameters:
    ///   - value: the field's full current text.
    ///   - caretUTF16: caret offset in UTF-16 units.
    ///   - delivered: the exact string previously inserted (including any
    ///     leading space the inserter added).
    public static func replacementRange(
        value: String, caretUTF16: Int, delivered: String
    ) -> NSRange? {
        let deliveredUnits = Array(delivered.utf16)
        guard !deliveredUnits.isEmpty else { return nil }
        let valueUnits = Array(value.utf16)
        let start = caretUTF16 - deliveredUnits.count
        guard start >= 0, caretUTF16 <= valueUnits.count else { return nil }
        guard Array(valueUnits[start..<caretUTF16]) == deliveredUnits else { return nil }
        return NSRange(location: start, length: deliveredUnits.count)
    }
}
