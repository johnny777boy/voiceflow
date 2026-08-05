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
        let response = try await session.respond(to: rawText)
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceFlowError.cleanupProviderUnavailable }
        return text
    }
}
