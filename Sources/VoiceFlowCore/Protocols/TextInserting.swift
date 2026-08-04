import Foundation

/// Outcome of an insertion attempt.
public struct InsertionOutcome: Sendable, Equatable {
    /// The strategy actually used.
    public let strategy: InsertionStrategy
    /// Whether text reached the destination (false for copy-only / preview).
    public let didInsert: Bool
    /// Optional human-readable note (e.g. why it degraded).
    public let note: String?

    public init(strategy: InsertionStrategy, didInsert: Bool, note: String? = nil) {
        self.strategy = strategy
        self.didInsert = didInsert
        self.note = note
    }
}

/// Abstraction over delivering text to the destination and clipboard control.
public protocol TextInserting: AnyObject, Sendable {
    /// Attempt to insert `text` using `strategy`. Implementations must restore the
    /// prior clipboard contents when using `.clipboardPaste`.
    func insert(_ text: String, using strategy: InsertionStrategy) throws -> InsertionOutcome
    /// Place text on the clipboard without pasting.
    func copyToClipboard(_ text: String)
    /// Inspect the current destination's capabilities (Accessibility support, secure input).
    func currentCapabilities() -> DestinationCapabilities
}
