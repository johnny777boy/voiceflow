import Foundation
import VoiceFlowCore

// Test doubles for the protocol seams. All tested types are public, so these
// conform without needing @testable.

final class MockAudioRecorder: AudioRecording, @unchecked Sendable {
    var isRecording: Bool = false
    var permissionGranted = true
    var captureToReturn = AudioCapture(samples: [0.1, 0.2, 0.1], sampleRate: 16_000, duration: 1.0)
    var startError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startRecording() throws {
        if let startError { throw startError }
        startCount += 1
        isRecording = true
    }
    func stopRecording() throws -> AudioCapture {
        stopCount += 1
        isRecording = false
        return captureToReturn
    }
    func requestPermission() async -> Bool { permissionGranted }
}

final class MockHotkeyManager: HotkeyManaging, @unchecked Sendable {
    private(set) var registered: HotkeyConfiguration?
    private var handler: (@Sendable (HotkeyEvent) -> Void)?

    func register(_ configuration: HotkeyConfiguration, handler: @escaping @Sendable (HotkeyEvent) -> Void) {
        self.registered = configuration
        self.handler = handler
    }
    func unregister() { registered = nil; handler = nil }
    func fire(_ event: HotkeyEvent) { handler?(event) }
}

final class MockTranscriber: Transcribing, @unchecked Sendable {
    var permissionGranted = true
    var resultToReturn = TranscriptionResult(text: "hello world")
    var error: Error?
    /// Simulates a transcription that takes real time, so a test can land another
    /// call while a dictation is genuinely mid-flight.
    var delay: TimeInterval = 0
    private(set) var lastLanguage: String?
    private(set) var lastContext: TranscriptionContext?

    func transcribe(_ audio: AudioCapture, languageCode: String) async throws -> TranscriptionResult {
        try await transcribe(audio, languageCode: languageCode, context: .empty)
    }
    func transcribe(
        _ audio: AudioCapture, languageCode: String, context: TranscriptionContext
    ) async throws -> TranscriptionResult {
        lastLanguage = languageCode
        lastContext = context
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let error { throw error }
        return resultToReturn
    }
    func requestPermission() async -> Bool { permissionGranted }
}

/// Stands in for the Accessibility screen reader. `delay` simulates an app that
/// is slow to answer AX queries, so the controller's no-wait rule can be tested.
final class MockScreenContextProvider: ScreenContextProviding, @unchecked Sendable {
    var text: String?
    var delay: TimeInterval

    init(text: String? = nil, delay: TimeInterval = 0) {
        self.text = text
        self.delay = delay
    }

    func frontmostWindowText() -> String? {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return text
    }
}

final class MockTextInserter: TextInserting, @unchecked Sendable {
    var capabilities = DestinationCapabilities(
        supportsAccessibilityInsertion: true,
        allowsSyntheticPaste: true,
        isSecureInput: false
    )
    var insertError: Error?
    /// Whether the destination accepts an in-place two-phase upgrade.
    var supportsReplacement = false
    private(set) var insertedText: String?
    private(set) var insertedStrategy: InsertionStrategy?
    private(set) var copiedText: String?
    private(set) var replacedText: String?
    private(set) var insertCount = 0

    func insert(_ text: String, using strategy: InsertionStrategy) throws -> InsertionOutcome {
        if let insertError { throw insertError }
        insertedText = text
        insertedStrategy = strategy
        insertCount += 1
        return InsertionOutcome(strategy: strategy, didInsert: strategy != .copyOnly)
    }

    func replaceLastInsertion(with newText: String) -> Bool {
        guard supportsReplacement else { return false }
        replacedText = newText
        insertedText = newText
        return true
    }
    func copyToClipboard(_ text: String) { copiedText = text }
    func currentCapabilities() -> DestinationCapabilities { capabilities }
}

final class MockActiveAppProvider: ActiveAppProviding, @unchecked Sendable {
    var snapshotToReturn: DestinationSnapshot

    init(snapshot: DestinationSnapshot = MockActiveAppProvider.terminal()) {
        self.snapshotToReturn = snapshot
    }
    func captureSnapshot() -> DestinationSnapshot { snapshotToReturn }

    static func terminal(secure: Bool = false) -> DestinationSnapshot {
        DestinationSnapshot(
            bundleIdentifier: "com.apple.Terminal",
            appName: "Terminal",
            windowTitle: "bash",
            focusedElementRole: "AXTextArea",
            focusedElementIdentifier: nil,
            isSecureInput: secure,
            capturedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    static func safari() -> DestinationSnapshot {
        DestinationSnapshot(
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "Gmail",
            focusedElementRole: "AXTextField",
            focusedElementIdentifier: nil,
            isSecureInput: false,
            capturedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }
}

final class InMemorySecureStore: SecureStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]
    func setSecret(_ value: String, account: String) throws { storage[account] = value }
    func secret(account: String) throws -> String? { storage[account] }
    func deleteSecret(account: String) throws { storage[account] = nil }
}
