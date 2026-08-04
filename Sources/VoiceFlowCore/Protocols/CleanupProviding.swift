import Foundation

/// Context handed to the cleanup pipeline for a single transcript.
public struct CleanupContext: Sendable, Equatable {
    public let mode: DictationMode
    public let strength: CleanupStrength
    public let vocabulary: [VocabularyEntry]
    public let languageCode: String

    public init(
        mode: DictationMode,
        strength: CleanupStrength,
        vocabulary: [VocabularyEntry],
        languageCode: String
    ) {
        self.mode = mode
        self.strength = strength
        self.vocabulary = vocabulary
        self.languageCode = languageCode
    }
}

/// Abstraction over a text-cleanup stage. Implementations range from a purely
/// deterministic rule engine to an LLM-backed rewriter.
public protocol CleanupProviding: Sendable {
    /// Transform raw transcript text into cleaned text.
    /// Must be pure with respect to `context` for the deterministic engine.
    func clean(_ rawText: String, context: CleanupContext) async throws -> String
}
