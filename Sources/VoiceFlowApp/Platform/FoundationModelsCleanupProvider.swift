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
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceFlowError.cleanupProviderUnavailable }

        // Safety net: cleanup must edit, not rewrite. Reject and fall back to the
        // deterministic result if the model changed the content — so we never ship
        // text that changed the user's meaning.
        //
        // (a) Length: reject a ballooned (hallucinated) or gutted output.
        let inWords = rawText.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        let outWords = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        if inWords >= 3, (outWords > inWords * 2 || outWords * 3 < inWords) {
            throw VoiceFlowError.cleanupProviderUnavailable
        }
        // (b) Content preservation: most of the significant words (>3 chars, so we
        // ignore filler/articles that cleanup is allowed to drop) must survive. A
        // paraphrase that swaps content words fails this even at the same length.
        let significant = Self.significantWords(rawText)
        if significant.count >= 4 {
            let kept = Set(Self.significantWords(text))
            let survived = significant.filter { kept.contains($0) }.count
            if Double(survived) / Double(significant.count) < 0.6 {
                throw VoiceFlowError.cleanupProviderUnavailable
            }
        }
        return text
    }

    private static func significantWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { $0.count > 3 }
    }
}
