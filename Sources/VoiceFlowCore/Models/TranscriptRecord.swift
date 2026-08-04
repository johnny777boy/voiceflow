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
    /// End-to-end latency from record-stop to insertion-ready, in seconds.
    public var latencySeconds: Double
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
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }
}
