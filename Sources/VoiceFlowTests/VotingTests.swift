import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

/// Phase 5 — word-level dual-engine voting. The rule that outranks accuracy:
/// the merged text may only contain words one of the two engines produced.
func runVotingTests(_ suite: TestSuite) {
    let vocabulary = ["Sarah", "Kubernetes", "Payload CMS", "Grafana"]

    suite.test("voting: the secondary's vocabulary-correct word wins") { s in
        let result = DualEngineVoting.reconcile(
            primary: "I told Sara about the cluster",
            secondary: "I told Sarah about the cluster",
            vocabulary: vocabulary)
        s.expectEqual(result.text, "I told Sarah about the cluster")
        s.expectEqual(result.substitutions.count, 1)
    }

    suite.test("voting: disagreement on an ordinary word keeps the primary engine") { s in
        let result = DualEngineVoting.reconcile(
            primary: "I think it worked fine",
            secondary: "I thought it worked fine",
            vocabulary: vocabulary)
        s.expectEqual(result.text, "I think it worked fine")
        s.expectFalse(result.changedAnything)
    }

    suite.test("voting: never invents a word neither engine produced") { s in
        let primary = "we deploy cuber netties daily"
        let secondary = "we deploy Kubernetes today daily"
        let result = DualEngineVoting.reconcile(primary: primary, secondary: secondary, vocabulary: vocabulary)
        // Compare WORD CORES, not raw tokens: the swap deliberately carries the
        // primary's punctuation across ("Sara." + "Sarah" → "Sarah."), so a raw
        // token comparison asserts something stronger than the design promises
        // and passes only by luck of the chosen inputs.
        let core = { (w: Substring) in
            String(w.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let produced = Set(result.text.split(separator: " ").map(core))
        let allowed = Set((primary + " " + secondary).split(separator: " ").map(core))
        for word in produced {
            s.expect(allowed.contains(word), "invented word: \(word)")
        }
    }

    suite.test("voting: a punctuation-only word is not wrapped around the replacement") { s in
        // Regression: when the primary's word has no letters or digits at all, the
        // affix logic captured the WHOLE token as both prefix and suffix, emitting
        // "—Sarah—" — a token neither engine produced.
        let result = DualEngineVoting.reconcile(
            primary: "hi — today", secondary: "hi Sarah today", vocabulary: vocabulary)
        s.expectEqual(result.text, "hi Sarah today")
    }

    suite.test("voting: engines that heard different structure are not merged") { s in
        // Different word counts mean a positional merge would be guesswork.
        let result = DualEngineVoting.reconcile(
            primary: "tell Sara now",
            secondary: "please tell Sarah right now",
            vocabulary: vocabulary)
        s.expectEqual(result.text, "tell Sara now")
        s.expectFalse(result.changedAnything)
    }

    suite.test("voting: with no vocabulary there is nothing to vote about") { s in
        let result = DualEngineVoting.reconcile(
            primary: "I told Sara today", secondary: "I told Sarah today", vocabulary: [])
        s.expectEqual(result.text, "I told Sara today")
    }

    suite.test("voting: a vocabulary word the primary already has is never overridden") { s in
        let result = DualEngineVoting.reconcile(
            primary: "deploy Kubernetes now",
            secondary: "deploy Grafana now",
            vocabulary: vocabulary)
        s.expectEqual(result.text, "deploy Kubernetes now")
    }

    suite.test("voting: the primary's punctuation survives the swap") { s in
        let result = DualEngineVoting.reconcile(
            primary: "thanks, Sara.", secondary: "thanks, Sarah", vocabulary: vocabulary)
        s.expectEqual(result.text, "thanks, Sarah.")
    }

    // MARK: - When a second opinion is worth its latency

    suite.test("near-miss: a one-character miss of a vocabulary term triggers a second opinion") { s in
        s.expect(DualEngineVoting.containsNearMiss(text: "I told Sara today", vocabulary: vocabulary))
        s.expect(DualEngineVoting.containsNearMiss(text: "we run Grafanna", vocabulary: vocabulary))
    }

    suite.test("near-miss: ordinary speech never pays for a second engine") { s in
        s.expectFalse(DualEngineVoting.containsNearMiss(
            text: "let us meet at the office tomorrow", vocabulary: vocabulary))
        s.expectFalse(DualEngineVoting.containsNearMiss(text: "anything", vocabulary: []))
        s.expectFalse(DualEngineVoting.containsNearMiss(text: "", vocabulary: vocabulary))
    }

    suite.test("near-miss: an exactly-correct term is not a near miss") { s in
        s.expectFalse(DualEngineVoting.containsNearMiss(text: "I told Sarah today", vocabulary: vocabulary))
    }

    suite.test("near-miss: low decoder confidence widens the net to two edits") { s in
        // "Grafanah" is two edits from "Grafana": ignored normally, caught when
        // the decoder itself was unsure.
        s.expectFalse(DualEngineVoting.containsNearMiss(text: "we run Graffanah", vocabulary: vocabulary))
        s.expect(DualEngineVoting.containsNearMiss(text: "we run Graffanah", vocabulary: vocabulary, maxEdits: 2))
    }

    suite.test("near-miss: short vocabulary terms don't trigger on unrelated words") { s in
        // Terms under 4 characters are excluded — too many false neighbours.
        s.expectFalse(DualEngineVoting.containsNearMiss(text: "the cat sat", vocabulary: ["cap", "bat"]))
    }
}
