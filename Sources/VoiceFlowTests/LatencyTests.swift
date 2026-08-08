import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

/// A stand-in for the on-device LLM stage: records whether it ran, and shouts
/// its result loudly enough that a test can tell the two phases apart.
private final class SpyCleanupProvider: CleanupProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _prewarms = 0
    var calls: Int { withLock { _calls } }
    var prewarms: Int { withLock { _prewarms } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func clean(_ rawText: String, context: CleanupContext) async throws -> String {
        withLock { _calls += 1 }
        return rawText + " [Polished]"
    }
    func prewarm() {
        withLock { _prewarms += 1 }
    }
}

/// Phase 3 — latency work. Each test pins a place where speed must not have been
/// bought with a behavior change.
func runLatencyTests(_ suite: TestSuite) {

    // MARK: - Short-utterance fast path

    suite.test("fast path: short casual phrases skip the LLM") { s in
        s.expect(ShortUtteranceFastPath.canSkipLLM("On my way.", mode: .cleanWriting))
        s.expect(ShortUtteranceFastPath.canSkipLLM("Sounds good to me.", mode: .cleanWriting))
        s.expect(ShortUtteranceFastPath.canSkipLLM("git status", mode: .claudeCode))
    }

    suite.test("fast path: questions keep the LLM, because the rules always write a period") { s in
        s.expectFalse(ShortUtteranceFastPath.canSkipLLM("Are you coming.", mode: .cleanWriting))
        s.expectFalse(ShortUtteranceFastPath.canSkipLLM("How did it go.", mode: .cleanWriting))
        s.expectFalse(ShortUtteranceFastPath.canSkipLLM("Can you send it.", mode: .cleanWriting))
    }

    suite.test("fast path: long utterances and email always keep the LLM") { s in
        let long = "this is a considerably longer sentence that runs past the word budget easily"
        s.expectFalse(ShortUtteranceFastPath.canSkipLLM(long, mode: .cleanWriting))
        s.expectFalse(ShortUtteranceFastPath.canSkipLLM("Thanks again.", mode: .email))
        s.expectFalse(ShortUtteranceFastPath.canSkipLLM("", mode: .cleanWriting))
    }

    suite.test("pipeline: the fast path actually bypasses the provider, and the flag disables it") { s in
        let spy = SpyCleanupProvider()
        let pipeline = CleanupPipeline(llmProvider: spy, useLLM: true)
        let fastContext = CleanupContext(mode: .cleanWriting, strength: .standard, vocabulary: [],
                                         languageCode: "en-US", fastPathEnabled: true)
        let fullContext = CleanupContext(mode: .cleanWriting, strength: .standard, vocabulary: [],
                                         languageCode: "en-US", fastPathEnabled: false)
        let skipped = blockingAwait { try? await pipeline.clean("on my way", context: fastContext) }
        s.expectEqual(skipped, "On my way.")
        s.expectEqual(spy.calls, 0)

        let refined = blockingAwait { try? await pipeline.clean("on my way", context: fullContext) }
        s.expectEqual(refined, "On my way. [Polished]")
        s.expectEqual(spy.calls, 1)
    }

    suite.test("pipeline: prewarm reaches the provider only when the LLM stage is on") { s in
        let spy = SpyCleanupProvider()
        CleanupPipeline(llmProvider: spy, useLLM: false).prewarm()
        s.expectEqual(spy.prewarms, 0)
        CleanupPipeline(llmProvider: spy, useLLM: true).prewarm()
        s.expectEqual(spy.prewarms, 1)
    }

    suite.test("pipeline: deterministicClean never consults the model") { s in
        let spy = SpyCleanupProvider()
        let pipeline = CleanupPipeline(llmProvider: spy, useLLM: true)
        let context = CleanupContext(mode: .cleanWriting, strength: .standard, vocabulary: [],
                                     languageCode: "en-US", fastPathEnabled: false)
        let fast = blockingAwait { try? await pipeline.deterministicClean("hello there friend", context: context) }
        s.expectEqual(fast, "Hello there friend.")
        s.expectEqual(spy.calls, 0)
    }

    // MARK: - Two-phase delivery

    suite.test("two-phase: off by default — one insertion of the fully cleaned text") { s in
        let spy = SpyCleanupProvider()
        let inserter = MockTextInserter()
        inserter.supportsReplacement = true
        let controller = DictationController(
            audio: MockAudioRecorder(), transcriber: MockTranscriber(),
            cleanup: CleanupPipeline(llmProvider: spy, useLLM: true),
            inserter: inserter, activeApp: MockActiveAppProvider(),
            history: InMemoryHistoryStore(), settings: .default, time: MockTimeSource()
        )
        _ = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            return try? await controller.finishRecording()
        }
        s.expectEqual(inserter.insertCount, 1)
        s.expectNil(inserter.replacedText)
    }

    suite.test("two-phase: on — deterministic text lands first, then is upgraded in place") { s in
        var settings = AppSettings.default
        settings.twoPhaseDeliveryEnabled = true
        settings.fastShortUtterances = false
        let inserter = MockTextInserter()
        inserter.supportsReplacement = true
        let transcriber = MockTranscriber()
        transcriber.resultToReturn = TranscriptionResult(text: "the quick brown fox jumps over the lazy dog")
        let controller = DictationController(
            audio: MockAudioRecorder(), transcriber: transcriber,
            cleanup: CleanupPipeline(llmProvider: SpyCleanupProvider(), useLLM: true),
            inserter: inserter, activeApp: MockActiveAppProvider(),
            history: InMemoryHistoryStore(), settings: settings, time: MockTimeSource()
        )
        let result = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            return try? await controller.finishRecording()
        }
        s.expectEqual(inserter.replacedText, "The quick brown fox jumps over the lazy dog. [Polished]")
        // History must record what ended up in the field, not the interim text.
        s.expectEqual(result?.record.cleanText, "The quick brown fox jumps over the lazy dog. [Polished]")
    }

    suite.test("two-phase: a destination that refuses the swap keeps the delivered text") { s in
        var settings = AppSettings.default
        settings.twoPhaseDeliveryEnabled = true
        settings.fastShortUtterances = false
        let inserter = MockTextInserter()
        inserter.supportsReplacement = false   // e.g. the user started typing
        let transcriber = MockTranscriber()
        transcriber.resultToReturn = TranscriptionResult(text: "the quick brown fox jumps over the lazy dog")
        let controller = DictationController(
            audio: MockAudioRecorder(), transcriber: transcriber,
            cleanup: CleanupPipeline(llmProvider: SpyCleanupProvider(), useLLM: true),
            inserter: inserter, activeApp: MockActiveAppProvider(),
            history: InMemoryHistoryStore(), settings: settings, time: MockTimeSource()
        )
        let result = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            return try? await controller.finishRecording()
        }
        s.expectEqual(inserter.insertedText, "The quick brown fox jumps over the lazy dog.")
        s.expectEqual(result?.record.cleanText, "The quick brown fox jumps over the lazy dog.")
    }

    // MARK: - In-place replacement range

    suite.test("refine range: matches only when the delivered text still ends at the caret") { s in
        let value = "Hello there friend."
        let caret = value.utf16.count
        let range = RefinementPlanner.replacementRange(
            value: value, caretUTF16: caret, delivered: "there friend.")
        s.expectEqual(range, NSRange(location: 6, length: 13))
    }

    suite.test("refine range: refuses once the user has typed, moved, or emptied the field") { s in
        // User typed a character after our text.
        s.expectNil(RefinementPlanner.replacementRange(
            value: "Hello there friend.!", caretUTF16: 20, delivered: "there friend."))
        // Caret moved back into the middle.
        s.expectNil(RefinementPlanner.replacementRange(
            value: "Hello there friend.", caretUTF16: 6, delivered: "there friend."))
        // Caret beyond the value / nothing delivered / text replaced wholesale.
        s.expectNil(RefinementPlanner.replacementRange(
            value: "Hello", caretUTF16: 99, delivered: "Hello"))
        s.expectNil(RefinementPlanner.replacementRange(
            value: "Hello", caretUTF16: 5, delivered: ""))
        s.expectNil(RefinementPlanner.replacementRange(
            value: "something else", caretUTF16: 14, delivered: "there friend."))
    }

    suite.test("refine range: a leading space is part of the delivered payload") { s in
        let value = "Hi there"
        let range = RefinementPlanner.replacementRange(
            value: value, caretUTF16: value.utf16.count, delivered: " there")
        s.expectEqual(range, NSRange(location: 2, length: 6))
    }

    // MARK: - Cancellation ownership

    suite.test("cancel during transcription must not yank the capture from the finish") { s in
        let audio = MockAudioRecorder()
        let transcriber = MockTranscriber()
        transcriber.delay = 0.4          // dictation is genuinely mid-flight
        let controller = DictationController(
            audio: audio, transcriber: transcriber, cleanup: CleanupPipeline(),
            inserter: MockTextInserter(), activeApp: MockActiveAppProvider(),
            history: InMemoryHistoryStore(), settings: .default, time: MockTimeSource()
        )
        let result = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            async let finished = try? await controller.finishRecording()
            try? await Task.sleep(nanoseconds: 150_000_000)   // let the finish reach transcription
            await controller.cancelRecording()                // cancel arrives mid-flight
            return await finished
        }
        s.expectNotNil(result, "a cancel during transcription killed the dictation")
        s.expectEqual(audio.stopCount, 1, "the recorder was torn down twice")
    }
}
