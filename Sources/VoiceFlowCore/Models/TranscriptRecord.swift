import Foundation

/// A single dictation event as stored in history.
public struct TranscriptRecord: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    /// The verbatim transcript from the speech engine.
    public var rawText: String
    /// The cleaned text that was (or would be) inserted.
    public var cleanText: String
    /// Bundle id of the destination application.
    public var appBundleIdentifier: String?
    /// Display name of the destination application.
    public var appName: String?
    /// The mode used for cleanup.
    public var mode: DictationMode
    /// The insertion strategy that was ultimately used, if any.
    public var insertionStrategy: InsertionStrategy?
    /// Wall time from the start of the hold to insertion-ready, in seconds. This
    /// INCLUDES however long the user held the key, so it is not a speed metric.
    public var latencySeconds: Double
    /// The number that actually describes how fast the app feels: key RELEASE to
    /// text-in-the-field, hold time excluded. This is the Phase 3 target metric.
    public var insertLatencySeconds: Double
    /// Set later by the correction watcher when the user edited the inserted text
    /// (Phase 4). Drives the zero-edit rate — the honest quality number.
    public var editedAfterInsert: Bool
    /// Per-stage breakdown of `insertLatencySeconds`, so slow dictations are
    /// attributable instead of mysterious. 0 = not measured (old records).
    /// Seconds inside the transcriber call (Whisper/Apple decode + any arbiter).
    public var transcribeSeconds: Double
    /// Seconds inside the second-opinion engine, when one ran (subset of
    /// `transcribeSeconds`). The variable cost that makes same-length dictations
    /// differ by seconds.
    public var arbiterSeconds: Double
    /// Seconds inside the cleanup pipeline (rules + optional LLM polish).
    public var cleanupSeconds: Double
    /// Which engine produced the text ("whisper" / "apple"), when known.
    public var engineUsed: String?
    /// THE CLEANUP AUDIT (added 2026-08-19). History used to store only the
    /// delivered text, which made "cleanup is not accurate" unanswerable: a
    /// dictation whose polish the guard silently reverted looks identical to one
    /// the model had nothing to fix — in both, cleanText == rawText.
    ///
    /// What the AI proposed, BEFORE the guard ruled on it. nil when no model ran.
    public var cleanupProposed: String?
    /// What happened to that proposal: "accepted", "partial" (some sentences
    /// kept), "rejected", "unavailable", "timeout", "fast-path", "rules-only".
    public var cleanupDecision: String?
    /// When the guard refused, WHY — e.g. `dropped the word "well"`.
    public var cleanupRejectReason: String?
    /// A non-fatal error/warning message, if the event degraded (e.g. fell back to copy-only).
    public var errorMessage: String?
    /// When the dictation happened.
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        rawText: String,
        cleanText: String,
        appBundleIdentifier: String? = nil,
        appName: String? = nil,
        mode: DictationMode,
        insertionStrategy: InsertionStrategy? = nil,
        latencySeconds: Double = 0,
        insertLatencySeconds: Double = 0,
        editedAfterInsert: Bool = false,
        transcribeSeconds: Double = 0,
        arbiterSeconds: Double = 0,
        cleanupSeconds: Double = 0,
        engineUsed: String? = nil,
        cleanupProposed: String? = nil,
        cleanupDecision: String? = nil,
        cleanupRejectReason: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.rawText = rawText
        self.cleanText = cleanText
        self.appBundleIdentifier = appBundleIdentifier
        self.appName = appName
        self.mode = mode
        self.insertionStrategy = insertionStrategy
        self.latencySeconds = latencySeconds
        self.insertLatencySeconds = insertLatencySeconds
        self.editedAfterInsert = editedAfterInsert
        self.transcribeSeconds = transcribeSeconds
        self.arbiterSeconds = arbiterSeconds
        self.cleanupSeconds = cleanupSeconds
        self.engineUsed = engineUsed
        self.cleanupProposed = cleanupProposed
        self.cleanupDecision = cleanupDecision
        self.cleanupRejectReason = cleanupRejectReason
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }

    /// Tolerant decoding: records written before the Phase 2 metrics existed must
    /// keep loading, with the new fields at their defaults rather than throwing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        rawText = try c.decode(String.self, forKey: .rawText)
        cleanText = try c.decode(String.self, forKey: .cleanText)
        appBundleIdentifier = try c.decodeIfPresent(String.self, forKey: .appBundleIdentifier)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        mode = try c.decode(DictationMode.self, forKey: .mode)
        insertionStrategy = try c.decodeIfPresent(InsertionStrategy.self, forKey: .insertionStrategy)
        latencySeconds = try c.decodeIfPresent(Double.self, forKey: .latencySeconds) ?? 0
        insertLatencySeconds = try c.decodeIfPresent(Double.self, forKey: .insertLatencySeconds) ?? 0
        editedAfterInsert = try c.decodeIfPresent(Bool.self, forKey: .editedAfterInsert) ?? false
        transcribeSeconds = try c.decodeIfPresent(Double.self, forKey: .transcribeSeconds) ?? 0
        arbiterSeconds = try c.decodeIfPresent(Double.self, forKey: .arbiterSeconds) ?? 0
        cleanupSeconds = try c.decodeIfPresent(Double.self, forKey: .cleanupSeconds) ?? 0
        engineUsed = try c.decodeIfPresent(String.self, forKey: .engineUsed)
        cleanupProposed = try c.decodeIfPresent(String.self, forKey: .cleanupProposed)
        cleanupDecision = try c.decodeIfPresent(String.self, forKey: .cleanupDecision)
        cleanupRejectReason = try c.decodeIfPresent(String.self, forKey: .cleanupRejectReason)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}
