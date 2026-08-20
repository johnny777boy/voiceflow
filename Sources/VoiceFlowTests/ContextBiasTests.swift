import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

/// Phase 1 — context biasing. The prompt is what the recognizer gets nudged
/// toward, so these tests pin the two properties that matter: the user's own
/// vocabulary always wins the space, and nothing sensitive ever becomes a term.
func runContextBiasTests(_ suite: TestSuite) {

    // MARK: - Prompt echo (the decoder reading our glossary back at us)

    suite.test("echo: a transcript that is mostly the prompt glossary is caught") { s in
        let terms = ["Compose", "Drafts", "Snoozed", "Archive", "Meeting", "Payload CMS"]
        // The classic Whisper failure: near-silence decodes to the conditioning text.
        s.expect(TranscriptSanity.looksLikePromptEcho(
            text: "Compose, Drafts, Snoozed, Archive, Meeting.", promptTerms: terms))
        s.expect(TranscriptSanity.looksLikePromptEcho(
            text: "Drafts Archive Compose Meeting Snoozed", promptTerms: terms))
    }

    suite.test("echo: ordinary speech that mentions the user's terms is NOT an echo") { s in
        let terms = ["Compose", "Drafts", "Snoozed", "Archive", "Meeting", "Payload CMS"]
        // A false positive here throws away real speech, so the bar is high.
        s.expectFalse(TranscriptSanity.looksLikePromptEcho(
            text: "can you move the meeting to tomorrow afternoon", promptTerms: terms))
        s.expectFalse(TranscriptSanity.looksLikePromptEcho(
            text: "I put the draft in Payload CMS this morning", promptTerms: terms))
        // Too short to judge, and no terms at all.
        s.expectFalse(TranscriptSanity.looksLikePromptEcho(text: "Drafts Archive", promptTerms: terms))
        s.expectFalse(TranscriptSanity.looksLikePromptEcho(
            text: "Compose Drafts Archive Meeting", promptTerms: []))
    }

    suite.test("echo: a suspected transcript stands only when EVERY word is corroborated") { s in
        // The genuine case this exists to protect: a vocabulary-dense sentence
        // both engines independently produced. Punctuation and case don't count.
        s.expect(TranscriptSanity.isFullyCorroborated(
            "Sarah, Kubernetes, Payload CMS.", by: "sarah kubernetes payload cms"))
        // A shorter arbiter transcript still corroborates a subset of itself.
        s.expect(TranscriptSanity.isFullyCorroborated(
            "Sarah Kubernetes", by: "Sarah Kubernetes Grafana"))
    }

    suite.test("echo: partial agreement is a partial echo, not agreement") { s in
        // Codex round-3 FAIL. The user says three of their terms; the decoder
        // completes the glossary with the other two; the arbiter hears the three
        // real ones. Every similarity SCORE tried here cleared this (3/5 = 0.6),
        // and delivered "Payload CMS" — words neither the user nor the arbiter
        // produced. Only exact corroboration catches it.
        s.expectFalse(TranscriptSanity.isFullyCorroborated(
            "Sarah Kubernetes Payload CMS Grafana", by: "Sarah Kubernetes Grafana"))
        // Codex round-2 FAIL: a subset must not read as full agreement.
        s.expectFalse(TranscriptSanity.isFullyCorroborated(
            "Sarah Kubernetes Payload CMS Grafana", by: "Sarah"))
        // Outright disagreement, and the empty cases.
        s.expectFalse(TranscriptSanity.isFullyCorroborated(
            "Compose, Drafts, Snoozed, Archive.", by: "can you send that over"))
        s.expectFalse(TranscriptSanity.isFullyCorroborated("", by: "anything"))
        s.expectFalse(TranscriptSanity.isFullyCorroborated("anything", by: ""))
    }

    suite.test("echo: a word repeated more often than it was heard is not corroborated") { s in
        // Codex round-4 FAIL: comparing distinct word SETS ignored occurrences, so
        // an echo that simply repeats a term — "Sarah Kubernetes Grafana Sarah" —
        // matched "Sarah Kubernetes Grafana" exactly and the extra name was
        // delivered. Corroboration counts tokens, not types.
        s.expectFalse(TranscriptSanity.isFullyCorroborated(
            "Sarah Kubernetes Grafana Sarah", by: "Sarah Kubernetes Grafana"))
        // Legitimate repetition still passes when it was genuinely heard twice.
        s.expect(TranscriptSanity.isFullyCorroborated(
            "Sarah Kubernetes Sarah", by: "Sarah Kubernetes Sarah again"))
    }

    suite.test("echo: symbols inside a word are part of the word") { s in
        // Codex round-5 FAIL: corroboration reused `normalized`, which strips all
        // punctuation, so "C++" and "C" became the same token — an echoed "C++"
        // counted as corroborated by an arbiter that only said "C", and the
        // symbols were delivered.
        s.expectFalse(TranscriptSanity.isFullyCorroborated(
            "C++ Sarah Kubernetes Grafana", by: "C Sarah Kubernetes Grafana"))
        s.expectFalse(TranscriptSanity.isFullyCorroborated(
            "Next.js Sarah", by: "next Sarah"))
        s.expectFalse(TranscriptSanity.isFullyCorroborated("C# Sarah", by: "C Sarah"))
        // Identical symbol-bearing tokens still corroborate, and sentence
        // punctuation around a word is not part of it.
        s.expect(TranscriptSanity.isFullyCorroborated(
            "C++, Sarah.", by: "c++ sarah"))
        s.expect(TranscriptSanity.isFullyCorroborated(
            "we shipped Next.js", by: "We shipped Next.js!"))
    }

    suite.test("echo: a leading dot is part of a technical word") { s in
        // Codex round-6 FAIL: trimming `.` from BOTH ends collapsed ".NET" into
        // "net", so an echoed ".NET" was corroborated by an arbiter that only
        // said "NET" and the leading symbol was delivered.
        s.expectFalse(TranscriptSanity.isFullyCorroborated(
            ".NET Sarah Kubernetes Grafana", by: "NET Sarah Kubernetes Grafana"))
        // The identical term still corroborates through quotes, a trailing
        // sentence period, and case differences — the trailing dot of ".NET." is
        // a sentence period, the leading one is part of the word.
        s.expect(TranscriptSanity.isFullyCorroborated(
            "\".NET.\" Sarah", by: ".net Sarah"))
        s.expect(TranscriptSanity.isFullyCorroborated(
            "we moved to .NET.", by: "We moved to .NET"))
    }

    suite.test("echo: one better-heard word does not license the rest of the glossary") { s in
        // Whisper spelling the name right does NOT corroborate the terms the
        // arbiter never heard. We lose "Sarah" in favour of "Sara" here, and that
        // trade — lose a word rather than insert one — is the point.
        s.expectFalse(TranscriptSanity.isFullyCorroborated(
            "Sarah Kubernetes Payload CMS", by: "Sara Kubernetes"))
    }

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
        // The cap must cover the WHOLE prompt, framing included — only the last
        // 224 tokens reach the decoder, so framing that escaped the budget would
        // push the very terms it introduces out of the window.
        let capped = TranscriptionContext(vocabularyTerms: distinct).promptText(maxCharacters: 140)
        s.expect(capped.count <= 140, "prompt \(capped.count) chars exceeded the 140-char cap")
        s.expect(!capped.isEmpty, "cap swallowed every term")
        // The prompt is a sentence now, so strip the framing before checking the
        // terms themselves. The cap covers the WHOLE prompt including framing —
        // counting only the terms would silently overrun the 224-token window.
        let body = capped
            .replacingOccurrences(of: TranscriptionContext.promptLeadIn, with: "")
            .replacingOccurrences(of: TranscriptionContext.promptTrailer, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        for term in body.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            s.expect(distinct.contains(term), "prompt contained a truncated term: \(term)")
        }
    }

    suite.test("context: the prompt is a SENTENCE, not a word dump") { s in
        // MEASURED 2026-08-19 with VoiceFlowBench once WhisperKit v1.1.0 revived
        // biasing: a bare comma list of Capitalised Terms made Whisper copy the
        // LIST'S STYLE into the transcript — "The Whisper Flow Parity Work Needs
        // Aware Benchmark on My Voice". Whisper conditions on the prompt's form
        // as well as its vocabulary, so the prompt has to look like ordinary
        // prose or it corrupts the output it was meant to improve.
        let prompt = TranscriptionContext(vocabularyTerms: ["Payload CMS", "Codex"]).promptText()
        s.expect(prompt.hasSuffix("."), "prompt must end like a sentence, got: \(prompt)")
        s.expect(prompt.contains(" "), "prompt must read as prose")
        s.expect(prompt.contains("Payload CMS") && prompt.contains("Codex"),
                 "every term must survive, got: \(prompt)")
        // Rare words carry more weight the later they appear, so the terms must
        // sit at the END of the sentence, not the start.
        let head = prompt.prefix(while: { $0 != ":" && $0 != "," })
        s.expectFalse(head.hasPrefix("Payload"), "terms must not lead the prompt: \(prompt)")
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

    suite.test("screen terms: anything mixing letters and digits is refused") { s in
        // Short alphanumerics used to slip through the length-based id filter, so
        // a visible 2FA code or licence-key fragment could become a bias term —
        // i.e. get lifted off the screen and into the recognizer's prompt.
        let terms = ScreenTermExtractor.terms(
            in: "we told Sarah the code X4F9K2 and the licence AB12 for Kubernetes")
        s.expectFalse(terms.contains("X4F9K2"), "a short code was harvested: \(terms)")
        s.expectFalse(terms.contains("AB12"), "a short code was harvested: \(terms)")
        s.expect(terms.contains("Sarah"))
        s.expect(terms.contains("Kubernetes"))
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

    suite.test("echo defense also covers the prompt's FRAMING, not just the terms") { s in
        // Reviewer finding I10, and it blocks turning biasing on. The prompt is a
        // whole sentence — "The following transcript mentions X, Y, Z. It is
        // written in ordinary sentence case." — but the echo check only knew the
        // terms. A model parroting the FRAMING would have had it delivered as his
        // dictation: the invented-words failure in its purest form.
        let terms = ["Codex", "Payload CMS", "GitHub"]
        s.expect(TranscriptSanity.looksLikePromptEcho(
            text: "It is written in ordinary sentence case.", promptTerms: terms),
            "the trailer alone must be caught")
        s.expect(TranscriptSanity.looksLikePromptEcho(
            text: "The following transcript mentions Payload CMS", promptTerms: terms),
            "the lead-in plus one term must be caught")
        s.expect(TranscriptSanity.looksLikePromptEcho(
            text: "The following transcript mentions Codex, Payload CMS, GitHub. It is written in ordinary sentence case.",
            promptTerms: terms),
            "the whole prompt echoed back must be caught")
        // Real speech that happens to use his terms is NOT an echo.
        s.expectFalse(TranscriptSanity.looksLikePromptEcho(
            text: "Ask Codex to verify the branch before we merge it to main", promptTerms: terms),
            "a genuine dictation containing a term must survive")
        s.expectFalse(TranscriptSanity.looksLikePromptEcho(
            text: "Push the Payload CMS changes to GitHub and redeploy the staging site", promptTerms: terms),
            "a genuine dictation with two terms must survive")
    }
}
