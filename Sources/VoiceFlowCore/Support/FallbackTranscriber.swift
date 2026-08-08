import Foundation

/// Routes each transcription to a preferred engine when it's available, and to a
/// fallback engine otherwise — so an opt-in engine that isn't ready yet (e.g. a
/// Whisper model still downloading) can NEVER make a dictation fail. Also falls
/// back when the preferred engine throws at runtime.
///
/// The route is re-evaluated per call, so an engine that becomes ready mid-session
/// takes over on the next dictation without a relaunch.
public final class FallbackTranscriber: Transcribing, @unchecked Sendable {
    private let preferred: Transcribing
    private let fallback: Transcribing
    private let usePreferred: @Sendable () -> Bool
    private let onFallback: (@Sendable (_ reason: String) -> Void)?

    /// - Parameters:
    ///   - preferred: engine to use when `usePreferred()` says it's ready.
    ///   - fallback: always-available engine (must not require the preferred one's state).
    ///   - usePreferred: cheap, thread-safe readiness check, evaluated per call.
    ///   - onFallback: invoked (once per call) when the preferred engine was wanted
    ///     but failed, with a short reason — for logging/telemetry.
    public init(
        preferred: Transcribing,
        fallback: Transcribing,
        usePreferred: @escaping @Sendable () -> Bool,
        onFallback: (@Sendable (_ reason: String) -> Void)? = nil
    ) {
        self.preferred = preferred
        self.fallback = fallback
        self.usePreferred = usePreferred
        self.onFallback = onFallback
    }

    public func transcribe(_ audio: AudioCapture, languageCode: String) async throws -> TranscriptionResult {
        try await transcribe(audio, languageCode: languageCode, context: .empty)
    }

    public func transcribe(
        _ audio: AudioCapture, languageCode: String, context: TranscriptionContext
    ) async throws -> TranscriptionResult {
        if usePreferred() {
            do {
                return try await preferred.transcribe(audio, languageCode: languageCode, context: context)
            } catch is CancellationError {
                throw CancellationError()   // a cancelled dictation must stay cancelled
            } catch {
                // On most failures the preferred engine leaves the capture intact
                // (Whisper deletes the file only on success) so the fallback can
                // re-read it. Exception: the phantom-arbiter path may have already
                // consumed the file — the fallback then cleanly reports an empty
                // transcript, which is the intended outcome for vetoed silence.
                onFallback?(String(describing: error))
            }
        }
        return try await fallback.transcribe(audio, languageCode: languageCode, context: context)
    }

    public func requestPermission() async -> Bool {
        await fallback.requestPermission()
    }
}
