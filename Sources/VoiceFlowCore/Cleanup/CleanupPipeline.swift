import Foundation

/// Thrown when the optional AI polish outruns its deadline. Never surfaced to
/// the user — the pipeline falls back to the deterministic result.
struct CleanupTimeout: Error {}

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
                    let refined = try await Self.withDeadline(seconds: context.cleanupTimeout) {
                        try await llmProvider.clean(base, context: context)
                    }
                    let trimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
                    result = trimmed.isEmpty ? base : trimmed
                    Log.cleanup.notice("AI cleanup applied (\(base.count, privacy: .public)→\(result.count, privacy: .public) chars)")
                } catch VoiceFlowError.cleanupProviderUnavailable {
                    Log.cleanup.notice("AI cleanup unavailable; rule-based result")
                } catch is CancellationError {
                    throw CancellationError()   // a cancelled dictation stays cancelled
                } catch is CleanupTimeout {
                    Log.cleanup.error("AI cleanup TIMED OUT after \(context.cleanupTimeout, privacy: .public)s — delivering the rule-based result")
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

    /// Run `work`, abandoning it if it exceeds `seconds`.
    ///
    /// A task group CANNOT do this job, and the first version of this function
    /// wrongly used one: `withThrowingTaskGroup` awaits every child before it
    /// returns, and `cancelAll()` is only a cooperative request. Measured with a
    /// child that ignores cancellation (the shape of a hung XPC/ANE call), a 1s
    /// deadline returned after 8.5s — i.e. it did not bound the very hang it was
    /// written to bound.
    ///
    /// So: race the work against a timer through a once-guarded continuation and
    /// ABANDON the loser. A genuinely wedged model task then leaks until the OS
    /// reaps it — the correct trade, because the alternative is losing the user's
    /// dictation, and delivery is not optional.
    static func withDeadline<T: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard seconds > 0, seconds.isFinite else { return try await work() }
        let claimed = Claim()
        let workTask = Task { try await work() }
        let timerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                Task {
                    do {
                        let value = try await workTask.value
                        if claimed.claim() { continuation.resume(returning: value) }
                    } catch {
                        if claimed.claim() { continuation.resume(throwing: error) }
                    }
                }
                Task {
                    await timerTask.value
                    if claimed.claim() { continuation.resume(throwing: CleanupTimeout()) }
                }
            }
        } onCancel: {
            workTask.cancel()
            timerTask.cancel()
        }
    }

    /// One-shot winner flag: whichever racer arrives first resumes the
    /// continuation, and a second resume is structurally impossible.
    private final class Claim: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }

}
