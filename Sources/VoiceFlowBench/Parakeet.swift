import Foundation
import FluidAudio
import VoiceFlowCore

/// Decode his archived audio with Parakeet, to judge it on HIS voice rather than
/// on a leaderboard.
///
/// Codex's one serious engine suggestion (2026-08-20): NVIDIA reports
/// parakeet-tdt-0.6b at ~6 average WER, and our own measurements had already
/// falsified "a bigger Whisper will fix it" — full large-v3 changed nothing on
/// identical audio. A different ARCHITECTURE is a different question from a
/// bigger model of the same kind.
///
/// This is a SHADOW benchmark. The app does not link FluidAudio, so nothing here
/// can touch a real dictation. If Parakeet wins on substitutions without adding
/// insertions, integration becomes a conversation; if not, another dead end is
/// closed cheaply, which is the whole point of having the harness.
@available(macOS 14.0, *)
func runParakeet(files: [URL], out: String?) async throws {
    FileHandle.standardError.write(
        "loading Parakeet (first run downloads the CoreML models)…\n".data(using: .utf8)!)
    let models = try await AsrModels.downloadAndLoad()
    let asr = AsrManager(config: .default, models: models)
    var lines: [String] = []
    var total = 0.0
    for (i, url) in files.enumerated() {
        // A fresh decoder state per file: these are separate dictations, not one
        // continuous stream, and carrying state across them would let one
        // utterance condition the next.
        var state = try TdtDecoderState()
        let started = Date()
        let result = try await asr.transcribe(url, decoderState: &state)
        let elapsed = Date().timeIntervalSince(started)
        total += elapsed
        let text = result.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(text)
        FileHandle.standardError.write(
            String(format: "  [%d/%d] %.2fs  %@\n", i + 1, files.count, elapsed,
                   url.lastPathComponent).data(using: .utf8)!)
    }
    let body = lines.joined(separator: "\n") + "\n"
    if let out {
        do { try body.write(toFile: out, atomically: true, encoding: .utf8) }
        catch {
            FileHandle.standardError.write("FAILED to write \(out): \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        FileHandle.standardError.write("wrote \(out)\n".data(using: .utf8)!)
    } else {
        print(body, terminator: "")
    }
    FileHandle.standardError.write(
        String(format: "parakeet  files=%d  decode=%.1fs total\n", files.count, total)
            .data(using: .utf8)!)
}
