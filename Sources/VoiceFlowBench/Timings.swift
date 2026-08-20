import Foundation
@preconcurrency import WhisperKit
import VoiceFlowCore
import VoiceFlowWhisper

/// Print the PAUSE STRUCTURE of a dictation.
///
/// Codex's diagnosis, 2026-08-20: we decode with `withoutTimestamps = true` and
/// `wordTimestamps = false`, then ask a text-only model where sentences end.
/// It cannot hear a pause, so it guesses, and the guard correctly rejects the
/// guesses. The timing evidence was there and we were discarding it.
///
/// This dumps what we were throwing away, so prosody-first segmentation can be
/// judged on his real speech before any of it is built.
@available(macOS 26.0, *)
@MainActor
func printTimings(audio: String, model: String) async throws {
    let (pipeline, _) = try await WhisperModelManager.loadPipeline(variant: model)
    let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio)
    let trimmed = LeadingSilence.trimmed(samples, sampleRate: 16_000)
    var options = DecodingOptions()
    options.language = "en"
    options.temperature = 0
    options.withoutTimestamps = false
    options.wordTimestamps = true
    options.chunkingStrategy = ChunkingStrategy.none
    let results = try await pipeline.transcribe(audioArray: trimmed, decodeOptions: options)
    let words = results.flatMap { $0.segments }.compactMap { $0.words }.flatMap { $0 }
    guard !words.isEmpty else { print("no word timings returned"); return }
    print("\n\(words.count) words, \(String(format: "%.1f", Double(trimmed.count) / 16_000))s\n")
    print("gaps of 250ms or more — candidate sentence boundaries:\n")
    var previousEnd = words.first?.end ?? 0
    var gaps: [(Float, String, String)] = []
    for (i, w) in words.enumerated() where i > 0 {
        let gap = w.start - previousEnd
        if gap >= 0.25 {
            gaps.append((gap, words[i - 1].word.trimmingCharacters(in: .whitespaces),
                         w.word.trimmingCharacters(in: .whitespaces)))
        }
        previousEnd = w.end
    }
    for (gap, before, after) in gaps.sorted(by: { $0.0 > $1.0 }) {
        print(String(format: "  %.2fs   …%@ | %@…", gap, before, after))
    }
    print("\n\(gaps.count) candidate boundaries from pauses alone.")
}
