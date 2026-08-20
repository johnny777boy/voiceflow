import Foundation
import AppKit
import SwiftUI
import AVFoundation
import Speech
import VoiceFlowCore
import VoiceFlowWhisper

/// Observable app state that bridges the SwiftUI UI with the `DictationController`
/// actor and the global hotkey. Owns permission flow, settings persistence, and
/// the recording lifecycle.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var isRecording = false
    /// Live mic level (0…1) for the in-window recording animation.
    @Published private(set) var audioLevel: CGFloat = 0
    @Published private(set) var statusText = "Ready"
    @Published private(set) var lastResult: DictationResult?
    @Published private(set) var recentRecords: [TranscriptRecord] = []
    /// Median release-to-insert latency + zero-edit rate over recent dictations.
    @Published private(set) var stats: DictationStats = .empty
    /// Corrections the user has made repeatedly, offered for one-click accept.
    /// Nothing here changes transcription until the user says so.
    @Published private(set) var vocabularySuggestions: [VocabularySuggestion] = []
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var microphoneGranted = false
    @Published private(set) var speechGranted = false
    @Published private(set) var inputMonitoringGranted = false

    /// Whisper "High Accuracy" model lifecycle (download progress, readiness) —
    /// observed by SettingsView for the progress UI.
    let whisperManager: WhisperModelManager

    private let controller: DictationController
    private let live: SpeechEngine
    private let hotkeys: GlobalHotkeyManager
    private var flagKeyGlobalMonitor: Any?
    private var flagKeyLocalMonitor: Any?
    private let flagKeyTaps = DoubleTapTracker()
    private let settingsStore: SettingsStore
    private let history: HistoryStoring
    private let secureStore: SecureStoring
    /// The cleanup stage's account of the dictation in flight (see CleanupAuditLog).
    private let cleanupAudit: CleanupAuditLog
    private let overlay = OverlayController()
    private let suggestionStore: SuggestedVocabularyStore
    private var corrections: CorrectionWatcher?
    private var didStart = false
    /// Desired recording state, set synchronously by hotkey events. A single
    /// reconcile pass drives the *actual* recording toward this intent and
    /// re-reads it after every async transition — so a release that arrives while
    /// `beginRecording` is still awaiting is honored on the next loop turn rather
    /// than dropped (which a simple busy-latch would do).
    private var recordingIntent = false
    private var reconciling = false
    private var recordingStartedAt: Date?

    init() {
        let settingsStore = SettingsStore()
        let loaded = settingsStore.load()
        self.settingsStore = settingsStore
        self.settings = loaded

        // Persistent history with an in-memory fallback if the DB can't open.
        let store: HistoryStoring
        do {
            store = try SQLiteHistoryStore(url: AppPaths.historyDatabaseURL())
        } catch {
            Log.history.error("SQLite unavailable, using in-memory history: \(String(describing: error), privacy: .public)")
            store = InMemoryHistoryStore()
        }
        self.history = store
        self.secureStore = KeychainStore()
        self.hotkeys = GlobalHotkeyManager()
        self.suggestionStore = SuggestedVocabularyStore(url: AppPaths.suggestedVocabularyURL())


        // One audit slot shared by the cleanup stage and the controller: the
        // stage writes what it proposed and what the guard did with it, the
        // controller copies that onto the history record (2026-08-19).
        let cleanupAudit = CleanupAuditLog()
        self.cleanupAudit = cleanupAudit

        // AI cleanup provider: prefer Apple's on-device model (free, private, no API
        // key) on macOS 26; otherwise the optional Anthropic provider (needs a key).
        let llmProvider: CleanupProviding
        let useLLM: Bool
        if #available(macOS 26.0, *) {
            // On-device, free, private — the "think, then deliver" polish (like Wispr).
            // Do NOT gate on isAvailable HERE: that value is a moving target (false while
            // Apple Intelligence is still waking up at launch), and freezing it once left
            // cleanup/punctuation off for a whole session. The provider re-checks
            // availability on EVERY call and falls back to rule-based only when it's
            // genuinely not ready — so cleanup turns on the moment the model is ready.
            llmProvider = FoundationModelsCleanupProvider(audit: cleanupAudit)
            useLLM = true
            Log.cleanup.notice("cleanup: on-device Foundation Models (re-checked per call)")
        } else {
            // Paid Anthropic API — respect the user's toggle + key.
            llmProvider = LLMCleanupProvider(secureStore: secureStore)
            useLLM = loaded.useLLMCleanup
            Log.cleanup.notice("cleanup: Anthropic (API key) / rule-based")
        }
        let pipeline = CleanupPipeline(llmProvider: llmProvider, useLLM: useLLM, audit: cleanupAudit)
        // Pick the best engine: on macOS 26 use Apple's SpeechAnalyzer (records the
        // whole clip, then transcribes with full context — far more accurate).
        // Otherwise fall back to the legacy streaming engine.
        let engine: SpeechEngine
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            engine = SpeechAnalyzerDictation()
            Log.transcription.notice("engine: SpeechAnalyzer (macOS 26)")
        } else {
            engine = LiveSpeechDictation()
            Log.transcription.notice("engine: legacy SFSpeechRecognizer")
        }
        engine.preferredLanguage = loaded.languageCode
        if #available(macOS 26.0, *), let sa = engine as? SpeechAnalyzerDictation {
            sa.idleReleaseEnabled = loaded.micIdleReleaseEnabled
        }
        let live = engine
        self.live = live
        // Transcriber: the fast Apple engine is ALWAYS the fallback. When the user
        // turns on "High Accuracy", `WhisperModelManager` downloads + loads the
        // Whisper model in the background; the router below re-checks readiness on
        // every dictation, so Whisper takes over the moment it's ready (and Apple
        // covers every dictation before that, and any Whisper runtime failure).
        // No relaunch needed in either direction.
        let whisper = WhisperKitTranscriber()
        // Benchmark mode: keep every capture so a normal day of dictation
        // becomes a corpus that can be re-decoded offline under another model or
        // with biasing on. Without it, a model A/B requires re-reading a script,
        // and the reading varies more than the models do.
        //   defaults write com.voiceflow.dictation benchmarkRetainCaptures -bool YES
        if UserDefaults.standard.bool(forKey: "benchmarkRetainCaptures") {
            let corpus = AppPaths.baseDirectory().appendingPathComponent("Benchmark", isDirectory: true)
            whisper.retainCaptureFile = true
            whisper.captureArchiveDirectory = corpus
            Log.transcription.notice("BENCHMARK MODE: captures retained in \(corpus.path, privacy: .public)")
        }
        // Second opinion for Whisper's silence-hallucinations: Apple's engine
        // emits nothing on silent clips, so it can veto phantom "Thank you."s.
        // ONLY the modern engine qualifies — the legacy streaming engine's
        // transcribe is stateful/slow (15s poll) and unsafe to invoke twice.
        if #available(macOS 26.0, *), live is SpeechAnalyzerDictation {
            whisper.silenceArbiter = live
        }
        self.whisperManager = WhisperModelManager(transcriber: whisper)
        let transcriber: Transcribing = FallbackTranscriber(
            preferred: whisper,
            fallback: live,
            usePreferred: { [weak whisper] in
                UserDefaults.standard.bool(forKey: WhisperModelManager.enabledDefaultsKey)
                    && whisper?.isReady == true
            },
            onFallback: { reason in
                Log.transcription.error("Whisper failed — fell back to Apple engine: \(reason, privacy: .public)")
            }
        )
        self.controller = DictationController(
            audio: live,
            transcriber: transcriber,
            cleanup: pipeline,
            inserter: AccessibilityTextInserter(),
            activeApp: WorkspaceActiveAppProvider(),
            history: store,
            settings: loaded,
            screenContext: AXScreenContextProvider(),
            cleanupAudit: cleanupAudit,
            confusions: PersonalConfusionsStore(
                url: AppPaths.baseDirectory().appendingPathComponent("personal-confusions.json"))
        )
    }

    // MARK: - Lifecycle

    func start() {
        guard !didStart else { return }   // idempotent: safe if invoked more than once
        didStart = true
        // Feed the live mic level into the floating waveform pill AND the window.
        live.levelHandler = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                self.overlay.updateLevel(level)
                // Coalesce: only publish visible changes — every publish re-renders
                // every window observing the coordinator.
                let new = CGFloat(level)
                if abs(new - self.audioLevel) > 0.01 { self.audioLevel = new }
            }
        }
        // Bias recognition toward the user's saved names/terms.
        live.contextualStrings = contextualStrings(from: settings)
        refreshPermissionStatus()
        _ = AX.hasAccessibilityPermission(prompt: true)   // nudge the AX prompt once
        InputMonitoring.request()                         // nudge the Input Monitoring prompt
        Task { await requestPermissions() }
        registerHotkey()
        registerFlagKey()
        LoginItemManager.setEnabled(settings.launchAtLogin)
        // Learn from what the user fixes by hand — proposals only, never silent
        // vocabulary changes.
        corrections = CorrectionWatcher(
            store: suggestionStore,
            onEdit: { [weak self] recordID, edited in
                guard let self else { return }
                try? self.history.setEditedAfterInsert(edited, id: recordID)
                self.refreshHistory()
            },
            onSuggestion: { [weak self] _ in
                self?.refreshSuggestions()
            }
        )
        refreshSuggestions()
        refreshHistory()
        // If High Accuracy was already on, resume the model download/load now —
        // dictation stays on the Apple engine until Whisper reports ready.
        whisperManager.bootstrapIfEnabled()

        // Re-check permissions whenever the app is refocused (e.g. after the user
        // toggles a permission in System Settings), so banners aren't stale — and
        // (re)register the global hotkey once its permissions are granted, since the
        // event tap can only be created after Accessibility/Input Monitoring exist.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshPermissionStatus()
                // Always REBUILD the tap when perms are present: a tap created
                // before a grant landed comes up dead and must be recreated.
                if self.accessibilityGranted, self.inputMonitoringGranted {
                    self.registerHotkey()
                }
            }
        }

        // Self-heal after sleep: macOS can silently disable a global event tap
        // across a sleep/wake cycle, leaving the hotkey dead until the user
        // happens to click the app (didBecomeActive). Rebuild the tap on every
        // wake — for a menu-bar app that may never be "activated", this is the
        // only reliable trigger. Slight delay lets the system settle first.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                self.refreshPermissionStatus()
                if self.accessibilityGranted, self.inputMonitoringGranted {
                    self.registerHotkey()
                    Log.hotkey.notice("Rebuilt hotkey tap after wake")
                }
            }
        }
    }

    private func refreshPermissionStatus() {
        accessibilityGranted = AX.hasAccessibilityPermission(prompt: false)
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        inputMonitoringGranted = InputMonitoring.isGranted()
        // Keep the mic warm so the first word isn't clipped by device warm-up.
        if microphoneGranted, !isRecording { live.prewarm() }
    }

    private func requestPermissions() async {
        _ = await AudioEngineRecorder().requestPermission()
        _ = await SFSpeechTranscriberWrapper().requestPermission()
        await MainActor.run { refreshPermissionStatus() }
    }

    /// Ensure mic + speech are authorized right before recording. Returns an
    /// actionable error message if not (nil means good to go).
    private func ensureCapturePermissions() async -> String? {
        // Microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            let granted = await withCheckedContinuation { c in
                AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
            }
            if !granted {
                return "Microphone access is off. Enable VoiceFlow in System Settings ▸ Privacy & Security ▸ Microphone."
            }
        default:
            return "Microphone access is off. Enable VoiceFlow in System Settings ▸ Privacy & Security ▸ Microphone."
        }
        // Speech recognition
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            if status != .authorized {
                return "Speech Recognition is off. Enable VoiceFlow in System Settings ▸ Privacy & Security ▸ Speech Recognition."
            }
        default:
            return "Speech Recognition is off. Enable VoiceFlow in System Settings ▸ Privacy & Security ▸ Speech Recognition."
        }
        refreshPermissionStatus()
        return nil
    }

    /// Open a specific Privacy & Security settings pane.
    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The "that was wrong" gesture: TAP CONTROL TWICE (⌃⌃), quickly.
    ///
    /// His dictation key is a single held Option, so the error report has to be
    /// just as light — a chord like ⌃⌥⌘X was rejected as too much. Two taps of
    /// the bottom-corner key, one finger, done. A quiet sound acknowledges.
    ///
    /// Strictly two PURE taps: control pressed alone (no other modifiers), no
    /// real key typed between the taps, both within 600ms. That makes ⌃C ⌃V
    /// runs and ⌃-clicks invisible to it — those always type or click between
    /// presses. Separate monitors from the dictation hotkey so neither can
    /// break the other; nothing is consumed, nothing is typed.
    private func registerFlagKey() {
        let handle: @Sendable (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            if event.type == .keyDown { self.flagKeyTaps.somethingTyped(); return }
            guard event.type == .flagsChanged else { return }
            let mods = event.modifierFlags.intersection([.control, .option, .command, .shift, .function])
            guard self.flagKeyTaps.controlEvent(isPureControl: mods == .control,
                                                controlHeld: mods.contains(.control)) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.controller.flagLastDictation() != nil {
                    NSSound(named: "Purr")?.play()   // quiet ack: flag recorded
                }
            }
        }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        flagKeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle)
        flagKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handle(event); return event
        }
    }

    private func registerHotkey() {
        hotkeys.register(settings.hotkey) { [weak self] event in
            // Hotkey callback arrives on the main run loop; hop to the main actor.
            Task { @MainActor in
                self?.handle(event)
            }
        }
    }

    /// Hotkey events only update the *intent* (synchronously), then kick a
    /// reconcile. They never await, so no event is ever dropped mid-transition.
    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .pressed:  recordingIntent = true
        case .released: recordingIntent = false
        case .toggled:  recordingIntent.toggle()
        }
        reconcile()
    }

    // MARK: - Recording (intent → actual reconciliation)

    /// Public entry points (menu / tests) also route through intent.
    func beginRecording() { recordingIntent = true; reconcile() }
    func finishRecording() { recordingIntent = false; reconcile() }

    /// Tap-to-toggle for the in-app button: start if idle, stop if recording.
    func toggleRecording() {
        recordingIntent.toggle()
        reconcile()
    }

    /// Drive `isRecording` toward `recordingIntent`. Only one pass runs at a time;
    /// it loops because the intent may flip during an `await`.
    private func reconcile() {
        guard !reconciling else { return }   // in-flight pass will observe the new intent
        reconciling = true
        Task { @MainActor in
            defer { reconciling = false }
            while recordingIntent != isRecording {
                if recordingIntent {
                    await beginRecordingTransition()
                    if !isRecording { break }   // begin failed (e.g. mic error) — don't spin
                } else {
                    await finishRecordingTransition()
                }
            }
        }
    }

    private func beginRecordingTransition() async {
        // A new dictation supersedes the previous one's correction window.
        corrections?.cancel()
        // Gate on mic + speech permission — but only await the (possibly
        // prompting) request path when they aren't already granted. When they
        // are, we proceed synchronously so a prompt can't desync press/release.
        if !(microphoneGranted && speechGranted) {
            if let message = await ensureCapturePermissions() {
                recordingIntent = false
                isRecording = false
                statusText = message
                overlay.show(state: .error(message))
                return
            }
        }
        do {
            try await controller.beginRecording()
            isRecording = true
            recordingStartedAt = Date()
            statusText = "Listening…"
            overlay.show(state: .recording)
        } catch {
            isRecording = false
            statusText = "Mic error: \(error.localizedDescription)"
            overlay.show(state: .error(statusText))
        }
    }

    private func finishRecordingTransition() async {
        isRecording = false
        // Safety rail: ignore very short holds (e.g. a quick key-tap while typing)
        // so they never record, transcribe, or insert anything.
        if let started = recordingStartedAt, Date().timeIntervalSince(started) < 0.4 {
            recordingStartedAt = nil
            await controller.cancelRecording()
            statusText = "Ready"
            overlay.hide()
            return
        }
        recordingStartedAt = nil
        statusText = "Transcribing…"
        overlay.show(state: .processing)
        do {
            let result = try await controller.finishRecording()
            lastResult = result
            statusText = result.outcome.didInsert ? "Inserted" : (result.outcome.note ?? "Copied to clipboard")
            overlay.show(state: .done(result))
            refreshHistory()
            // Learning from corrections is part of keeping history: it reads the
            // user's field a moment after insertion and persists word pairs taken
            // from it. Someone who turned history OFF has said they don't want
            // their dictations kept, and this must honour that.
            if result.outcome.didInsert, settings.historyEnabled {
                corrections?.watch(recordID: result.record.id, insertedText: result.record.cleanText)
            }
        } catch {
            statusText = "Error: \(error.localizedDescription)"
            overlay.show(state: .error(statusText))
        }
    }

    func cancel() {
        recordingIntent = false
        Task { await controller.cancelRecording() }
        isRecording = false
        statusText = "Cancelled"
        overlay.hide()
    }

    // MARK: - Settings & history

    /// Recognition hints from the user's enabled vocabulary (their spelling of
    /// names/terms), so the recognizer is biased toward them.
    private func contextualStrings(from s: AppSettings) -> [String] {
        let terms = s.vocabulary.filter { $0.isEnabled }.flatMap { [$0.written, $0.spoken] }
        return Array(Set(terms.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })).prefix(100).map { $0 }
    }

    func applySettings(_ new: AppSettings) {
        let hotkeyChanged = new.hotkey != settings.hotkey
        let loginChanged = new.launchAtLogin != settings.launchAtLogin
        settings = new
        try? settingsStore.save(new)
        live.preferredLanguage = new.languageCode
        live.contextualStrings = contextualStrings(from: new)
        if #available(macOS 26.0, *), let sa = live as? SpeechAnalyzerDictation {
            sa.idleReleaseEnabled = new.micIdleReleaseEnabled
        }
        Task { await controller.updateSettings(new) }
        if hotkeyChanged { registerHotkey() }
        if loginChanged { LoginItemManager.setEnabled(new.launchAtLogin) }
    }

    func setAPIKey(_ key: String) {
        do {
            if key.isEmpty {
                try secureStore.deleteSecret(account: KeychainStore.llmAPIKeyAccount)
            } else {
                try secureStore.setSecret(key, account: KeychainStore.llmAPIKeyAccount)
            }
        } catch {
            Log.security.error("Failed to store API key: \(String(describing: error), privacy: .public)")
        }
    }

    func hasAPIKey() -> Bool {
        (try? secureStore.secret(account: KeychainStore.llmAPIKeyAccount))?.isEmpty == false
    }

    func refreshHistory() {
        let all = (try? history.allRecords()) ?? []
        recentRecords = all.prefix(20).map { $0 }
        stats = DictationStats.summarize(all)
    }

    func deleteHistory(_ id: UUID) {
        try? history.delete(id: id)
        refreshHistory()
    }

    func clearHistory() {
        try? history.deleteAll()
        // Words learned from corrections are dictation history too — leaving them
        // on disk after "Clear History" would be a lie.
        corrections?.cancel()
        suggestionStore.removeAll()
        refreshSuggestions()
        refreshHistory()
    }

    // MARK: - Suggested vocabulary (Phase 4 — propose, never auto-apply)

    /// Notice words that SOUND like the user's vocabulary but came out spelled
    /// differently, and count them toward a suggestion.
    ///
    /// This replaces guesswork with the app's own observation. The old learning
    /// path watched the text field for six seconds after insertion and needed an
    /// Accessibility-readable field, the same app, and no send — measured
    /// 2026-08-19, it had seen ZERO corrections across 40 dictations in Claude
    /// (an Electron app) while catching 2 of 2 in Chrome. This signal needs none
    /// of that: it reads the transcript we already have.
    ///
    /// It PROPOSES only. "codecs" and "codices" are real English words, so no
    /// rule can tell "he said codecs" from "Codex was misheard" — substituting
    /// would silently destroy a word he meant, which is precisely the failure
    /// Wispr shipped. He approves an entry once; the deterministic replacer
    /// handles it forever after.
    private func noteMisheardVocabulary(in rawText: String) {
        let detector = PhoneticVocabulary(entries: settings.vocabulary)
        for miss in detector.nearMisses(in: rawText) {
            if let ready = suggestionStore.record(
                WordCorrection(heard: miss.heard, corrected: miss.written)) {
                Log.cleanup.notice("Vocabulary suggestion ready: \(ready.corrected, privacy: .public)")
                refreshSuggestions()
            }
        }
    }

    func refreshSuggestions() {
        vocabularySuggestions = suggestionStore.readySuggestions()
    }

    /// Turn a suggestion into a real vocabulary entry, at the user's request.
    func acceptSuggestion(_ suggestion: VocabularySuggestion) {
        var updated = settings
        let alreadyPresent = updated.vocabulary.contains {
            $0.spoken.caseInsensitiveCompare(suggestion.heard) == .orderedSame
                && $0.written == suggestion.corrected
        }
        if !alreadyPresent {
            updated.vocabulary.append(VocabularyEntry(spoken: suggestion.heard, written: suggestion.corrected))
            applySettings(updated)
        }
        suggestionStore.remove(id: suggestion.id)
        refreshSuggestions()
    }

    /// Drop a suggestion without acting on it; it won't be offered again.
    func dismissSuggestion(_ suggestion: VocabularySuggestion) {
        suggestionStore.remove(id: suggestion.id)
        refreshSuggestions()
    }

    func copyRecord(_ record: TranscriptRecord) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(record.cleanText, forType: .string)
    }
}

/// Detects a quick double-tap of Control from event-monitor callbacks, which
/// arrive off the main actor. Lock-guarded so the Sendable closure can use it.
private final class DoubleTapTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTap: Date?
    private var wasDown = false
    private var typedSinceTap = false

    func somethingTyped() {
        lock.lock(); defer { lock.unlock() }
        typedSinceTap = true
    }

    /// Returns true when this event completes a pure double-tap.
    func controlEvent(isPureControl: Bool, controlHeld: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let pressed = isPureControl && !wasDown
        wasDown = controlHeld
        guard pressed else { return false }
        let now = Date()
        if let last = lastTap, now.timeIntervalSince(last) < 0.6, !typedSinceTap {
            lastTap = nil
            return true
        }
        lastTap = now
        typedSinceTap = false
        return false
    }
}
