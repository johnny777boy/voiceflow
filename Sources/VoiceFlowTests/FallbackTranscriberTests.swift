import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

/// The engine router that keeps dictation alive while the opt-in Whisper engine
/// is downloading (or broken): preferred engine only when ready, Apple fallback
/// otherwise and on ANY preferred-engine failure.
func runFallbackTranscriberTests(_ s: TestSuite) {
    let capture = AudioCapture(samples: [], sampleRate: 16_000, duration: 1)

    s.test("routes to preferred engine when ready") { s in
        let preferred = MockTranscriber()
        preferred.resultToReturn = TranscriptionResult(text: "whisper")
        let fallback = MockTranscriber()
        fallback.resultToReturn = TranscriptionResult(text: "apple")
        let router = FallbackTranscriber(preferred: preferred, fallback: fallback,
                                         usePreferred: { true })
        let out = blockingAwait { try? await router.transcribe(capture, languageCode: "en-US") }
        s.expectEqual(out?.text, "whisper")
    }

    s.test("routes to fallback while preferred is not ready") { s in
        let preferred = MockTranscriber()
        preferred.resultToReturn = TranscriptionResult(text: "whisper")
        let fallback = MockTranscriber()
        fallback.resultToReturn = TranscriptionResult(text: "apple")
        let router = FallbackTranscriber(preferred: preferred, fallback: fallback,
                                         usePreferred: { false })
        let out = blockingAwait { try? await router.transcribe(capture, languageCode: "en-US") }
        s.expectEqual(out?.text, "apple")
    }

    s.test("falls back when the preferred engine throws, and reports the reason") { s in
        let preferred = MockTranscriber()
        preferred.error = VoiceFlowError.audioEngineFailure("model exploded")
        let fallback = MockTranscriber()
        fallback.resultToReturn = TranscriptionResult(text: "apple saves the day")
        let reasonBox = Box<String>()
        let router = FallbackTranscriber(preferred: preferred, fallback: fallback,
                                         usePreferred: { true },
                                         onFallback: { reasonBox.set($0) })
        let out = blockingAwait { try? await router.transcribe(capture, languageCode: "en-US") }
        s.expectEqual(out?.text, "apple saves the day")
        s.expect(reasonBox.get()?.contains("model exploded") == true, "fallback reason is surfaced")
    }

    s.test("readiness is re-evaluated per call (mid-session takeover, no relaunch)") { s in
        let preferred = MockTranscriber()
        preferred.resultToReturn = TranscriptionResult(text: "whisper")
        let fallback = MockTranscriber()
        fallback.resultToReturn = TranscriptionResult(text: "apple")
        let ready = Box<Bool>()
        ready.set(false)
        let router = FallbackTranscriber(preferred: preferred, fallback: fallback,
                                         usePreferred: { ready.get() == true })
        let first = blockingAwait { try? await router.transcribe(capture, languageCode: "en-US") }
        ready.set(true)   // model finished downloading mid-session
        let second = blockingAwait { try? await router.transcribe(capture, languageCode: "en-US") }
        s.expectEqual(first?.text, "apple")
        s.expectEqual(second?.text, "whisper")
    }

    s.test("error from the fallback engine still propagates (nothing swallows it)") { s in
        let preferred = MockTranscriber()
        preferred.error = VoiceFlowError.emptyTranscript
        let fallback = MockTranscriber()
        fallback.error = VoiceFlowError.emptyTranscript
        let router = FallbackTranscriber(preferred: preferred, fallback: fallback,
                                         usePreferred: { true })
        let out = blockingAwait { () -> Bool in
            do { _ = try await router.transcribe(capture, languageCode: "en-US"); return false }
            catch { return true }
        }
        s.expect(out, "both engines failing must throw to the caller")
    }
}

/// Tiny thread-safe box for observing callbacks from Sendable closures in tests.
private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}
