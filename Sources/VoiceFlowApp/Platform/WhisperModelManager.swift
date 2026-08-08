import Foundation
@preconcurrency import WhisperKit
import VoiceFlowCore

/// Owns the Whisper model lifecycle so the ~1 GB download NEVER happens inline
/// during a dictation: turning the toggle on starts a background download with
/// published progress; when the model is downloaded AND loaded (Core ML
/// specialization included), the ready pipeline is handed to
/// `WhisperKitTranscriber`. Until that moment every dictation keeps using the
/// Apple engine via `FallbackTranscriber` — nothing fails, nothing blocks.
@MainActor
final class WhisperModelManager: ObservableObject {
    enum State: Equatable {
        case idle                    // toggle off, or not started
        case downloading(Double)     // fraction 0…1
        case preparing               // downloaded; loading + ANE specialization
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Verified against the argmaxinc/whisperkit-coreml repo listing: resolves to
    /// folder "openai_whisper-large-v3-v20240930_turbo" — OpenAI's large-v3-turbo
    /// in Argmax's ANE-optimized conversion. NOTE the previous value
    /// "large-v3-turbo" matched NO folder in the repo and always failed.
    /// For the WER A/B, "openai_whisper-large-v3_turbo" is FULL large-v3 (no
    /// 4-layer decoder truncation, ~1 WER better on accents, bigger + slower) —
    /// settable via the override below without a rebuild.
    static let defaultModelVariant = "openai_whisper-large-v3-v20240930_turbo"
    private static let variantOverrideDefaultsKey = "whisperModelVariant"
    static var modelVariant: String {
        UserDefaults.standard.string(forKey: variantOverrideDefaultsKey) ?? defaultModelVariant
    }

    nonisolated static let enabledDefaultsKey = "useWhisperEngine"
    private nonisolated static let modelFolderDefaultsKey = "whisperModelFolderPath"

    private let transcriber: WhisperKitTranscriber
    private var task: Task<Void, Never>?
    /// Bumped on every new run and on toggle-off; stale runs check it before
    /// every state write so they can never race a newer run (see ensureReady).
    private var generation: UInt64 = 0

    init(transcriber: WhisperKitTranscriber) {
        self.transcriber = transcriber
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    /// Kick off download/load at launch when the user already opted in.
    func bootstrapIfEnabled() {
        if Self.isEnabled { ensureReady() }
    }

    /// Toggle handler: on → background download+load; off → cancel and unload.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledDefaultsKey)
        if on {
            ensureReady()
        } else {
            generation &+= 1        // orphan any in-flight task: its writes are ignored
            task?.cancel()
            task = nil
            transcriber.unload()
            state = .idle
        }
    }

    func retry() {
        guard Self.isEnabled else { state = .idle; return }
        state = .idle
        ensureReady()
    }

    /// Idempotent: starts the pipeline exactly once; re-entry while running or
    /// after ready is a no-op. Model files land under Application Support (kept
    /// out of ~/Documents), and a completed download is reused across launches.
    ///
    /// Every run is stamped with a generation; toggling off bumps the generation,
    /// so a stale task that survives cancellation (URLSession can take a moment,
    /// and CoreML loads aren't cancellable) can never adopt a pipeline, flip
    /// state, or clear the handle of a NEWER run. This is what makes rapid
    /// on→off→on flapping safe (review finding, 2026-08-08).
    func ensureReady() {
        guard Self.isEnabled else { return }
        guard task == nil, state != .ready, state != .preparing else { return }
        generation &+= 1
        let gen = generation
        state = Self.cachedModelFolder() == nil ? .downloading(0) : .preparing
        task = Task { [weak self] in
            await self?.run(generation: gen)
            guard let self, self.generation == gen else { return }
            self.task = nil
        }
    }

    /// True while `gen` is still the live run AND the feature is still on.
    private func isCurrent(_ gen: UInt64) -> Bool {
        generation == gen && Self.isEnabled
    }

    private func run(generation gen: UInt64) async {
        do {
            let folder: URL
            if let cached = Self.cachedModelFolder() {
                folder = cached
                Log.transcription.notice("Whisper model already on disk — loading")
            } else {
                Log.transcription.notice("Whisper model download started (\(Self.modelVariant, privacy: .public))")
                let onProgress: @Sendable (Progress) -> Void = { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        // Only advance while this run is still current and still
                        // in the downloading phase (ignore late/stale callbacks).
                        guard let self, self.isCurrent(gen),
                              case .downloading = self.state else { return }
                        self.state = .downloading(fraction)
                    }
                }
                folder = try await WhisperKit.download(
                    variant: Self.modelVariant,
                    downloadBase: Self.downloadBase(),
                    progressCallback: onProgress
                )
                UserDefaults.standard.set(folder.path, forKey: Self.modelFolderDefaultsKey)
                Log.transcription.notice("Whisper model downloaded to \(folder.path, privacy: .public)")
            }
            guard isCurrent(gen) else { return }
            try Task.checkCancellation()
            state = .preparing
            // prewarm keeps peak memory down during first-time Core ML
            // specialization; download:false guarantees no surprise network I/O.
            let config = WhisperKitConfig(
                model: Self.modelVariant,
                modelFolder: folder.path,
                prewarm: true,
                load: true,
                download: false
            )
            let pipeline = try await WhisperKit(config)
            // The load isn't cancellable — re-check before adopting so a pipeline
            // finished after toggle-off is discarded, not retained (1.5 GB).
            guard isCurrent(gen) else { return }
            try Task.checkCancellation()
            transcriber.adopt(pipeline)
            state = .ready
            Log.transcription.notice("Whisper ready — high-accuracy engine active")
        } catch {
            // A stale run reports nothing; setEnabled(false) already set .idle.
            guard isCurrent(gen) else { return }
            if Self.isCancellation(error) {
                state = .idle
            } else {
                let message = (error as NSError).localizedDescription
                Log.transcription.error("Whisper setup failed: \(String(describing: error), privacy: .public)")
                state = .failed(message)
            }
        }
    }

    /// Cancellation arrives as CancellationError from Task APIs but as
    /// URLError(.cancelled) from URLSession-backed downloads — both mean
    /// "the user turned it off", never a failure worth a Retry button.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    // MARK: - Disk locations

    /// ~/Library/Application Support/VoiceFlow/Models — NOT the WhisperKit default
    /// (~/Documents/huggingface), which would dump a gigabyte into Documents.
    private static func downloadBase() -> URL {
        AppPaths.baseDirectory().appendingPathComponent("Models", isDirectory: true)
    }

    /// A previously completed download, verified to still contain compiled
    /// Core ML models (so a half-deleted folder re-downloads instead of failing).
    private static func cachedModelFolder() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: modelFolderDefaultsKey),
              let children = try? FileManager.default.contentsOfDirectory(atPath: path),
              children.contains(where: { $0.hasSuffix(".mlmodelc") })
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}
