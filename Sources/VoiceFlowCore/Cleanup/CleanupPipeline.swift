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

    public func clean(_ rawText: String, context: CleanupContext) async throws -> String {
        let base = ruleEngine.cleanSync(rawText, context: context)

        // Raw mode and "off" strength never get LLM refinement.
        guard useLLM, context.mode != .raw, context.strength != .off, let llmProvider else {
            return base
        }

        do {
            let refined = try await llmProvider.clean(base, context: context)
            let trimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
            // Guard against an LLM that returns nothing useful; return the trimmed
            // form so no stray leading/trailing whitespace reaches insertion.
            return trimmed.isEmpty ? base : trimmed
        } catch VoiceFlowError.cleanupProviderUnavailable {
            // No API key configured — expected; use the rule-based result silently.
            return base
        } catch {
            Log.cleanup.error("LLM cleanup failed, using rule-based result: \(String(describing: error), privacy: .public)")
            return base
        }
    }
}
