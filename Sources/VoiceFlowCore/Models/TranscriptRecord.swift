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
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}
