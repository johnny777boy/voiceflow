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
        // DIAGNOSTIC LOGGING (2026-08-18): three very different failures used to
        // throw the same error and print one indistinguishable line ("AI cleanup
        // unavailable"), which hid WHY dictations were never being repaired.
        // Each cause now says its own name; content stays .private.
        guard SystemLanguageModel.default.isAvailable else {
            Log.cleanup.error("AI cleanup: Apple Intelligence reports the model UNAVAILABLE")
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
        guard !text.isEmpty else {
            Log.cleanup.error("AI cleanup: model returned EMPTY output")
            throw VoiceFlowError.cleanupProviderUnavailable
        }

        // Safety net: cleanup must edit, not rewrite. If the model changed meaning
        // (dropped a negation, changed a number, or rewrote the whole topic), reject
        // it so the pipeline falls back to the deterministic result.
        // Per-SENTENCE reconciliation, not all-or-nothing: one overstepping
        // clause used to discard every other repair in the dictation.
        let merged = CleanupGuard.safelyMerged(
            original: rawText, cleaned: text, policy: context.guardPolicy)
        if merged == text {
            Log.cleanup.notice("AI cleanup: guard ACCEPTED the edit (\(rawText.count, privacy: .public)→\(text.count, privacy: .public) chars)")
        } else if merged == rawText {
            Log.cleanup.error("AI cleanup: guard REJECTED every sentence — delivering unrepaired text")
            Log.cleanup.debug("AI cleanup rejected — was: \(rawText, privacy: .private) / proposed: \(text, privacy: .private)")
            throw VoiceFlowError.cleanupProviderUnavailable
        } else {
            Log.cleanup.notice("AI cleanup: guard kept the SAFE sentences and reverted the rest (\(rawText.count, privacy: .public)→\(merged.count, privacy: .public) chars)")
        }
        return merged
    }
}
