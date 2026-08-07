import Foundation
@preconcurrency import WhisperKit
import VoiceFlowCore

/// Optional high-accuracy transcriber: on-device **Whisper** (large-v3-turbo) via
/// WhisperKit, running on the Apple Neural Engine (Core ML — no Metal compiler
/// needed). Trained on hugely diverse, accented, real-world speech, so it handles
/// non-native English better than Apple's model — at the cost of ~1–2s latency and
/// a one-time model download. Audio stays on-device.
///
/// It only transcribes; `SpeechAnalyzerDictation` still records the audio to a file
/// and passes its URL through `AudioCapture.fileURL`.
@available(macOS 14.0, *)
final class WhisperKitTranscriber: Transcribing, @unchecked Sendable {
    private let modelName: String
    private var pipeline: WhisperKit?

    init(model: String = "large-v3-turbo") { self.modelName = model }

    func requestPermission() async -> Bool { true }   // mic handled by the recorder

    /// Load the model once (downloads it on first use).
    private func loadedPipeline() async throws -> WhisperKit {
        if let pipeline { return pipeline }
        Log.transcription.notice("WhisperKit: loading \(self.modelName, privacy: .public) (first run downloads it)")
        let wk = try await WhisperKit(WhisperKitConfig(model: modelName))
        pipeline = wk
        return wk
    }

    func transcribe(_ audio: AudioCapture, languageCode: String) async throws -> VoiceFlowCore.TranscriptionResult {
        guard let url = audio.fileURL else { throw VoiceFlowError.emptyTranscript }
        defer { try? FileManager.default.removeItem(at: url) }

        let wk = try await loadedPipeline()
        var options = DecodingOptions()
        options.language = String(languageCode.prefix(2))   // e.g. "en" — skip language detection

        let results = try await wk.transcribe(audioPath: url.path, decodeOptions: options)
        let text = results.map { $0.text }.joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Log.transcription.notice("WhisperKit transcribed \(text.count, privacy: .public) chars")
        guard !text.isEmpty else { throw VoiceFlowError.emptyTranscript }
        return VoiceFlowCore.TranscriptionResult(text: text)
    }
}
