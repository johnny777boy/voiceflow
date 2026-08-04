import Foundation

/// Pure strategy selection: given a destination's capabilities and any per-app
/// override, choose how to deliver text. Priority (from the spec):
/// 1. Accessibility insertion
/// 2. Clipboard restore paste
/// 3. Copy-only fallback
///
/// Secure (password) fields always resolve to copy-only — never an automated paste.
public enum InsertionPlanner {
    public static func plan(
        capabilities: DestinationCapabilities,
        forceCopyOnly: Bool
    ) -> InsertionStrategy {
        if capabilities.isSecureInput { return .copyOnly }
        if forceCopyOnly { return .copyOnly }
        if capabilities.supportsAccessibilityInsertion { return .accessibility }
        if capabilities.allowsSyntheticPaste { return .clipboardPaste }
        return .copyOnly
    }
}
