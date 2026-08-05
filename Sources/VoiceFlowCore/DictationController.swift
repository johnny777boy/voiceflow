import Foundation

/// The result of a completed dictation, returned for the UI/overlay to display.
public struct DictationResult: Sendable, Equatable {
    public let record: TranscriptRecord
    public let plan: InsertionPlan
    public let outcome: InsertionOutcome
    public init(record: TranscriptRecord, plan: InsertionPlan, outcome: InsertionOutcome) {
        self.record = record
        self.plan = plan
        self.outcome = outcome
    }
}

/// Orchestrates the end-to-end dictation workflow:
///
///   capture destination → record → transcribe → cleanup →
///   re-verify destination → insert (or copy) → save history
///
/// The controller NEVER sends a message or executes a command — it only delivers
/// text to a field (or the clipboard). The user reviews and presses Enter.
///
/// Implemented as an actor so the pending destination snapshot and settings are
/// accessed without data races.
public actor DictationController {
    private let audio: AudioRecording
    private let transcriber: Transcribing
    private let cleanup: CleanupProviding
    private let inserter: TextInserting
    private let activeApp: ActiveAppProviding
    private let history: HistoryStoring
    private let time: TimeSource

    public private(set) var settings: AppSettings
    /// Destination captured at recording start, used later for verification.
    private var pendingSnapshot: DestinationSnapshot?
    private var recordStartTime: TimeInterval = 0

    public init(
        audio: AudioRecording,
        transcriber: Transcribing,
        cleanup: CleanupProviding,
        inserter: TextInserting,
        activeApp: ActiveAppProviding,
        history: HistoryStoring,
        settings: AppSettings = .default,
        time: TimeSource = SystemTimeSource()
    ) {
        self.audio = audio
        self.transcriber = transcriber
        self.cleanup = cleanup
        self.inserter = inserter
        self.activeApp = activeApp
        self.history = history
        self.settings = settings
        self.time = time
    }

    public func updateSettings(_ newValue: AppSettings) {
        settings = newValue
    }

    public var isRecording: Bool { audio.isRecording }

    /// Capture the destination and begin recording. Idempotent-ish: if already
    /// recording, this is a no-op capture refresh.
    public func beginRecording() throws {
        pendingSnapshot = activeApp.captureSnapshot()
        recordStartTime = time.now()
        try audio.startRecording()
    }

    /// Cancel an in-progress recording without transcribing or inserting.
    public func cancelRecording() {
        _ = try? audio.stopRecording()
        pendingSnapshot = nil
    }

    /// Stop recording, run the pipeline, and deliver the result.
    public func finishRecording() async throws -> DictationResult {
        guard let original = pendingSnapshot else {
            throw VoiceFlowError.audioEngineFailure("finishRecording called without beginRecording")
        }
        pendingSnapshot = nil

        let capture = try audio.stopRecording()

        // Transcribe.
        let transcription = try await transcriber.transcribe(capture, languageCode: settings.languageCode)
        let raw = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw VoiceFlowError.emptyTranscript
        }

        // Cleanup for the resolved mode.
        let mode = settings.mode(forBundleIdentifier: original.bundleIdentifier)
        let context = CleanupContext(
            mode: mode,
            strength: settings.cleanupStrength,
            vocabulary: settings.vocabulary,
            languageCode: settings.languageCode
        )
        let clean = try await cleanup.clean(raw, context: context)

        // Re-verify destination immediately before insertion.
        let current = activeApp.captureSnapshot()
        let capabilities = inserter.currentCapabilities()
        let forceCopyOnly = settings.forcesCopyOnly(forBundleIdentifier: original.bundleIdentifier)
        let plan = DestinationGuard.makePlan(
            original: original, current: current, capabilities: capabilities, forceCopyOnly: forceCopyOnly
        )

        // Deliver text.
        let outcome: InsertionOutcome
        if plan.willInsert {
            // Focus the intended destination app before pasting, in case focus
            // drifted (e.g. to VoiceFlow) during transcription.
            inserter.prepareForInsertion(intoBundleIdentifier: current.bundleIdentifier)
            do {
                outcome = try inserter.insert(clean, using: plan.strategy)
            } catch {
                // Graceful degradation: fall back to copy-only.
                inserter.copyToClipboard(clean)
                outcome = InsertionOutcome(strategy: .copyOnly, didInsert: false,
                                           note: "Insertion failed; copied to clipboard. (\(error.localizedDescription))")
            }
        } else {
            inserter.copyToClipboard(clean)
            outcome = InsertionOutcome(strategy: .copyOnly, didInsert: false, note: plan.note)
        }

        let latency = max(0, time.now() - recordStartTime)
        let record = TranscriptRecord(
            rawText: raw,
            cleanText: clean,
            appBundleIdentifier: original.bundleIdentifier,
            appName: original.appName,
            mode: mode,
            insertionStrategy: outcome.strategy,
            latencySeconds: latency,
            errorMessage: outcome.note ?? plan.note,
            createdAt: time.date()
        )

        if settings.historyEnabled {
            try? history.save(record)
            try? history.trim(toMostRecent: settings.historyRetentionLimit)
        }

        return DictationResult(record: record, plan: plan, outcome: outcome)
    }
}
