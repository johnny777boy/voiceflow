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
    /// Allow short casual utterances to skip the LLM pass entirely (latency).
    public let fastPathEnabled: Bool
    /// How much freedom the cleanup model has over wording. `.grammarRepair`
    /// lets it correct a non-native speaker's grammar (irregular verbs, missing
    /// articles/prepositions); `.verbatim` forbids any word change at all.
    public let guardPolicy: CleanupGuard.Policy
    /// Hard ceiling on the optional AI polish, in seconds. The on-device model
    /// can hang with no contract to return; past this the deterministic result
    /// is delivered instead. A dictation must always arrive — polish is
    /// optional, delivery is not. 0 disables the deadline (tests only).
    ///
    /// 15s on the dictation path: measured cleanups run 0.6–4.4s, and a 6s cap
    /// sat close enough to that to cut off a WORKING pass on a cold model or
    /// under ANE contention — silently costing the repair, which the standing
    /// accuracy rule forbids. This is a hang-stopper, not a latency knob.
    public let cleanupTimeout: TimeInterval
    /// Identifies the dictation this cleanup belongs to, so the audit slot can
    /// reject an entry written late by a previous one.
    public var dictationID: UUID?

    public init(
        mode: DictationMode,
        strength: CleanupStrength,
        vocabulary: [VocabularyEntry],
        languageCode: String,
        spokenPunctuationEnabled: Bool = false,
        fastPathEnabled: Bool = false,
        guardPolicy: CleanupGuard.Policy = .verbatim,
        cleanupTimeout: TimeInterval = 15,
        dictationID: UUID? = nil
    ) {
        self.mode = mode
        self.strength = strength
        self.vocabulary = vocabulary
        self.languageCode = languageCode
        self.spokenPunctuationEnabled = spokenPunctuationEnabled
        self.fastPathEnabled = fastPathEnabled
        self.guardPolicy = guardPolicy
        self.dictationID = dictationID
        self.cleanupTimeout = cleanupTimeout
    }
}

/// Abstraction over a text-cleanup stage. Implementations range from a purely
/// deterministic rule engine to an LLM-backed rewriter.
public protocol CleanupProviding: Sendable {
    /// Transform raw transcript text into cleaned text.
    /// Must be pure with respect to `context` for the deterministic engine.
    func clean(_ rawText: String, context: CleanupContext) async throws -> String
    /// The instant, deterministic result — no model, no waiting. Used by
    /// two-phase delivery to put text on screen before the polish arrives.
    /// Default: the full `clean`, i.e. providers without a fast tier are
    /// unaffected.
    func deterministicClean(_ rawText: String, context: CleanupContext) async throws -> String
    /// Give the provider a chance to load its model while the user is still
    /// speaking, so the first dictation of a session isn't the slow one.
    /// Must return immediately; default is a no-op.
    func prewarm()
}

public extension CleanupProviding {
    func deterministicClean(_ rawText: String, context: CleanupContext) async throws -> String {
        try await clean(rawText, context: context)
    }
    func prewarm() {}
}
