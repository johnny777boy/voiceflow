import Foundation

/// Result of a transcription request.
public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    /// Recognizer confidence 0...1 when available (else 1).
    public let confidence: Float
    public init(text: String, confidence: Float = 1) {
        self.text = text
        self.confidence = confidence
    }
}

/// Abstraction over speech-to-text (SFSpeechRecognizer in production; a protocol
/// so a local Whisper or a cloud engine can be substituted).
public protocol Transcribing: AnyObject, Sendable {
    /// Transcribe captured audio into text for the given BCP-47 language.
    func transcribe(_ audio: AudioCapture, languageCode: String) async throws -> TranscriptionResult
    /// Transcribe with per-dictation recognition context (vocabulary + on-screen
    /// proper nouns) to bias decoding. Engines that can't use context inherit the
    /// default implementation, which simply ignores it — so adding context can
    /// never change the behavior of an engine that doesn't support it.
    func transcribe(
        _ audio: AudioCapture, languageCode: String, context: TranscriptionContext
    ) async throws -> TranscriptionResult
    /// Request speech-recognition authorization; returns whether granted.
    func requestPermission() async -> Bool
}

public extension Transcribing {
    func transcribe(
        _ audio: AudioCapture, languageCode: String, context: TranscriptionContext
    ) async throws -> TranscriptionResult {
        try await transcribe(audio, languageCode: languageCode)
    }
}
