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

    s.test("settings migration strips legacy seeded code-mode rows, keeps user rules") { s in
        var old = AppSettings.default
        old.perAppBehaviors = [
            // Legacy seeded rows (old defaults) — must be removed.
            PerAppBehavior(bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude", defaultMode: .claudeCode),
            PerAppBehavior(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", defaultMode: .claudeCode),
            PerAppBehavior(bundleIdentifier: "com.apple.Notes", appName: "Notes", defaultMode: .cleanWriting),
            // Hand-flipped variant of a seeded row — also removed.
            PerAppBehavior(bundleIdentifier: "com.microsoft.VSCode", appName: "VS Code", defaultMode: .cleanWriting),
            // GENUINE user rules — must survive: custom app, custom mode, copy-only.
            PerAppBehavior(bundleIdentifier: "com.mycompany.tool", appName: "MyTool", defaultMode: .claudeCode),
            PerAppBehavior(bundleIdentifier: "com.apple.Safari", appName: "Safari", defaultMode: .cleanWriting, forceCopyOnly: true),
        ]
        let migrated = SettingsStore.migrate(old)
        let ids = migrated.perAppBehaviors.map(\.bundleIdentifier)
        s.expectEqual(ids.sorted(), ["com.apple.Safari", "com.mycompany.tool"])
        // Post-migration resolution is uniform: Terminal/Claude → Clean Writing.
        s.expectEqual(migrated.mode(forBundleIdentifier: "com.apple.Terminal"), .cleanWriting)
        s.expectEqual(migrated.mode(forBundleIdentifier: "com.anthropic.claudefordesktop"), .cleanWriting)
        s.expectEqual(migrated.mode(forBundleIdentifier: "com.mycompany.tool"), .claudeCode)
    }

    s.test("CleanupGuard: 1-char exemption is contraction-shards ONLY (Codex finding)") { s in
        // A bare invented "I"/"a" must be rejected — the shard exemption applies
        // only to letters that literally follow an apostrophe in the cleaned text.
        s.expectFalse(CleanupGuard.preservesMeaning(original: "go now", cleaned: "I go now"))
        s.expectFalse(CleanupGuard.preservesMeaning(original: "send report", cleaned: "send a report"))
        // Real contraction shards still pass, straight or curly apostrophe.
        s.expect(CleanupGuard.preservesMeaning(original: "do not touch it", cleaned: "Don't touch it."))
        s.expect(CleanupGuard.preservesMeaning(original: "it is fine", cleaned: "It\u{2019}s fine."))
    }

    s.test("CleanupGuard rejects invented numbers (both directions exact)") { s in
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "send the report", cleaned: "send the 2 reports"))
        s.expect(CleanupGuard.preservesMeaning(
            original: "review version 3.14 now", cleaned: "Review version 3.14 now."))
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
    // MARK: - Grammar repair (Yoni, 2026-08-18): fix HOW he said it, never WHAT

    s.test("grammar repair: a non-native speaker's real errors are fixed") { s in
        let p = CleanupGuard.Policy.grammarRepair
        // Irregular verbs — the commonest non-native error, and invisible to a
        // stem check ("go"/"went" share no letters).
        s.expect(CleanupGuard.preservesMeaning(
            original: "he go to the store yesterday",
            cleaned: "he went to the store yesterday", policy: p))
        // Missing article + preposition + agreement, all at once.
        s.expect(CleanupGuard.preservesMeaning(
            original: "I am interesting for discuss this",
            cleaned: "I am interested in discussing this", policy: p))
        s.expect(CleanupGuard.preservesMeaning(
            original: "he go store yesterday",
            cleaned: "he went to the store yesterday", policy: p))
        // Auxiliary tense fix.
        s.expect(CleanupGuard.preservesMeaning(
            original: "the tests is passing now",
            cleaned: "the tests are passing now", policy: p))
    }

    s.test("grammar repair: WHAT he said is still locked down") { s in
        let p = CleanupGuard.Policy.grammarRepair
        // Content words may never be invented...
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "send the file", cleaned: "send the invoice file", policy: p))
        // ...nor dropped.
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "cancel the Tuesday meeting", cleaned: "cancel the meeting", policy: p))
        // Negation stays absolute — the flip that changes everything.
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "do not delete it", cleaned: "do delete it", policy: p))
        // Numbers stay exact.
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "transfer 300 dollars", cleaned: "transfer 3000 dollars", policy: p))
        // Names are content, not structure.
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "ask Sarah about it", cleaned: "ask Michael about it", policy: p))
    }

    s.test("grammar repair: the 'Thank' → 'Thank you.' defect stays impossible") { s in
        // The 2026-08-08 live defect. "you" is a function word, so a naive
        // closed-class rule would wave it through; the length-scaled insertion
        // budget gives a very short utterance NO room to grow.
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "Thank", cleaned: "Thank you.", policy: .grammarRepair))
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "Yes", cleaned: "Yes, I will do it.", policy: .grammarRepair))
        s.expectEqual(CleanupGuard.insertionBudget(originalWordCount: 3), 0)
        s.expect(CleanupGuard.insertionBudget(originalWordCount: 10) >= 1)
    }

    s.test("grammar repair: verbatim policy is unchanged for anyone who keeps it") { s in
        // The founding behaviour must survive intact behind the setting.
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "he go to the store yesterday",
            cleaned: "he went to the store yesterday", policy: .verbatim))
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "he go store", cleaned: "he go to the store", policy: .verbatim))
    }

}
