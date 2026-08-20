import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

/// Property testing: instead of checking examples a human thought of, generate
/// tens of thousands of edits and assert the RULES that must hold for all of
/// them. Every hand-written test in this suite encodes what its author already
/// suspected — which is exactly why the reviewer found four Criticals that the
/// suite was green on. This finds the cases nobody imagined.
func runFuzzTests(_ s: TestSuite) {

    // A deterministic generator: a failing seed is reproducible, so a fuzz
    // failure becomes a normal bug report instead of a ghost.
    struct Rand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
        mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
    }

    let vocabulary = [
        "the", "a", "we", "he", "she", "they", "i", "you", "it",
        "need", "needs", "needed", "want", "wants", "send", "sent", "call",
        "well", "wall", "deck", "beam", "tile", "crew", "client", "invoice",
        "before", "after", "until", "because", "and", "but", "so", "not",
        "three", "seven", "fifteen", "monday", "friday", "garage", "kitchen",
        "is", "are", "was", "were", "will", "would", "can", "might", "must",
        "to", "from", "over", "under", "with", "for", "on", "in", "at",
    ]
    let contentWords = Set(["need", "needs", "needed", "want", "wants", "send",
                            "sent", "call", "well", "wall", "deck", "beam",
                            "tile", "crew", "client", "invoice", "garage",
                            "kitchen", "monday", "friday"])

    s.test("fuzz: the guard never lets a CONTENT word vanish (20k edits)") { s in
        var rng = Rand(state: 0x5EED_1234)
        var checked = 0
        for _ in 0..<20_000 {
            let n = 4 + rng.int(9)
            var words = (0..<n).map { _ in rng.pick(vocabulary) }
            // Delete one content word — the edit the whole product forbids.
            let victims = words.indices.filter { contentWords.contains(words[$0]) }
            guard let victim = victims.isEmpty ? nil : victims[rng.int(victims.count)] else { continue }
            let dropped = words.remove(at: victim)
            let original = words.isEmpty ? "" : ""
            _ = original
            var rebuilt = (0..<n).map { _ in "" }
            _ = rebuilt
            rebuilt = []
            let before = ({ () -> [String] in
                var copy = words; copy.insert(dropped, at: victim); return copy
            })().joined(separator: " ")
            let after = words.joined(separator: " ")
            // Another copy of the same word elsewhere makes the deletion
            // invisible by design (bag-of-words), so skip those.
            if words.contains(dropped) { continue }
            checked += 1
            for policy in [CleanupGuard.Policy.verbatim, .grammarRepair] {
                s.expectFalse(
                    CleanupGuard.preservesMeaning(original: before, cleaned: after, policy: policy),
                    "content word \"\(dropped)\" vanished unnoticed [\(policy)]: \"\(before)\" -> \"\(after)\"")
            }
        }
        s.expect(checked > 5_000, "only \(checked) usable cases generated — the fuzzer is not exercising much")
    }

    s.test("fuzz: the guard never invents a content word (20k edits)") { s in
        var rng = Rand(state: 0xC0FFEE_99)
        for _ in 0..<20_000 {
            let n = 4 + rng.int(9)
            var words = (0..<n).map { _ in rng.pick(vocabulary) }
            let before = words.joined(separator: " ")
            let intruder = rng.pick(Array(contentWords))
            guard !words.contains(intruder) else { continue }
            words.insert(intruder, at: rng.int(words.count + 1))
            let after = words.joined(separator: " ")
            for policy in [CleanupGuard.Policy.verbatim, .grammarRepair] {
                s.expectFalse(
                    CleanupGuard.preservesMeaning(original: before, cleaned: after, policy: policy),
                    "invented \"\(intruder)\" [\(policy)]: \"\(before)\" -> \"\(after)\"")
            }
        }
    }

    s.test("fuzz: identical text is always accepted, and never crashes") { s in
        // Reflexivity. Trivial to state, and the kind of thing that breaks when
        // a rule is added — the clause rule nearly did exactly this.
        var rng = Rand(state: 0xABCD_4321)
        for _ in 0..<20_000 {
            let n = 1 + rng.int(14)
            let words = (0..<n).map { _ in rng.pick(vocabulary) }
            var text = words.joined(separator: " ")
            // Sprinkle punctuation, the part every rule keeps getting wrong.
            if rng.int(3) == 0 { text += "." }
            if rng.int(4) == 0 { text = text.replacingOccurrences(of: " ", with: ", ") }
            if rng.int(5) == 0 { text += "?" }
            for policy in [CleanupGuard.Policy.verbatim, .grammarRepair] {
                s.expect(CleanupGuard.preservesMeaning(original: text, cleaned: text, policy: policy),
                         "rejected IDENTICAL text [\(policy)]: \"\(text)\"")
            }
        }
    }

    s.test("fuzz: the verdict and its reason never disagree (20k edits)") { s in
        // `preservesMeaning` is defined as `rejection == nil`. An audit that
        // reported a different answer than the guard took would be worse than
        // no audit, so prove the two can never come apart.
        var rng = Rand(state: 0x1357_9BDF)
        for _ in 0..<20_000 {
            let n = 3 + rng.int(10)
            var words = (0..<n).map { _ in rng.pick(vocabulary) }
            switch rng.int(4) {
            case 0: if !words.isEmpty { words.remove(at: rng.int(words.count)) }
            case 1: words.insert(rng.pick(vocabulary), at: rng.int(words.count + 1))
            case 2: if words.count > 1 { words.swapAt(rng.int(words.count), rng.int(words.count)) }
            default: if !words.isEmpty { words[rng.int(words.count)] = rng.pick(vocabulary) }
            }
            let before = (0..<n).map { _ in rng.pick(vocabulary) }.joined(separator: " ")
            let after = words.joined(separator: " ")
            for policy in [CleanupGuard.Policy.verbatim, .grammarRepair] {
                let ok = CleanupGuard.preservesMeaning(original: before, cleaned: after, policy: policy)
                let reason = CleanupGuard.rejection(original: before, cleaned: after, policy: policy)
                s.expectEqual(ok, reason == nil,
                              "verdict and reason disagree [\(policy)]: \"\(before)\" -> \"\(after)\"")
            }
        }
    }
}

/// The app noticing its own mishearings (2026-08-19).
func runDoubtTests(_ s: TestSuite) {

    s.test("doubt: two engines disagreeing localises the actual error") { s in
        // The real case, from his audio tonight. The small model heard "wrench",
        // the large one "rent" — and the disagreement is precisely the error,
        // even though nothing here knows which side is right.
        let doubt = TranscriptDoubt.assess(
            text: "I wonder if we have any friends who would want to wrench it out for the year",
            confidence: nil,
            secondOpinion: "I wonder if we have any friends who would want to rent it out for the year")
        s.expectEqual(doubt.spans.count, 1)
        s.expectEqual(doubt.spans.first?.text, "wrench")
        s.expectEqual(doubt.spans.first?.alternative, "rent")
        s.expectEqual(doubt.spans.first?.kind, .enginesDisagree)
    }

    s.test("doubt: a dropped word is localised, not smeared across the sentence") { s in
        // His other real error: "or all the words" delivered as "all the words".
        // An alignment that shifted would flag the whole tail and be useless.
        let doubt = TranscriptDoubt.assess(
            text: "what do we do with the missing words all the words I never said",
            confidence: nil,
            secondOpinion: "what do we do with the missing words or all the words I never said")
        s.expectEqual(doubt.spans.count, 1)
        s.expectEqual(doubt.spans.first?.alternative, "or")
    }

    s.test("doubt: agreement is silent") { s in
        // Both engines wrong the same way is invisible by construction, and a
        // detector that cried wolf on every dictation would be ignored.
        let same = "the crew finished the deck today and went home early"
        s.expect(TranscriptDoubt.assess(text: same, confidence: 0.9, secondOpinion: same).isEmpty)
        s.expect(TranscriptDoubt.assess(text: same, confidence: nil, secondOpinion: nil).isEmpty)
    }

    s.test("doubt: low confidence flags the utterance only when nothing better exists") { s in
        let text = "we need to dig a new well behind the garage"
        let vague = TranscriptDoubt.assess(text: text, confidence: 0.2, secondOpinion: nil)
        s.expectEqual(vague.spans.first?.kind, .lowConfidence)
        // A specific disagreement outranks a vague one — naming the word beats
        // telling him something somewhere is wrong.
        let precise = TranscriptDoubt.assess(
            text: text, confidence: 0.2,
            secondOpinion: "we need to dig a new wall behind the garage")
        s.expectEqual(precise.spans.first?.kind, .enginesDisagree)
        s.expectFalse(precise.spans.contains { $0.kind == .lowConfidence })
    }

    s.test("doubt: confident dictations are never flagged") { s in
        let text = "send the change order to the client before friday"
        s.expect(TranscriptDoubt.assess(text: text, confidence: 0.95, secondOpinion: text).isEmpty)
    }
}

/// Trimming the dead air before he starts speaking (2026-08-19).
func runLeadingSilenceTests(_ s: TestSuite) {
    let rate = 16_000.0
    func silence(_ seconds: Double, level: Float = 0.0008) -> [Float] {
        (0..<Int(rate * seconds)).map { i in level * (i % 7 == 0 ? 1 : -1) }
    }
    func speech(_ seconds: Double, level: Float = 0.18) -> [Float] {
        (0..<Int(rate * seconds)).map { i in
            level * Float(sin(Double(i) * 0.07)) * (i % 1000 < 700 ? 1 : 0.3)
        }
    }

    s.test("silence: the dead air in front of his speech is removed") { s in
        // His real recordings carried 1.6-2.7s of it, and it cost five words and
        // invented a "Thank you" on the first A/B sentence.
        let clip = silence(2.5) + speech(3)
        let out = LeadingSilence.trimmed(clip, sampleRate: rate)
        let removed = Double(clip.count - out.count) / rate
        s.expect(removed > 2.0 && removed < 2.4,
                 "removed \(removed)s — should be the silence minus the 0.2s lead-in")
    }

    s.test("silence: a lead-in is always kept so a soft first word survives") { s in
        let clip = silence(2.0) + speech(2)
        let out = LeadingSilence.trimmed(clip, sampleRate: rate)
        let kept = Double(out.count) / rate - 2.0
        s.expect(kept >= 0.15, "kept only \(kept)s before speech — a quiet 'Ask' would be clipped")
    }

    s.test("silence: quiet speech is not mistaken for silence") { s in
        // He records at a fifth of typical level. A fixed threshold tuned on
        // loud audio would eat his words outright.
        let clip = silence(1.5, level: 0.0005) + speech(2, level: 0.04)
        let out = LeadingSilence.trimmed(clip, sampleRate: rate)
        s.expect(Double(out.count) / rate > 2.0, "quiet speech was cut off")
    }

    s.test("silence: nothing is removed when there is nothing to remove") { s in
        let straightIn = speech(3)
        s.expectEqual(LeadingSilence.trimmed(straightIn, sampleRate: rate).count, straightIn.count)
        // An all-silence clip is returned WHOLE — judging a clip empty belongs
        // to the phantom filter, which has an arbiter behind it.
        let quiet = silence(3)
        s.expectEqual(LeadingSilence.trimmed(quiet, sampleRate: rate).count, quiet.count)
        // And a tiny gap is not worth cutting.
        let short = silence(0.25) + speech(2)
        s.expectEqual(LeadingSilence.trimmed(short, sampleRate: rate).count, short.count)
    }

    s.test("silence: the dead air AFTER he stops is removed too") { s in
        // LIVE, 2026-08-20: one second of trailing silence on a 32-second
        // dictation made Whisper append "Thank you." — on the very dictation
        // where he was telling me the app invents words. Removing the second
        // removed the phantom.
        let clip = speech(3) + silence(1.5)
        let out = LeadingSilence.trimmed(clip, sampleRate: rate)
        let removed = Double(clip.count - out.count) / rate
        s.expect(removed > 1.0 && removed < 1.4,
                 "removed \(removed)s — should be the tail minus the 0.3s lead-out")
    }

    s.test("silence: a lead-out is kept so a trailing consonant survives") { s in
        let clip = speech(2) + silence(2)
        let out = LeadingSilence.trimmed(clip, sampleRate: rate)
        let kept = Double(out.count) / rate - 2.0
        s.expect(kept >= 0.25, "kept only \(kept)s after speech — a final 't' would be clipped")
    }

    s.test("silence: audio is never removed from the middle") { s in
        // A pause mid-sentence is speech, not dead air, and the end is where a
        // trailing word lives.
        // A pause mid-sentence is speech, not dead air.
        let clip = silence(1.5) + speech(1) + silence(1.2) + speech(1.5)
        let out = LeadingSilence.trimmed(clip, sampleRate: rate)
        let expected = clip.count - (Int(rate * 1.5) - Int(rate * LeadingSilence.leadInSeconds))
        s.expectEqual(out.count, expected)
        s.expectEqual(Array(out.suffix(100)), Array(clip.suffix(100)))
    }
}

/// His own confusions, learned from his own corrections (2026-08-20).
func runPersonalConfusionTests(_ s: TestSuite) {
    typealias Rule = PersonalConfusions.Rule

    s.test("confusions: a correction is mined down to the phrase that changed") { s in
        // His real error. The rule must be "a new well" -> "and you walk"
        // reversed, NOT the whole sentence — memorising sentences makes the
        // table useless on anything he has not said verbatim before.
        let found = PersonalConfusions.confusions(
            heard: "we need to dig and you walk behind the garage",
            said:  "we need to dig a new well behind the garage")
        s.expectEqual(found.count, 1)
        s.expectEqual(found.first?.heard, "and you walk")
        s.expectEqual(found.first?.said, "a new well")
    }

    s.test("confusions: a missing or extra word is NOT learned as a confusion") { s in
        // "or all the words" -> "all the words" is a DELETION by the recogniser.
        // Turning that into a lookup rule would make the table insert "or"
        // wherever those words appear — inventing a word he did not say.
        s.expect(PersonalConfusions.confusions(
            heard: "all the words I never said",
            said:  "or all the words I never said").isEmpty)
        s.expect(PersonalConfusions.confusions(
            heard: "the framing is okay thank you",
            said:  "the framing is okay").isEmpty)
    }

    s.test("confusions: one sighting is a coincidence, two is a pattern") { s in
        let once = PersonalConfusions(rules: [Rule(heard: "wrench", said: "rented")])
        s.expectEqual(once.apply(to: "we want to wrench it out").text, "we want to wrench it out")
        var rules = [Rule]()
        rules = PersonalConfusions.learning(rules, heard: "wrench", said: "rented")
        rules = PersonalConfusions.learning(rules, heard: "wrench", said: "rented")
        s.expectEqual(rules.count, 1)
        s.expectEqual(rules.first?.sightings, 2)
        s.expectEqual(PersonalConfusions(rules: rules).apply(to: "we want to wrench it out").text,
                      "we want to rented it out")
    }

    s.test("confusions: only whole words, and every change is reported") { s in
        let rules = [Rule(heard: "cloud code", said: "Claude Code", sightings: 3)]
        let table = PersonalConfusions(rules: rules)
        let hit = table.apply(to: "Cloud Code should handle the migration")
        s.expectEqual(hit.text, "Claude Code should handle the migration")
        s.expectEqual(hit.corrections.count, 1)
        // A word that merely CONTAINS the phrase is untouched: substring
        // matching here would rewrite words he really said.
        let miss = table.apply(to: "the cloudcodes are fine")
        s.expectEqual(miss.text, "the cloudcodes are fine")
        s.expect(miss.isEmpty)
    }

    s.test("confusions: the longest match wins") { s in
        // "a new well" must beat a rule for "well" alone, or the specific fix is
        // shadowed by the general one.
        let table = PersonalConfusions(rules: [
            Rule(heard: "walk", said: "well", sightings: 2),
            Rule(heard: "and you walk", said: "a new well", sightings: 2),
        ])
        s.expectEqual(table.apply(to: "dig and you walk behind the garage").text,
                      "dig a new well behind the garage")
    }

    s.test("confusions: an empty table never touches his words") { s in
        let text = "Ask Codex to verify the branch before we merge it to main"
        let table = PersonalConfusions(rules: [])
        s.expectEqual(table.apply(to: text).text, text)
        s.expect(table.apply(to: text).isEmpty)
    }
}
