import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

/// Phase 1 — context biasing. The prompt is what the recognizer gets nudged
/// toward, so these tests pin the two properties that matter: the user's own
/// vocabulary always wins the space, and nothing sensitive ever becomes a term.
func runContextBiasTests(_ suite: TestSuite) {

    // MARK: - TranscriptionContext

    suite.test("context: vocabulary comes before screen terms and dedupes case-insensitively") { s in
        let context = TranscriptionContext(
            vocabularyTerms: ["Payload CMS", "Next.js"],
            screenTerms: ["Kubernetes", "next.js", "Payload cms"]
        )
        s.expectEqual(context.orderedTerms, ["Payload CMS", "Next.js", "Kubernetes"])
    }

    suite.test("context: empty and whitespace terms are dropped") { s in
        let context = TranscriptionContext(vocabularyTerms: ["", "  ", "Swift"], screenTerms: ["\n"])
        s.expectEqual(context.orderedTerms, ["Swift"])
    }

    suite.test("context: prompt text stays under the cap and never truncates a term") { s in
        let distinct = (0..<20).map { "Nomenclature\($0)" }
        let capped = TranscriptionContext(vocabularyTerms: distinct).promptText(maxCharacters: 60)
        s.expect(capped.count <= 60, "prompt \(capped.count) chars exceeded the 60-char cap")
        s.expect(!capped.isEmpty, "cap swallowed every term")
        for term in capped.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            s.expect(distinct.contains(term), "prompt contained a truncated term: \(term)")
        }
    }

    suite.test("context: empty context yields an empty prompt") { s in
        s.expectEqual(TranscriptionContext.empty.promptText(), "")
        s.expect(TranscriptionContext.empty.isEmpty)
    }

    // MARK: - ScreenTermExtractor

    suite.test("screen terms: mid-sentence proper nouns are kept, sentence starts are not") { s in
        let terms = ScreenTermExtractor.terms(in: "The deploy for Kubernetes failed. Please retry.")
        s.expect(terms.contains("Kubernetes"), "expected Kubernetes, got \(terms)")
        s.expectFalse(terms.contains("The"), "sentence-initial 'The' leaked in: \(terms)")
        s.expectFalse(terms.contains("Please"), "sentence-initial 'Please' leaked in: \(terms)")
    }

    suite.test("screen terms: CamelCase, dotted and initialism tokens are kept anywhere") { s in
        let terms = ScreenTermExtractor.terms(in: "WhisperKit and Next.js talk to the API today")
        s.expect(terms.contains("WhisperKit"), "\(terms)")
        s.expect(terms.contains("Next.js"), "\(terms)")
        s.expect(terms.contains("API"), "\(terms)")
    }

    suite.test("screen terms: emails, URLs, paths and opaque ids are never harvested") { s in
        let text = "Ping Sarah at sarah@example.com or https://example.com/docs " +
                   "using /Users/yoni/secret and key AKIA1234567890ABCD"
        let terms = ScreenTermExtractor.terms(in: text)
        for term in terms {
            s.expectFalse(term.contains("@"), "email leaked: \(term)")
            s.expectFalse(term.contains("/"), "path/URL leaked: \(term)")
            s.expectFalse(term.count > 12 && term.contains(where: { $0.isNumber }), "opaque id leaked: \(term)")
        }
        s.expect(terms.contains("Sarah"), "the actual name was lost: \(terms)")
    }

    suite.test("screen terms: possessives are normalized and repeats rank first") { s in
        let text = "we told Sarah. the report from Sarah's team mentions Sarah and also Bob"
        let terms = ScreenTermExtractor.terms(in: text)
        s.expect(terms.contains("Sarah"), "\(terms)")
        s.expectFalse(terms.contains("Sarah's"), "possessive not normalized: \(terms)")
        s.expectEqual(terms.first, "Sarah")   // 3 mentions beats Bob's 1
    }

    suite.test("screen terms: known vocabulary is excluded and the limit is respected") { s in
        let text = "we run Kubernetes with Terraform and Grafana and Datadog daily"
        let terms = ScreenTermExtractor.terms(in: text, limit: 2, excluding: ["Kubernetes"])
        s.expect(terms.count <= 2, "limit ignored: \(terms)")
        s.expectFalse(terms.contains("Kubernetes"), "excluded term returned: \(terms)")
    }

    suite.test("screen terms: empty input is safe") { s in
        s.expectEqual(ScreenTermExtractor.terms(in: ""), [])
    }

    // MARK: - Controller wiring

    /// Builds a controller wired to a mock transcriber + screen reader so the
    /// context that actually reaches the engine can be inspected.
    func makeContextController(
        settings: AppSettings = .default,
        screen: MockScreenContextProvider?
    ) -> (DictationController, MockTranscriber) {
        let transcriber = MockTranscriber()
        let controller = DictationController(
            audio: MockAudioRecorder(),
            transcriber: transcriber,
            cleanup: CleanupPipeline(),
            inserter: MockTextInserter(),
            activeApp: MockActiveAppProvider(),
            history: InMemoryHistoryStore(),
            settings: settings,
            time: MockTimeSource(),
            screenContext: screen
        )
        return (controller, transcriber)
    }

    suite.test("controller: vocabulary and harvested screen nouns reach the engine") { s in
        var settings = AppSettings.default
        settings.vocabulary = [
            VocabularyEntry(spoken: "payload cms", written: "Payload CMS"),
            VocabularyEntry(spoken: "disabled", written: "NeverSent", isEnabled: false),
        ]
        let screen = MockScreenContextProvider(text: "the cluster runs Kubernetes in production")
        let (controller, transcriber) = makeContextController(settings: settings, screen: screen)
        _ = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            return try? await controller.finishRecording()
        }
        let context = transcriber.lastContext
        s.expectNotNil(context)
        s.expectEqual(context?.vocabularyTerms, ["Payload CMS"])
        s.expect(context?.screenTerms.contains("Kubernetes") == true,
                 "screen nouns missing: \(context?.screenTerms ?? [])")
    }

    suite.test("controller: screen context off means nothing is read") { s in
        var settings = AppSettings.default
        settings.screenContextEnabled = false
        let screen = MockScreenContextProvider(text: "the cluster runs Kubernetes in production")
        let (controller, transcriber) = makeContextController(settings: settings, screen: screen)
        _ = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            return try? await controller.finishRecording()
        }
        s.expectEqual(transcriber.lastContext?.screenTerms, [])
    }

    suite.test("controller: a slow screen reader never delays the dictation") { s in
        // 3s of AX stall against a 0.2s budget: the dictation must complete with
        // no screen terms rather than wait.
        let screen = MockScreenContextProvider(text: "Kubernetes everywhere", delay: 3.0)
        let (controller, transcriber) = makeContextController(screen: screen)
        let started = Date()
        _ = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            return try? await controller.finishRecording()
        }
        s.expect(Date().timeIntervalSince(started) < 2.0,
                 "dictation waited on the screen reader (\(Date().timeIntervalSince(started))s)")
        s.expectEqual(transcriber.lastContext?.screenTerms, [])
    }

    suite.test("controller: with no screen provider the context is vocabulary only") { s in
        let (controller, transcriber) = makeContextController(screen: nil)
        _ = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            return try? await controller.finishRecording()
        }
        s.expectEqual(transcriber.lastContext?.screenTerms, [])
        s.expect(transcriber.lastContext?.vocabularyTerms.isEmpty == false)
    }
}
