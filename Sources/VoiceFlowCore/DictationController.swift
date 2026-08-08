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
    private let screenContext: ScreenContextProviding?

    public private(set) var settings: AppSettings
    /// Destination captured at recording start, used later for verification.
    private var pendingSnapshot: DestinationSnapshot?
    private var recordStartTime: TimeInterval = 0
    /// Screen-noun harvest kicked off at record start so its cost is paid while
    /// the user is still speaking, never after they release the key.
    private var screenHarvest: Task<Void, Never>?
    private var screenHarvestResult: HarvestBox?

    /// One-shot mailbox for the harvest result. A plain box rather than
    /// `await task.value` on purpose: the AX read is synchronous C code that
    /// cannot be cancelled, and awaiting a task that ignores cancellation would
    /// make the "never wait for the screen reader" rule unenforceable (a task
    /// group cannot return until its children finish).
    private final class HarvestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String]?
        var terms: [String]? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func fill(_ terms: [String]) {
            lock.lock(); defer { lock.unlock() }
            value = terms
        }
    }

    public init(
        audio: AudioRecording,
        transcriber: Transcribing,
        cleanup: CleanupProviding,
        inserter: TextInserting,
        activeApp: ActiveAppProviding,
        history: HistoryStoring,
        settings: AppSettings = .default,
        time: TimeSource = SystemTimeSource(),
        screenContext: ScreenContextProviding? = nil
    ) {
        self.audio = audio
        self.transcriber = transcriber
        self.cleanup = cleanup
        self.inserter = inserter
        self.activeApp = activeApp
        self.history = history
        self.settings = settings
        self.time = time
        self.screenContext = screenContext
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
        startScreenHarvest()
    }

    /// Cancel an in-progress recording without transcribing or inserting.
    public func cancelRecording() {
        screenHarvest?.cancel()
        screenHarvest = nil
        screenHarvestResult = nil
        _ = try? audio.stopRecording()
        audio.discardPendingCapture()   // remove the temp capture file we won't transcribe
        pendingSnapshot = nil
    }

    // MARK: - Recognition context

    /// Read the frontmost window's proper nouns WHILE the user speaks. Started
    /// here (not at release) so its cost lands during the hold, where it is free.
    private func startScreenHarvest() {
        screenHarvest?.cancel()
        screenHarvest = nil
        screenHarvestResult = nil
        guard settings.screenContextEnabled, let screenContext else { return }
        let known = Set(settings.vocabulary.filter { $0.isEnabled }.map { $0.written })
        let box = HarvestBox()
        screenHarvestResult = box
        screenHarvest = Task.detached(priority: .userInitiated) {
            let text = screenContext.frontmostWindowText()
            guard !Task.isCancelled else { return }
            box.fill(text.map { ScreenTermExtractor.terms(in: $0, excluding: known) } ?? [])
        }
    }

    /// The harvested terms if they are ready, else nothing. A dictation must
    /// NEVER wait on the screen reader: biasing is an accuracy bonus, and a
    /// hung app must not cost the user a second of latency. The harvest normally
    /// finished long ago (it started when the key went down), so this returns
    /// immediately; the short poll only covers a very brief hold.
    private func harvestedScreenTerms(timeout: TimeInterval = 0.2) async -> [String] {
        guard let box = screenHarvestResult else { return [] }
        screenHarvestResult = nil
        screenHarvest = nil
        if let ready = box.terms { return ready }
        // Wall clock on purpose: this is a real-time budget for another thread's
        // work, not a logical timestamp the injected clock should control.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)   // 10ms
            if let ready = box.terms { return ready }
        }
        Log.transcription.notice("Screen context not ready in time — dictating without it")
        return []
    }

    /// Recognition context for this dictation: the user's own vocabulary first,
    /// then whatever names are on screen.
    private func makeTranscriptionContext() async -> TranscriptionContext {
        let vocabulary = settings.vocabulary
            .filter { $0.isEnabled }
            .map { $0.written.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let screenTerms = await harvestedScreenTerms()
        return TranscriptionContext(vocabularyTerms: vocabulary, screenTerms: screenTerms)
    }

    /// Stop recording, run the pipeline, and deliver the result.
    public func finishRecording() async throws -> DictationResult {
        guard let original = pendingSnapshot else {
            throw VoiceFlowError.audioEngineFailure("finishRecording called without beginRecording")
        }
        pendingSnapshot = nil

        let capture = try audio.stopRecording()

        // Transcribe, biased toward the user's vocabulary + the names on screen.
        let recognitionContext = await makeTranscriptionContext()
        let transcription = try await transcriber.transcribe(
            capture, languageCode: settings.languageCode, context: recognitionContext
        )
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
            languageCode: settings.languageCode,
            spokenPunctuationEnabled: settings.spokenPunctuationEnabled
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
