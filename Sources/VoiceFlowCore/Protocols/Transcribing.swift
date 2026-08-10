import Foundation

/// Result of a transcription request.
public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    /// Recognizer confidence 0...1 when available (else 1).
    public let confidence: Float
    /// Which engine produced `text` ("whisper" / "apple"), when known. Purely
    /// diagnostic — nothing may branch on it.
    public let engineName: String?
    /// Seconds the primary model spent decoding, when the engine measured it.
    public let decodeSeconds: Double?
    /// Seconds spent consulting the second-opinion engine (phantom check, echo
    /// check, or vocabulary voting), when one ran. nil = no arbiter ran. This is
    /// the number that explains why two dictations of the same length can differ
    /// by seconds.
    public let arbiterSeconds: Double?
    public init(
        text: String, confidence: Float = 1,
        engineName: String? = nil, decodeSeconds: Double? = nil, arbiterSeconds: Double? = nil
    ) {
        self.text = text
        self.confidence = confidence
        self.engineName = engineName
        self.decodeSeconds = decodeSeconds
        self.arbiterSeconds = arbiterSeconds
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
