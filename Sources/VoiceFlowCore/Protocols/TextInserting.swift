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
    /// Bring the destination app to the front just before insertion, so a paste
    /// lands in the right place even if focus drifted during transcription.
    /// Default is a no-op (used by tests).
    func prepareForInsertion(intoBundleIdentifier bundleIdentifier: String?)
    /// Attempt to insert `text` using `strategy`. Implementations must restore the
    /// prior clipboard contents when using `.clipboardPaste`.
    func insert(_ text: String, using strategy: InsertionStrategy) throws -> InsertionOutcome
    /// Place text on the clipboard without pasting.
    func copyToClipboard(_ text: String)
    /// Inspect the current destination's capabilities (Accessibility support, secure input).
    func currentCapabilities() -> DestinationCapabilities
    /// Swap the text this inserter most recently delivered for `newText`, in
    /// place (two-phase delivery). Must return false — changing nothing — unless
    /// it can prove the delivered text is still sitting untouched at the caret.
    /// Default: unsupported.
    func replaceLastInsertion(with newText: String) -> Bool
}

public extension TextInserting {
    func prepareForInsertion(intoBundleIdentifier bundleIdentifier: String?) {}
    func replaceLastInsertion(with newText: String) -> Bool { false }
}
