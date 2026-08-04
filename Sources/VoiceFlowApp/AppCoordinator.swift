import Foundation
import AppKit
import SwiftUI
import VoiceFlowCore

/// Observable app state that bridges the SwiftUI UI with the `DictationController`
/// actor and the global hotkey. Owns permission flow, settings persistence, and
/// the recording lifecycle.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var isRecording = false
    @Published private(set) var statusText = "Ready"
    @Published private(set) var lastResult: DictationResult?
    @Published private(set) var recentRecords: [TranscriptRecord] = []
    @Published private(set) var accessibilityGranted = false

    private let controller: DictationController
    private let hotkeys: GlobalHotkeyManager
    private let settingsStore: SettingsStore
    private let history: HistoryStoring
    private let secureStore: SecureStoring
    private let overlay = OverlayController()

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
        self.controller = DictationController(
            audio: AudioEngineRecorder(),
            transcriber: SpeechTranscriber(),
            cleanup: pipeline,
            inserter: AccessibilityTextInserter(),
            activeApp: WorkspaceActiveAppProvider(),
            history: store,
            settings: loaded
        )
    }

    // MARK: - Lifecycle

    func start() {
        accessibilityGranted = AX.hasAccessibilityPermission(prompt: true)
        Task { await requestPermissions() }
        registerHotkey()
        refreshHistory()
    }

    private func requestPermissions() async {
        _ = await AudioEngineRecorder().requestPermission()
        _ = await SpeechTranscriber().requestPermission()
        await MainActor.run { accessibilityGranted = AX.hasAccessibilityPermission(prompt: false) }
    }

    private func registerHotkey() {
        hotkeys.register(settings.hotkey) { [weak self] event in
            // Hotkey callback arrives on the main run loop; hop to the actor via Task.
            Task { @MainActor in
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: HotkeyEvent) async {
        switch event {
        case .pressed:
            await beginRecording()
        case .released:
            await finishRecording()
        case .toggled:
            if isRecording { await finishRecording() } else { await beginRecording() }
        }
    }

    // MARK: - Recording

    func beginRecording() async {
        guard !isRecording else { return }
        do {
            try await controller.beginRecording()
            isRecording = true
            statusText = "Listening…"
            overlay.show(state: .recording)
        } catch {
            statusText = "Mic error: \(error.localizedDescription)"
            overlay.show(state: .error(statusText))
        }
    }

    func finishRecording() async {
        guard isRecording else { return }
        isRecording = false
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
        Task { await controller.cancelRecording() }
        isRecording = false
        statusText = "Cancelled"
        overlay.hide()
    }

    // MARK: - Settings & history

    func applySettings(_ new: AppSettings) {
        settings = new
        try? settingsStore.save(new)
        Task { await controller.updateSettings(new) }
        registerHotkey()
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
