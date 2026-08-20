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
