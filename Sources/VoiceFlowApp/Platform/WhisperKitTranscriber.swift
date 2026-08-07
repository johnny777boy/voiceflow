import Foundation
@preconcurrency import WhisperKit
import VoiceFlowCore

/// Optional high-accuracy transcriber: on-device **Whisper** via WhisperKit,
/// running on the Apple Neural Engine (Core ML — no Metal compiler needed).
/// Whisper is trained on hugely diverse, accented, real-world speech, so it
/// handles non-native English better than Apple's model — at the cost of ~1–2s
/// latency and a one-time model download. Audio stays on-device.
///
/// It only transcribes; `SpeechAnalyzerDictation` still records the audio to a
/// file and passes its URL through `AudioCapture.fileURL`.
///
/// This class NEVER downloads or loads the model itself — `WhisperModelManager`
/// does that in the background and hands the ready pipeline to `adopt(_:)`.
/// Until then `isReady` is false and the `FallbackTranscriber` routes dictations
/// to the Apple engine, so nothing ever fails or blocks on the ~1 GB download.
@available(macOS 14.0, *)
final class WhisperKitTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private var pipeline: WhisperKit?

    /// Thread-safe readiness check for the per-dictation route.
    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return pipeline != nil
    }

    /// Called by `WhisperModelManager` once the model is downloaded and loaded.
    func adopt(_ loaded: WhisperKit) {
        lock.lock(); defer { lock.unlock() }
        pipeline = loaded
    }

    /// Drop the pipeline (user turned the toggle off) so memory is reclaimed.
    func unload() {
        lock.lock(); defer { lock.unlock() }
        pipeline = nil
    }

    private func currentPipeline() -> WhisperKit? {
        lock.lock(); defer { lock.unlock() }
        return pipeline
    }

    func requestPermission() async -> Bool { true }   // mic handled by the recorder

    func transcribe(_ audio: AudioCapture, languageCode: String) async throws -> VoiceFlowCore.TranscriptionResult {
        guard let wk = currentPipeline() else {
            throw VoiceFlowError.audioEngineFailure("Whisper model not ready.")
        }
        guard let url = audio.fileURL else { throw VoiceFlowError.emptyTranscript }

        // Decoding options per the parity research: force English with the prefill
        // prompt (language mis-detect is a catastrophic failure mode on accented
        // speech), greedy decode with the temperature-fallback schedule ON, no
        // timestamps (shorter/faster decode for dictation), and NO VAD chunking —
        // dictations are single ≤30s windows and chunking risks splitting words.
        var options = DecodingOptions()
        options.task = .transcribe
        let lang = String(languageCode.prefix(2))
        options.language = lang.isEmpty ? "en" : lang
        options.usePrefillPrompt = true
        options.detectLanguage = false
        options.temperature = 0
        options.temperatureFallbackCount = 3   // default 5 only adds tail latency
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.wordTimestamps = false
        options.chunkingStrategy = ChunkingStrategy.none

        let results = try await wk.transcribe(audioPath: url.path, decodeOptions: options)
        let text = results.map { $0.text }.joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Log.transcription.notice("WhisperKit transcribed \(text.count, privacy: .public) chars")
        guard !text.isEmpty else { throw VoiceFlowError.emptyTranscript }
        // Success: the capture file is consumed here. On ANY failure above we leave
        // the file alone — the FallbackTranscriber re-runs the Apple engine, which
        // reads the same file via its internal URL.
        try? FileManager.default.removeItem(at: url)
        return VoiceFlowCore.TranscriptionResult(text: text)
    }
}
