import Foundation

/// How cleaned text is delivered to the destination, in priority order.
public enum InsertionStrategy: String, Codable, Sendable, Hashable, CaseIterable {
    /// Insert directly via the Accessibility API (most reliable, no clipboard churn).
    case accessibility
    /// Place on the pasteboard, synthesize Cmd-V, then restore the prior clipboard.
    case clipboardPaste
    /// Copy to clipboard only; the user pastes manually (safest fallback).
    case copyOnly

    public var displayName: String {
        switch self {
        case .accessibility: return "Accessibility Insertion"
        case .clipboardPaste: return "Clipboard Paste (restored)"
        case .copyOnly: return "Copy Only"
        }
    }
}

/// Capabilities of the current destination, used to plan an insertion strategy.
public struct DestinationCapabilities: Sendable, Equatable {
    /// The destination exposes a settable Accessibility value on the focused element.
    public let supportsAccessibilityInsertion: Bool
    /// Synthetic paste (Cmd-V) is permitted for this destination.
    public let allowsSyntheticPaste: Bool
    /// The focused field is secure (password) — no automated insertion allowed.
    public let isSecureInput: Bool

    public init(
        supportsAccessibilityInsertion: Bool,
        allowsSyntheticPaste: Bool,
        isSecureInput: Bool
    ) {
        self.supportsAccessibilityInsertion = supportsAccessibilityInsertion
        self.allowsSyntheticPaste = allowsSyntheticPaste
        self.isSecureInput = isSecureInput
    }
}
