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
    private var suppressTokens: [Int] = []

    /// Thread-safe readiness check for the per-dictation route.
    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return pipeline != nil
    }

    /// Called by `WhisperModelManager` once the model is downloaded and loaded.
    func adopt(_ loaded: WhisperKit) {
        // Resolve the non-speech suppression token set once per loaded model
        // (token ids differ across vocab versions, so never hardcode them).
        let tokens = loaded.tokenizer.map(Self.nonSpeechTokens) ?? []
        lock.lock(); defer { lock.unlock() }
        pipeline = loaded
        suppressTokens = tokens
    }

    /// Drop the pipeline (user turned the toggle off) so memory is reclaimed.
    func unload() {
        lock.lock(); defer { lock.unlock() }
        pipeline = nil
    }

    private func currentPipeline() -> (WhisperKit, [Int])? {
        lock.lock(); defer { lock.unlock() }
        guard let pipeline else { return nil }
        return (pipeline, suppressTokens)
    }

    /// Port of OpenAI whisper `tokenizer.non_speech_tokens`: symbol tokens
    /// (brackets, quotes, music notes, …) whose emission on quiet/noisy audio is
    /// artifact, not dictation. WhisperKit v0.18 leaves this set empty by default
    /// (`// TODO` in Configurations.swift), so we build it ourselves. Logit
    /// suppression cannot delete spoken words — it only bans symbol tokens.
    private static func nonSpeechTokens(_ tokenizer: any WhisperTokenizer) -> [Int] {
        let specialBegin = tokenizer.specialTokens.specialTokenBegin
        func enc(_ s: String) -> [Int] { tokenizer.encode(text: s).filter { $0 < specialBegin } }
        var result = Set<Int>()
        if let t = enc(" -").first { result.insert(t) }
        if let t = enc(" '").first { result.insert(t) }
        let symbols = "\"#()*+/:;<=>@[]^_`{|}~「」『』".map(String.init)
            + ["<<", ">>", "<<<", ">>>", "--", "---", "-(", "-[", "('", "((", "))", "(((", ")))", "[[", "]]", "{{", "}}", "♪♪", "♪♪♪"]
        let miscellaneous: Set<String> = ["♩", "♪", "♫", "♬", "♭", "♮", "♯"]
        for s in symbols + Array(miscellaneous) {
            for ids in [enc(s), enc(" " + s)] {
                if ids.count == 1 {
                    result.insert(ids[0])
                } else if miscellaneous.contains(s) {
                    ids.forEach { result.insert($0) }
                }
            }
        }
        return result.sorted()
    }

    func requestPermission() async -> Bool { true }   // mic handled by the recorder

    func transcribe(_ audio: AudioCapture, languageCode: String) async throws -> VoiceFlowCore.TranscriptionResult {
        guard let (wk, suppress) = currentPipeline() else {
            throw VoiceFlowError.audioEngineFailure("Whisper model not ready.")
        }
        guard let url = audio.fileURL else { throw VoiceFlowError.emptyTranscript }

        // Load once (resampled to 16kHz mono by WhisperKit) and measure energy in
        // 100ms chunks. Whisper hallucinates full sentences on silence, so a
        // truly-silent clip (accidental key-press) must never reach the decoder.
        // Thresholds are DELIBERATELY far below WhisperKit's speech default
        // (0.02 RMS): a quiet accented speaker must never be gated. Both RMS and
        // peak must agree before we discard. Energies are logged on every clip so
        // the thresholds can be tuned from real data.
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        let chunkSize = 1600   // 100ms @ 16kHz
        var maxChunkRMS: Float = 0
        var index = 0
        while index < samples.count {
            let chunk = Array(samples[index..<min(index + chunkSize, samples.count)])
            maxChunkRMS = max(maxChunkRMS, AudioProcessor.calculateAverageEnergy(of: chunk))
            index += chunkSize
        }
        let peak = AudioProcessor.calculateEnergy(of: samples).max
        Log.transcription.notice("Whisper clip energy: maxRMS=\(maxChunkRMS, privacy: .public) peak=\(peak, privacy: .public)")
        if maxChunkRMS < 0.005, peak < 0.015 {
            Log.transcription.notice("Whisper energy gate: silent clip — skipping decode")
            throw VoiceFlowError.emptyTranscript
        }

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
        // One retry step (temps 0, 0.2): keeps the only escape hatch for greedy
        // repetition loops while capping added latency and randomness. Do NOT
        // tighten logProbThreshold below the -1.0 default — that converts marginal
        // accented clips into random high-temperature resampling.
        options.temperatureFallbackCount = 1
        options.skipSpecialTokens = true
        options.suppressBlank = true      // keep [BLANK_AUDIO]-style tokens out on quiet clips
        // NOTE: options.noSpeechThreshold is DEAD CONFIG in WhisperKit v0.18.0 —
        // noSpeechProb is hardcoded 0 (TextDecoder.swift "TODO: implement no
        // speech prob"), so the decoder-side silence gate can never fire. All
        // silence defense lives in the energy gate above + post-filter below.
        // Re-audit this (and prefill interaction, WhisperKit issue #27) on any
        // WhisperKit version bump.
        options.supressTokens = suppress   // (sic — WhisperKit API spelling)
        options.withoutTimestamps = true
        options.wordTimestamps = false
        options.chunkingStrategy = ChunkingStrategy.none

        let results = try await wk.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map { $0.text }.joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Log.transcription.notice("WhisperKit transcribed \(text.count, privacy: .public) chars")
        guard !text.isEmpty else { throw VoiceFlowError.emptyTranscript }

        // Phantom-phrase post-filter: catches the hallucinations that pass the
        // energy gate (breaths/noise with real energy). Whole-output match plus a
        // corroborating doubt signal required — see TranscriptSanity for the
        // safety analysis. A confidently transcribed audible "Thank you." passes.
        let minLogProb = results.flatMap { $0.segments }.map { $0.avgLogprob }.min()
        if TranscriptSanity.isLikelyHallucination(
            text: text,
            minAvgLogProb: minLogProb,
            nearSilence: maxChunkRMS < 0.01
        ) {
            Log.transcription.notice("Whisper post-filter: dropped probable hallucination \"\(text, privacy: .public)\" (logProb=\(minLogProb ?? 0, privacy: .public) maxRMS=\(maxChunkRMS, privacy: .public))")
            throw VoiceFlowError.emptyTranscript
        }
        // Success: the capture file is consumed here. On ANY failure above we leave
        // the file alone — the FallbackTranscriber re-runs the Apple engine, which
        // reads the same file via its internal URL.
        try? FileManager.default.removeItem(at: url)
        return VoiceFlowCore.TranscriptionResult(text: text)
    }
}
