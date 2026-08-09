import Foundation

/// Orchestrates the cleanup stages: the deterministic rule engine always runs;
/// an optional LLM refinement runs on top when enabled and available. The LLM
/// stage is best-effort — any failure falls back to the rule-based result so the
/// pipeline never blocks dictation on a network or secret.
public struct CleanupPipeline: CleanupProviding {
    private let ruleEngine: RuleBasedCleanup
    private let llmProvider: CleanupProviding?
    private let useLLM: Bool

    public init(
        ruleEngine: RuleBasedCleanup = RuleBasedCleanup(),
        llmProvider: CleanupProviding? = nil,
        useLLM: Bool = false
    ) {
        self.ruleEngine = ruleEngine
        self.llmProvider = llmProvider
        self.useLLM = useLLM
    }

    public func prewarm() {
        guard useLLM else { return }
        llmProvider?.prewarm()
    }

    /// The rules-only result, produced with no model and no waiting.
    public func deterministicClean(_ rawText: String, context: CleanupContext) async throws -> String {
        finalTidy(ruleEngine.cleanSync(rawText, context: context), context: context)
    }

    public func clean(_ rawText: String, context: CleanupContext) async throws -> String {
        let base = ruleEngine.cleanSync(rawText, context: context)

        var result = base
        // Raw mode and "off" strength never get LLM refinement.
        if useLLM, context.mode != .raw, context.strength != .off, let llmProvider {
            if context.fastPathEnabled, ShortUtteranceFastPath.canSkipLLM(base, mode: context.mode) {
                // Short casual utterance: the rules already produce what the
                // guard-constrained model would have returned, ~1s sooner.
                Log.cleanup.notice("AI cleanup skipped (short utterance fast path)")
            } else {
                do {
                    let refined = try await llmProvider.clean(base, context: context)
                    let trimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
                    result = trimmed.isEmpty ? base : trimmed
                    Log.cleanup.notice("AI cleanup applied (\(base.count, privacy: .public)→\(result.count, privacy: .public) chars)")
                } catch VoiceFlowError.cleanupProviderUnavailable {
                    Log.cleanup.notice("AI cleanup unavailable; rule-based result")
                } catch {
                    Log.cleanup.error("AI cleanup failed, using rule-based result: \(String(describing: error), privacy: .public)")
                }
            }
        }

        return finalTidy(result, context: context)
    }

    /// Final prose tidy: kill doubled punctuation / segment-seam artifacts
    /// ("fix it.. our system." → "fix it. Our system.").
    private func finalTidy(_ text: String, context: CleanupContext) -> String {
        guard context.mode == .cleanWriting || context.mode == .email else { return text }
        return TextNormalizer.tidyProse(text)
    }
}
