import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

/// Verbatim-fidelity regression tests: the cleanup pipeline must never fabricate,
/// substitute, or destroy words the user actually spoke. Each case here is a
/// corruption that was PROVEN by execution during the 2026-08-07 research pass.
func runVerbatimTests(_ s: TestSuite) {
    let vocab = VocabularyEntry.defaults
    func ctx(_ mode: DictationMode, strength: CleanupStrength = .standard,
             spokenPunctuation: Bool = false) -> CleanupContext {
        CleanupContext(mode: mode, strength: strength, vocabulary: vocab,
                       languageCode: "en-US", spokenPunctuationEnabled: spokenPunctuation)
    }
    let rules = RuleBasedCleanup()

    s.test("raw mode is truly verbatim — vocabulary substitution must not run") { s in
        s.expectEqual(rules.cleanSync("i use postgres and next js daily", context: ctx(.raw)),
                      "i use postgres and next js daily")
        s.expectEqual(rules.cleanSync("i use postgres daily", context: ctx(.cleanWriting, strength: .off)),
                      "i use postgres daily")
    }

    s.test("spoken punctuation is OFF by default — 'period'/'comma' survive as words") { s in
        s.expectEqual(rules.cleanSync("during that period we met", context: ctx(.cleanWriting)),
                      "During that period we met.")
        s.expectEqual(rules.cleanSync("put a comma there", context: ctx(.cleanWriting)),
                      "Put a comma there.")
        s.expectEqual(rules.cleanSync("the colon is an organ", context: ctx(.cleanWriting)),
                      "The colon is an organ.")
    }

    s.test("spoken punctuation still works when the user opts in") { s in
        let out = rules.cleanSync("stop period", context: ctx(.cleanWriting, spokenPunctuation: true))
        s.expect(out.hasSuffix("."), "trailing spoken 'period' becomes punctuation, got: \(out)")
        s.expectFalse(out.lowercased().contains("period"), "the word itself is consumed")
    }

    s.test("filler removal no longer destroys ER / err / ah") { s in
        s.expectEqual(rules.cleanSync("the ER doctor saw him", context: ctx(.cleanWriting)),
                      "The ER doctor saw him.")
        s.expect(rules.cleanSync("to err is human", context: ctx(.cleanWriting)).lowercased().contains("err"))
        s.expectEqual(rules.cleanSync("um okay", context: ctx(.cleanWriting)), "Okay.",
                      "unambiguous fillers are still removed")
    }

    s.test("CleanupGuard rejects invented words (homophone swaps, additions)") { s in
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "take the pill after dinner", cleaned: "take the peel after dinner"))
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "please send the check to the client", cleaned: "please send the czech to the client"))
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "meet me at the bank", cleaned: "meet me at the tank"))
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "delete the old file", cleaned: "please delete the old file first thing tomorrow"))
    }

    s.test("CleanupGuard still allows legitimate grammar fixes (stem variants)") { s in
        s.expect(CleanupGuard.preservesMeaning(
            original: "i am interesting for discuss the plan",
            cleaned: "I am interested in discussing the plan."))
        s.expect(CleanupGuard.preservesMeaning(
            original: "send the report",
            cleaned: "Send the report."))
    }

    s.test("TranscriptSanity drops phantom phrases only with corroboration") { s in
        // Whole-output phantom + low confidence ⇒ drop.
        s.expect(TranscriptSanity.isLikelyHallucination(
            text: "Thank you.", minAvgLogProb: -1.6, nearSilence: false))
        // Whole-output phantom + near-silent audio ⇒ drop.
        s.expect(TranscriptSanity.isLikelyHallucination(
            text: "Thanks for watching!", minAvgLogProb: nil, nearSilence: true))
        // Confident, audible "Thank you." ⇒ DELIVERED (never eaten).
        s.expectFalse(TranscriptSanity.isLikelyHallucination(
            text: "Thank you.", minAvgLogProb: -0.2, nearSilence: false))
        // Phantom phrase inside a longer utterance ⇒ never matched.
        s.expectFalse(TranscriptSanity.isLikelyHallucination(
            text: "thank you for the report from yesterday", minAvgLogProb: -2.0, nearSilence: true))
        // No signals at all ⇒ fail-open.
        s.expectFalse(TranscriptSanity.isLikelyHallucination(
            text: "Thank you.", minAvgLogProb: nil, nearSilence: false))
    }

    s.test("settings decode tolerates old settings.json without the new key") { s in
        // Simulate a settings.json written by an older build: encode current
        // settings, delete the new key, and decode — must not throw or reset.
        var settings = AppSettings.default
        settings.historyRetentionLimit = 350
        let data = try JSONEncoder().encode(settings)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "spokenPunctuationEnabled")
        let oldData = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try? JSONDecoder().decode(AppSettings.self, from: oldData)
        s.expectNotNil(decoded, "old settings must still decode")
        s.expectEqual(decoded?.spokenPunctuationEnabled, false)
        s.expectEqual(decoded?.historyRetentionLimit, 350)
    }
}
