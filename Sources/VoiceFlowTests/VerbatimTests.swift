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
        // NOTE (2026-08-18): this used to also swap "for"→"in", which passed only
        // by accident — "in" is a prefix of "interesting", and "for" is too short
        // for the deletion check. Preposition swaps are now rejected under BOTH
        // policies (Codex: "you owe me" → "you owe you"), so the test asserts what
        // it always meant to: stem variants are fine.
        s.expect(CleanupGuard.preservesMeaning(
            original: "i am interesting for discuss the plan",
            cleaned: "I am interested for discussing the plan."))
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
        // Partial repair, deliberately: "interesting"→"interested" and
        // "discuss"→"discussing" land, but "for"→"in" does NOT, because allowing
        // preposition swaps is what let "to Bob" become "from Bob".
        s.expect(CleanupGuard.preservesMeaning(
            original: "I am interesting for discuss this",
            cleaned: "I am interested for discussing this", policy: p))
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

    // MARK: - Per-sentence reconciliation (one bad clause ≠ lose every repair)

    s.test("merge: a safe sentence is kept even when another sentence oversteps") { s in
        // The live pattern: the model fixes several things, oversteps in ONE
        // clause, and all-or-nothing rejection threw away the good repairs too.
        let original = "he go to the store yesterday. Send the file."
        let cleaned  = "He went to the store yesterday. Send the invoice file."
        let merged = CleanupGuard.safelyMerged(
            original: original, cleaned: cleaned, policy: .grammarRepair)
        s.expect(merged.contains("He went to the store yesterday."),
                 "the safe repair was discarded: \(merged)")
        s.expectFalse(merged.contains("invoice"),
                      "an invented content word survived: \(merged)")
    }

    s.test("merge: a wholly safe edit passes through untouched") { s in
        let merged = CleanupGuard.safelyMerged(
            original: "he go to the store. i am interesting for discuss",
            cleaned: "He went to the store. I am interested for discussing",
            policy: .grammarRepair)
        s.expectEqual(merged, "He went to the store. I am interested for discussing")
    }

    s.test("merge: when every sentence oversteps, nothing is delivered from it") { s in
        let original = "send the file. cancel the Tuesday meeting."
        let merged = CleanupGuard.safelyMerged(
            original: original,
            cleaned: "Send the invoice file. Cancel the meeting.",
            policy: .grammarRepair)
        s.expectEqual(merged, original, "unsafe text was delivered")
    }

    s.test("merge: unalignable sentence counts fall back to all-or-nothing") { s in
        // The model merged two sentences into one — we cannot tell which repair
        // belongs where, so no partial credit is given.
        let original = "he go home. he sleep."
        let merged = CleanupGuard.safelyMerged(
            original: original, cleaned: "He went home and slept.", policy: .grammarRepair)
        s.expectEqual(merged, original)
    }

    // MARK: - The meaning-change scenarios a review proved were accepted

    s.test("grammar repair: relational words can never be SWAPPED") { s in
        let p = CleanupGuard.Policy.grammarRepair
        // Every one of these was ACCEPTED by the first implementation. For a
        // contractor dictating about money and schedules, each is a real-world
        // harm, not a theoretical one.
        let forbidden: [(String, String)] = [
            ("transfer the deposit to Bob today please", "transfer the deposit from Bob today please"),
            ("call me before the meeting on Monday", "call me after the meeting on Monday"),
            ("keep the budget under 50 thousand for this", "keep the budget over 50 thousand for this"),
            ("I got the quote for the supplier today", "I got the quote from the supplier today"),
            ("I might send the payment tomorrow", "I will send the payment tomorrow"),
            ("I can do it tomorrow myself", "I must do it tomorrow myself"),
            ("we should review the contract before signing", "we must review the contract before signing"),
            ("I will pay the contractor tomorrow", "You will pay the contractor tomorrow"),
            ("he told me the price was fine yesterday", "she told me the price was fine yesterday"),
        ]
        for (original, cleaned) in forbidden {
            s.expectFalse(CleanupGuard.preservesMeaning(original: original, cleaned: cleaned, policy: p),
                          "meaning changed: \(original) → \(cleaned)")
        }
    }

    s.test("grammar repair: a finished job cannot become a promise") { s in
        let p = CleanupGuard.Policy.grammarRepair
        // Irregular-verb equivalence plus a free auxiliary drop turned "I HAVE
        // SENT" into "I WILL SEND". Tense markers must be intact before verb
        // forms are treated as equivalent.
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "I have sent the report to the client",
            cleaned: "I will send the report to the client", policy: p))
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "I will send the invoice tomorrow",
            cleaned: "I sent the invoice tomorrow", policy: p))
    }

    s.test("grammar repair: agreement is still fixed, time is not moved") { s in
        let p = CleanupGuard.Policy.grammarRepair
        // Agreement carries no new information, so it stays allowed…
        s.expect(CleanupGuard.preservesMeaning(
            original: "the tests is passing now", cleaned: "the tests are passing now", policy: p))
        // …while the same auxiliaries moving through time do not.
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "the tests is passing now", cleaned: "the tests was passing now", policy: p))
    }

    s.test("grammar repair: a contractor's homographs are not verbs") { s in
        let p = CleanupGuard.Policy.grammarRepair
        // "saw", "left", "felt" are tools, directions and materials in his work.
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "we need the saw for the deck", cleaned: "we need to see for the deck", policy: p))
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "the panel is on the left side", cleaned: "the panel is on the leave side", policy: p))
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "bring the felt for the table", cleaned: "bring the feel for the table", policy: p))
    }

    s.test("grammar repair: reordering pronouns cannot flip who owes whom") { s in
        let p = CleanupGuard.Policy.grammarRepair
        // Codex round-1 FAIL. Identical words, identical counts — only the ORDER
        // changed, and the set-based check saw nothing. Debt reversed.
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "you owe me and I owe you",
            cleaned: "you owe you and I owe me", policy: p))
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "I send the invoice to you and you send the deposit to me",
            cleaned: "you send the invoice to me and I send the deposit to you", policy: p))
        // The same must hold under plain verbatim.
        s.expectFalse(CleanupGuard.preservesMeaning(
            original: "you owe me and I owe you",
            cleaned: "you owe you and I owe me", policy: .verbatim))
    }

}
