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
}
