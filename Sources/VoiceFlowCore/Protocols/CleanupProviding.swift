import Foundation

/// Context handed to the cleanup pipeline for a single transcript.
public struct CleanupContext: Sendable, Equatable {
    public let mode: DictationMode
    public let strength: CleanupStrength
    public let vocabulary: [VocabularyEntry]
    public let languageCode: String
    /// Convert spoken punctuation words ("period" → ".") — opt-in, because the
    /// unconditional mapping destroys those words used as ordinary nouns.
    public let spokenPunctuationEnabled: Bool

    public init(
        mode: DictationMode,
        strength: CleanupStrength,
        vocabulary: [VocabularyEntry],
        languageCode: String,
        spokenPunctuationEnabled: Bool = false
    ) {
        self.mode = mode
        self.strength = strength
        self.vocabulary = vocabulary
        self.languageCode = languageCode
        self.spokenPunctuationEnabled = spokenPunctuationEnabled
    }
}

/// Abstraction over a text-cleanup stage. Implementations range from a purely
/// deterministic rule engine to an LLM-backed rewriter.
public protocol CleanupProviding: Sendable {
    /// Transform raw transcript text into cleaned text.
    /// Must be pure with respect to `context` for the deterministic engine.
    func clean(_ rawText: String, context: CleanupContext) async throws -> String
}
