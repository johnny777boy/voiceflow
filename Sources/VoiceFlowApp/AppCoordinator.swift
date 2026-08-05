import Foundation
import AppKit
import SwiftUI
import AVFoundation
import Speech
import VoiceFlowCore

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
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var microphoneGranted = false
    @Published private(set) var speechGranted = false
    @Published private(set) var inputMonitoringGranted = false

    private let controller: DictationController
    private let live: LiveSpeechDictation
    private let hotkeys: GlobalHotkeyManager
    private let settingsStore: SettingsStore
    private let history: HistoryStoring
    private let secureStore: SecureStoring
    private let overlay = OverlayController()
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

        let pipeline = CleanupPipeline(
            llmProvider: LLMCleanupProvider(secureStore: secureStore),
            useLLM: loaded.useLLMCleanup
        )
        // One live engine serves both the audio and transcription seams so
        // recognition streams while you speak (captures full-length dictation).
        let live = LiveSpeechDictation()
        live.preferredLanguage = loaded.languageCode
        self.live = live
        self.controller = DictationController(
            audio: live,
            transcriber: live,
            cleanup: pipeline,
            inserter: AccessibilityTextInserter(),
            activeApp: WorkspaceActiveAppProvider(),
            history: store,
            settings: loaded
        )
    }

    // MARK: - Lifecycle

    func start() {
        guard !didStart else { return }   // idempotent: safe if invoked more than once
        didStart = true
        // Feed the live mic level into the floating waveform pill AND the window.
        live.levelHandler = { [weak self] level in
            Task { @MainActor in
                self?.overlay.updateLevel(level)
                self?.audioLevel = CGFloat(level)
            }
        }
        // Bias recognition toward the user's saved names/terms.
        live.contextualStrings = contextualStrings(from: settings)
        refreshPermissionStatus()
        _ = AX.hasAccessibilityPermission(prompt: true)   // nudge the AX prompt once
        InputMonitoring.request()                         // nudge the Input Monitoring prompt
        Task { await requestPermissions() }
        registerHotkey()
        LoginItemManager.setEnabled(settings.launchAtLogin)
        refreshHistory()

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
    }

    private func refreshPermissionStatus() {
        accessibilityGranted = AX.hasAccessibilityPermission(prompt: false)
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        inputMonitoringGranted = InputMonitoring.isGranted()
    }

    private func requestPermissions() async {
        _ = await AudioEngineRecorder().requestPermission()
        _ = await SpeechTranscriber().requestPermission()
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
        recentRecords = (try? history.allRecords())?.prefix(20).map { $0 } ?? []
    }

    func deleteHistory(_ id: UUID) {
        try? history.delete(id: id)
        refreshHistory()
    }

    func clearHistory() {
        try? history.deleteAll()
        refreshHistory()
    }

    func copyRecord(_ record: TranscriptRecord) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(record.cleanText, forType: .string)
    }
}
