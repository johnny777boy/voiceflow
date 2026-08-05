import Foundation

/// Pure strategy selection: given a destination's capabilities and any per-app
/// override, choose how to deliver text.
///
/// Priority — **clipboard-restore paste first**. Synthetic ⌘V works reliably in
/// essentially every app (native Cocoa, Electron like Claude Code / Slack, and
/// web fields in browsers), whereas Accessibility value-setting silently fails in
/// Electron/web views. Accessibility is the fallback for the rare app that blocks
/// synthetic paste but exposes a settable field.
///   1. Clipboard restore paste
///   2. Accessibility insertion
///   3. Copy-only fallback
///
/// Secure (password) fields always resolve to copy-only — never an automated paste.
public enum InsertionPlanner {
    public static func plan(
        capabilities: DestinationCapabilities,
        forceCopyOnly: Bool
    ) -> InsertionStrategy {
        if capabilities.isSecureInput { return .copyOnly }
        if forceCopyOnly { return .copyOnly }
        if capabilities.allowsSyntheticPaste { return .clipboardPaste }
        if capabilities.supportsAccessibilityInsertion { return .accessibility }
        return .copyOnly
    }
}
