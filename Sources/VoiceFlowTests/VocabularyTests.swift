import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

func runVocabularyTests(_ s: TestSuite) {
    let vocab = VocabularyEntry.defaults

    s.test("Vocabulary replaces single term case-insensitively") { s in
        let r = VocabularyReplacer(entries: vocab)
        s.expectEqual(r.apply(to: "i use postgres daily"), "i use PostgreSQL daily")
    }

    s.test("Vocabulary prefers longer phrase over shorter") { s in
        let entries = [
            VocabularyEntry(spoken: "next", written: "NEXT"),
            VocabularyEntry(spoken: "next js", written: "Next.js")
        ]
        let r = VocabularyReplacer(entries: entries)
        s.expectEqual(r.apply(to: "the next js app"), "the Next.js app")
    }

    s.test("Vocabulary respects word boundaries") { s in
        let r = VocabularyReplacer(entries: [VocabularyEntry(spoken: "codex", written: "Codex")])
        // Should not touch "codexes"
        s.expectEqual(r.apply(to: "codexes and codex"), "codexes and Codex")
    }

    s.test("Vocabulary handles multi-word with flexible whitespace") { s in
        let r = VocabularyReplacer(entries: [VocabularyEntry(spoken: "claude code", written: "Claude Code")])
        s.expectEqual(r.apply(to: "open claude   code now"), "open Claude Code now")
    }

    s.test("Disabled vocabulary entry is ignored") { s in
        let r = VocabularyReplacer(entries: [VocabularyEntry(spoken: "codex", written: "Codex", isEnabled: false)])
        s.expectEqual(r.apply(to: "use codex"), "use codex")
    }

    s.test("Case-sensitive entry only matches exact case") { s in
        let r = VocabularyReplacer(entries: [VocabularyEntry(spoken: "IOS", written: "iOS", caseSensitive: true)])
        s.expectEqual(r.apply(to: "IOS and ios"), "iOS and ios")
    }

    s.test("Vocabulary written form with regex-special chars is literal") { s in
        let r = VocabularyReplacer(entries: [VocabularyEntry(spoken: "dollar", written: "$1")])
        s.expectEqual(r.apply(to: "the dollar amount"), "the $1 amount")
    }
    // MARK: - Phonetic near-miss detection (2026-08-19)

    s.test("phonetic: finds the mishearings he had to hand-list, as SUGGESTIONS") { s in
        // His live vocabulary had grown hand-written mishearings — codices,
        // codecs, codeex → Codex; get hub, git hop → GitHub; clod code, closed
        // code → Claude Code. Making a user enumerate every way a recogniser can
        // mangle a word IS the defect: he can only add the ones that already
        // burned him.
        //
        // But these are found and PROPOSED, never substituted. "codecs" and
        // "codices" are real English words: no rule can distinguish "he said
        // codecs" from "Codex was misheard as codecs" — only context can, which
        // is why the real fix lives at the recogniser (context biasing). A
        // false suggestion costs one dismissal; a false substitution destroys a
        // word he actually said, and that is the failure this product refuses.
        let entries = [
            VocabularyEntry(spoken: "codex", written: "Codex"),
            VocabularyEntry(spoken: "github", written: "GitHub"),
            VocabularyEntry(spoken: "claude code", written: "Claude Code"),
        ]
        let detector = PhoneticVocabulary(entries: entries)
        for (heard, term, want) in [("ask codices to verify", "codices", "Codex"),
                                    ("ask codecs to verify", "codecs", "Codex"),
                                    ("push it to get hub", "get hub", "GitHub"),
                                    ("push it to git hop", "git hop", "GitHub"),
                                    ("open clod code now", "clod code", "Claude Code"),
                                    ("open closed code now", "closed code", "Claude Code")] {
            let found = detector.nearMisses(in: heard)
            s.expect(found.contains { $0.heard == term && $0.written == want },
                     "expected \(term) → \(want) from \"\(heard)\", got: \(found)")
        }
    }

    s.test("phonetic: ordinary speech produces no suggestions") { s in
        // Suggestions are cheap but not free — a detector that fires on every
        // sentence trains the user to ignore it, which is how the previous
        // learning system became useless.
        let detector = PhoneticVocabulary(entries: [
            VocabularyEntry(spoken: "codex", written: "Codex"),
            VocabularyEntry(spoken: "github", written: "GitHub"),
        ])
        for quiet in ["we need a permit for the deck before monday",
                      "the cabinet doors arrived this morning",
                      "tell the client the tile is on backorder",
                      "he wrote the code today"] {
            s.expectEqual(detector.nearMisses(in: quiet).count, 0, "fired on: \(quiet)")
        }
    }

    s.test("phonetic: a term already correct is not proposed") { s in
        let detector = PhoneticVocabulary(entries: [VocabularyEntry(spoken: "codex", written: "Codex")])
        s.expectEqual(detector.nearMisses(in: "Codex verified it").count, 0)
        s.expectEqual(detector.nearMisses(in: "codex verified it").count, 0)
    }

}
