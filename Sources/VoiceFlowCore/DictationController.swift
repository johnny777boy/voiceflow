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
    private var screenHarvestResult: HarvestBox?

    /// The harvest runs here rather than on the Swift cooperative pool.
    ///
    /// `frontmostWindowText()` is synchronous, uncancellable C code that blocks
    /// on another process. The cooperative pool has one thread per core and every
    /// `await` in the app shares it, so a handful of blocked harvests against an
    /// unresponsive app could starve the pool and stall the whole dictation
    /// pipeline. A dedicated serial queue confines the damage to the harvest
    /// itself: at worst the next harvest is late, and a late harvest is simply
    /// skipped.
    private static let harvestQueue = DispatchQueue(
        label: "com.voiceflow.screen-harvest", qos: .userInitiated
    )
    /// True from the moment `finishRecording` takes the capture until it returns.
    /// The actor is reentrant across its `await`s, so this marks the window in
    /// which another call must not touch the recorder.
    private var isFinishing = false
    /// Phase two of two-phase delivery, running after `finishRecording` returned.
    private var pendingRefinement: Task<Void, Never>?

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
        // A new dictation supersedes the previous one's in-flight polish.
        pendingRefinement?.cancel()
        pendingRefinement = nil
        pendingSnapshot = activeApp.captureSnapshot()
        recordStartTime = time.now()
        try audio.startRecording()
        startScreenHarvest()
        // Load the cleanup model's weights while the user talks, so the first
        // dictation of a session doesn't pay the cold start.
        cleanup.prewarm()
    }

    /// Cancel an in-progress recording without transcribing or inserting.
    ///
    /// A finish that is already running OWNS the capture: tearing the recorder
    /// down underneath it would delete the very file being transcribed. Cancel
    /// during transcription is therefore a no-op — the dictation completes, which
    /// is also what the user sees happen.
    public func cancelRecording() {
        guard !isFinishing else { return }
        screenHarvestResult = nil
        _ = try? audio.stopRecording()
        audio.discardPendingCapture()   // remove the temp capture file we won't transcribe
        pendingSnapshot = nil
    }

    // MARK: - Recognition context

    /// Read the frontmost window's proper nouns WHILE the user speaks. Started
    /// here (not at release) so its cost lands during the hold, where it is free.
    private func startScreenHarvest() {
        screenHarvestResult = nil
        guard settings.screenContextEnabled, let screenContext else { return }
        let known = Set(settings.vocabulary.filter { $0.isEnabled }.map { $0.written })
        let box = HarvestBox()
        screenHarvestResult = box
        // Fire-and-forget by design. There is no handle to cancel because the
        // work underneath cannot be cancelled; dropping the box is how a
        // superseded harvest is abandoned, and its result is then read by nobody.
        Self.harvestQueue.async {
            let text = screenContext.frontmostWindowText()
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

        // Claim the capture BEFORE the drain suspends. The actor is reentrant
        // across `await`, so a cancel arriving during the 0.18s drain would
        // otherwise pass the `!isFinishing` guard and delete the file this call
        // is about to transcribe.
        isFinishing = true
        defer { isFinishing = false }
        // Drain first (async, off the main thread), then take the capture.
        await audio.drainBeforeStop()
        let capture = try audio.stopRecording()
        // Everything after this point is the number the user actually feels:
        // key released → text in the field. Hold time is deliberately excluded.
        let releasedAt = time.now()

        // Transcribe, biased toward the user's vocabulary + the names on screen.
        let recognitionContext = await makeTranscriptionContext()
        let transcribeStarted = time.now()
        let transcription = try await transcriber.transcribe(
            capture, languageCode: settings.languageCode, context: recognitionContext
        )
        let transcribeSeconds = max(0, time.now() - transcribeStarted)
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
            spokenPunctuationEnabled: settings.spokenPunctuationEnabled,
            fastPathEnabled: settings.fastShortUtterances,
            guardPolicy: settings.grammarRepairEnabled ? .grammarRepair : .verbatim
        )

        // Two-phase delivery (OFF by default, needs live testing): put the
        // deterministic text on screen immediately, then quietly upgrade it in
        // place once the LLM polish arrives. When it's off, this is the original
        // single insertion of the fully-cleaned text.
        let twoPhase = settings.twoPhaseDeliveryEnabled && mode != .raw && settings.cleanupStrength != .off
        let cleanupStarted = time.now()
        let firstPass = twoPhase
            ? try await cleanup.deterministicClean(raw, context: context)
            : try await cleanup.clean(raw, context: context)
        let cleanupSeconds = max(0, time.now() - cleanupStarted)

        // Re-verify destination immediately before insertion.
        let current = activeApp.captureSnapshot()
        let capabilities = inserter.currentCapabilities()
        let forceCopyOnly = settings.forcesCopyOnly(forBundleIdentifier: original.bundleIdentifier)
        let plan = DestinationGuard.makePlan(
            original: original, current: current, capabilities: capabilities, forceCopyOnly: forceCopyOnly
        )

        // Deliver text.
        let clean = firstPass
        let outcome: InsertionOutcome
        if plan.willInsert {
            // Focus the intended destination app before pasting, in case focus
            // drifted (e.g. to VoiceFlow) during transcription.
            inserter.prepareForInsertion(intoBundleIdentifier: current.bundleIdentifier)
            do {
                outcome = try inserter.insert(firstPass, using: plan.strategy)
            } catch {
                // Graceful degradation: fall back to copy-only.
                inserter.copyToClipboard(firstPass)
                outcome = InsertionOutcome(strategy: .copyOnly, didInsert: false,
                                           note: "Insertion failed; copied to clipboard. (\(error.localizedDescription))")
            }
        } else {
            inserter.copyToClipboard(firstPass)
            outcome = InsertionOutcome(strategy: .copyOnly, didInsert: false, note: plan.note)
        }

        let completedAt = time.now()
        let latency = max(0, completedAt - recordStartTime)
        let insertLatency = max(0, completedAt - releasedAt)
        // The itemized bill for this dictation. This line is the whole point of
        // the instrumentation: when a dictation feels slow, the answer is here.
        let arbiterSeconds = transcription.arbiterSeconds ?? 0
        Log.transcription.notice("Dictation delivered in \(insertLatency, privacy: .public)s after release — transcribe \(transcribeSeconds, privacy: .public)s (engine \(transcription.engineName ?? "?", privacy: .public), arbiter \(arbiterSeconds, privacy: .public)s), cleanup \(cleanupSeconds, privacy: .public)s")
        let record = TranscriptRecord(
            rawText: raw,
            cleanText: clean,
            appBundleIdentifier: original.bundleIdentifier,
            appName: original.appName,
            mode: mode,
            insertionStrategy: outcome.strategy,
            latencySeconds: latency,
            insertLatencySeconds: insertLatency,
            transcribeSeconds: transcribeSeconds,
            arbiterSeconds: arbiterSeconds,
            cleanupSeconds: cleanupSeconds,
            engineUsed: transcription.engineName,
            errorMessage: outcome.note ?? plan.note,
            createdAt: time.date()
        )

        if settings.historyEnabled {
            try? history.save(record)
            try? history.trim(toMostRecent: settings.historyRetentionLimit)
        }

        // Phase two runs AFTER this call returns, never inside it. The caller
        // serializes dictations against this method, so awaiting the second LLM
        // pass here would leave the hotkey inert for a second or more — starting
        // exactly when the user can SEE their text and is most likely to start
        // speaking again, which silently truncated the next utterance.
        if twoPhase, outcome.didInsert {
            scheduleRefinement(
                recordID: record.id, raw: raw, delivered: firstPass,
                context: context, persist: settings.historyEnabled
            )
        }

        return DictationResult(record: record, plan: plan, outcome: outcome)
    }

    /// Run phase two off the dictation path, and keep history honest about what
    /// ended up in the field. Superseded by the next dictation.
    private func scheduleRefinement(
        recordID: UUID, raw: String, delivered: String, context: CleanupContext, persist: Bool
    ) {
        pendingRefinement?.cancel()
        pendingRefinement = Task { [self] in
            let refined = await refineInPlace(raw: raw, delivered: delivered, context: context)
            guard refined != delivered, persist else { return }
            try? history.updateCleanText(refined, id: recordID)
        }
    }

    /// Second phase of two-phase delivery: run the full cleanup and, only if it
    /// changed something, ask the inserter to swap the delivered text in place.
    /// Returns whatever text is actually in the field afterwards — a refusal
    /// (user typed, focus moved, field unreadable) simply keeps phase one, which
    /// is already correct text, never a half-applied edit.
    private func refineInPlace(
        raw: String, delivered: String, context: CleanupContext
    ) async -> String {
        // Phase two happens after the text is already on screen, so there is no
        // latency to protect — only a hang to bound. Cutting it at the dictation
        // path's ceiling would discard a repair the user was never waiting for.
        let context = CleanupContext(
            mode: context.mode, strength: context.strength, vocabulary: context.vocabulary,
            languageCode: context.languageCode,
            spokenPunctuationEnabled: context.spokenPunctuationEnabled,
            fastPathEnabled: context.fastPathEnabled,
            // Carry the user's policy: without it phase two silently fell back to
            // .verbatim, so the in-place "upgrade" was judged by rules he never
            // chose and his grammar setting was ignored on that path.
            guardPolicy: context.guardPolicy,
            cleanupTimeout: 90
        )
        guard let refined = try? await cleanup.clean(raw, context: context),
              !refined.isEmpty, refined != delivered else { return delivered }
        // A new dictation supersedes this one: never reach into a field the user
        // has since moved on from.
        guard !Task.isCancelled else { return delivered }
        guard inserter.replaceLastInsertion(with: refined) else {
            Log.cleanup.notice("Two-phase refine declined — keeping the delivered text")
            return delivered
        }
        return refined
    }
}
