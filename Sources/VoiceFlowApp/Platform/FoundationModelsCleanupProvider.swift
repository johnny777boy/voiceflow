import Foundation
import FoundationModels
import VoiceFlowCore

/// AI cleanup powered by Apple's **on-device Foundation Models** (Apple Intelligence,
/// macOS 26). Fixes grammar, punctuation, and imperfect/non-native English locally —
/// **no API key, no cloud, no cost, fully private**. This is how a Wispr-class app
/// polishes dictation without asking the user for a key.
///
/// If Apple Intelligence isn't available/enabled, it throws
/// `cleanupProviderUnavailable` so the pipeline falls back to deterministic rules.
@available(macOS 26.0, *)
final class FoundationModelsCleanupProvider: CleanupProviding, @unchecked Sendable {

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Load the model's weights while the user is still talking, so the LLM pass
    /// starts warm instead of paying a cold start on the first dictation of a
    /// session. A NEW session is still created per dictation — reusing one would
    /// accumulate transcript history and let earlier dictations bleed into later
    /// cleanups, which is exactly the drift the verbatim guard exists to stop.
    func prewarm() {
        guard SystemLanguageModel.default.isAvailable else { return }
        let instructions = CleanupPromptBuilder.systemPrompt(for: .cleanWriting, strength: .standard)
        LanguageModelSession(instructions: instructions).prewarm()
    }

    func clean(_ rawText: String, context: CleanupContext) async throws -> String {
        guard SystemLanguageModel.default.isAvailable else {
            throw VoiceFlowError.cleanupProviderUnavailable
        }
        let instructions = CleanupPromptBuilder.systemPrompt(for: context.mode, strength: context.strength)
        let session = LanguageModelSession(instructions: instructions)
        // Deterministic + conservative: greedy sampling with temperature 0 stops the
        // small on-device model from paraphrasing or drifting, so it edits rather
        // than rewrites. Cap the output near the input size.
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0,
            maximumResponseTokens: max(256, rawText.count)
        )
        let response = try await session.respond(to: rawText, options: options)
        // Strip any "Here is the cleaned text:" preamble the small model leaks despite
        // instructions, then trim.
        let text = TextNormalizer.stripLLMPreamble(response.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceFlowError.cleanupProviderUnavailable }

        // Safety net: cleanup must edit, not rewrite. If the model changed meaning
        // (dropped a negation, changed a number, or rewrote the whole topic), reject
        // it so the pipeline falls back to the deterministic result.
        guard CleanupGuard.preservesMeaning(original: rawText, cleaned: text) else {
            throw VoiceFlowError.cleanupProviderUnavailable
        }
        return text
    }
}
