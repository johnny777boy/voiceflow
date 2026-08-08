import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

/// Phase 4 — the learning dictionary. The product rule is *propose, never
/// mutate*, so these tests care as much about what is NOT learned as what is.
func runLearningTests(_ suite: TestSuite) {

    // MARK: - Detection

    suite.test("correction: a single misheard word is detected") { s in
        let correction = CorrectionDetector.detect(
            inserted: "I sent it to Sara this morning",
            final: "I sent it to Sarah this morning")
        s.expectEqual(correction, WordCorrection(heard: "Sara", corrected: "Sarah"))
    }

    suite.test("correction: real editing is never mistaken for a word fix") { s in
        // Two changes, added words, removed words, wholesale rewrite.
        s.expectNil(CorrectionDetector.detect(
            inserted: "I sent it to Sara this morning",
            final: "I mailed it to Sarah this morning"))
        s.expectNil(CorrectionDetector.detect(
            inserted: "I sent it to Sara",
            final: "I sent it to Sara this morning"))
        s.expectNil(CorrectionDetector.detect(
            inserted: "I sent it to Sara this morning",
            final: "I sent it"))
        s.expectNil(CorrectionDetector.detect(
            inserted: "I sent it to Sara",
            final: "completely different text here"))
    }

    suite.test("correction: case, punctuation and number changes are not vocabulary") { s in
        s.expectNil(CorrectionDetector.detect(inserted: "call sarah now", final: "call Sarah now"))
        s.expectNil(CorrectionDetector.detect(inserted: "call Sarah now", final: "call Sarah, now"))
        s.expectNil(CorrectionDetector.detect(inserted: "meet at 6 today", final: "meet at 7 today"))
        s.expectNil(CorrectionDetector.detect(inserted: "", final: ""))
    }

    suite.test("correction: only words we inserted count as recognizer errors") { s in
        s.expect(CorrectionDetector.containsWord("Sara", in: "I sent it to Sara."))
        s.expect(CorrectionDetector.containsWord("sara", in: "I sent it to Sara,"))
        s.expectFalse(CorrectionDetector.containsWord("Sara", in: "I sent it to Bob."))
        s.expectFalse(CorrectionDetector.containsWord("", in: "anything"))
    }

    suite.test("correction: an untouched field is not an edit") { s in
        s.expectFalse(CorrectionDetector.textWasEdited(inserted: "hello there", final: "hello there"))
        s.expectFalse(CorrectionDetector.textWasEdited(inserted: "hello there", final: " hello there\n"))
        s.expect(CorrectionDetector.textWasEdited(inserted: "hello there", final: "hello friend"))
    }

    // MARK: - Suggestion store

    func makeStore() -> (SuggestedVocabularyStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-suggestions-\(UUID().uuidString).json")
        return (SuggestedVocabularyStore(url: url), url)
    }

    suite.test("suggestions: nothing is offered until the correction recurs three times") { s in
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let correction = WordCorrection(heard: "Sara", corrected: "Sarah")
        s.expectNil(store.record(correction))
        s.expect(store.readySuggestions().isEmpty, "offered after one sighting")
        s.expectNil(store.record(correction))
        s.expect(store.readySuggestions().isEmpty, "offered after two sightings")
        s.expectNotNil(store.record(correction), "third sighting should surface the suggestion")
        s.expectEqual(store.readySuggestions().count, 1)
        s.expectEqual(store.readySuggestions().first?.occurrences, 3)
    }

    suite.test("suggestions: the threshold moment fires exactly once") { s in
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let correction = WordCorrection(heard: "Sara", corrected: "Sarah")
        var announcements = 0
        for _ in 0..<6 where store.record(correction) != nil { announcements += 1 }
        s.expectEqual(announcements, 1)
    }

    suite.test("suggestions: distinct corrections are tracked separately and ranked") { s in
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        for _ in 0..<4 { store.record(WordCorrection(heard: "Sara", corrected: "Sarah")) }
        for _ in 0..<3 { store.record(WordCorrection(heard: "cuber", corrected: "Kubernetes")) }
        store.record(WordCorrection(heard: "payload", corrected: "Payload"))
        let ready = store.readySuggestions()
        s.expectEqual(ready.count, 2)
        s.expectEqual(ready.first?.corrected, "Sarah")   // 4 beats 3
    }

    suite.test("suggestions: stale corrections are forgotten, not silently learned") { s in
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let longAgo = Date(timeIntervalSinceNow: -SuggestedVocabularyStore.memoryWindow - 60)
        for _ in 0..<3 { store.record(WordCorrection(heard: "Sara", corrected: "Sarah"), now: longAgo) }
        s.expect(store.readySuggestions().isEmpty, "a month-old correction was still being offered")
    }

    suite.test("suggestions: accepting or dismissing removes it, and it survives a relaunch") { s in
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        for _ in 0..<3 { store.record(WordCorrection(heard: "Sara", corrected: "Sarah")) }
        // A fresh store over the same file sees the persisted state.
        let reopened = SuggestedVocabularyStore(url: url)
        s.expectEqual(reopened.readySuggestions().count, 1)
        guard let suggestion = reopened.readySuggestions().first else { return }
        reopened.remove(id: suggestion.id)
        s.expect(reopened.readySuggestions().isEmpty)
        s.expect(SuggestedVocabularyStore(url: url).readySuggestions().isEmpty, "removal didn't persist")
    }
}
