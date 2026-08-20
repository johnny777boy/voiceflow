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
public final class WhisperModelManager: ObservableObject {
    public enum State: Equatable {
        case idle                    // toggle off, or not started
        case downloading(Double)     // fraction 0…1
        case preparing               // downloaded; loading + ANE specialization
        case ready
        case failed(String)
    }

    @Published public private(set) var state: State = .idle

    /// Verified against the argmaxinc/whisperkit-coreml repo listing: resolves to
    /// folder "openai_whisper-large-v3-v20240930_turbo" — OpenAI's large-v3-turbo
    /// in Argmax's ANE-optimized conversion. NOTE the previous value
    /// "large-v3-turbo" matched NO folder in the repo and always failed.
    /// WRONG BEFORE, CORRECTED 2026-08-19 against the repo's own file listing:
    /// `openai_whisper-large-v3_turbo` is ALSO a turbo build (every `*_turbo`
    /// folder is). The A/B this comment described would therefore have compared
    /// turbo against turbo, measured "no difference", and wrongly cleared the
    /// model — the same shape of plausible-but-false result as the dead-engine
    /// week.
    ///
    /// FULL large-v3 is `openai_whisper-large-v3-v20240930` — the same
    /// conversion vintage as the default, differing ONLY in the decoder (32
    /// layers vs turbo's 4). That makes it the honest A/B counterpart.
    ///
    /// Why it matters here specifically: OpenAI's own benchmarks put full
    /// large-v3 ahead of turbo by ~0.2 WER on clean English but ~1.1 WER on
    /// ACCENTED English. Yoni is a non-native speaker, so he sits in the case
    /// where the distillation costs the most — and this trade was never
    /// WER-gated, which the standing "speed may never cost quality" rule
    /// requires. Bigger and slower; measure before adopting.
    ///
    ///   defaults write com.voiceflow.dictation whisperModelVariant \
    ///     -string "openai_whisper-large-v3-v20240930"
    ///
    /// Settable via the override below without a rebuild.
    public static let defaultModelVariant = "openai_whisper-large-v3-v20240930_turbo"
    private static let variantOverrideDefaultsKey = "whisperModelVariant"
    public static var modelVariant: String {
        UserDefaults.standard.string(forKey: variantOverrideDefaultsKey) ?? defaultModelVariant
    }

    public nonisolated static let enabledDefaultsKey = "useWhisperEngine"
    /// Cached model folder, KEYED BY VARIANT.
    ///
    /// It used to be one shared key, and that made the model A/B a lie: setting
    /// `whisperModelVariant` to full large-v3 skipped the download, loaded the
    /// cached TURBO `.mlmodelc` files under the new name, resolved the (identical)
    /// tokenizer, reported ready — and the user dictated on turbo believing he
    /// was on large-v3. Nothing errored, because both variants share a tokenizer.
    /// Exactly the shape of plausible-but-false result this project has already
    /// been burned by twice.
    private nonisolated static func modelFolderDefaultsKey(for variant: String) -> String {
        "whisperModelFolderPath.\(variant)"
    }

    private let transcriber: WhisperKitTranscriber
    private var task: Task<Void, Never>?
    /// Bumped on every new run and on toggle-off; stale runs check it before
    /// every state write so they can never race a newer run (see ensureReady).
    private var generation: UInt64 = 0

    public init(transcriber: WhisperKitTranscriber) {
        self.transcriber = transcriber
    }

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    /// Kick off download/load at launch when the user already opted in.
    public func bootstrapIfEnabled() {
        if Self.isEnabled { ensureReady() }
    }

    /// Toggle handler: on → background download+load; off → cancel and unload.
    public func setEnabled(_ on: Bool) {
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

    public func retry() {
        guard Self.isEnabled else { state = .idle; return }
        // An explicit retry is the user accepting the cost of a fresh attempt
        // even if a watchdog-orphaned load is still running, so the handle is
        // dropped here (and only here) to let `ensureReady` proceed.
        task?.cancel()
        task = nil
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
        // NO watchdog armed here — deliberately. `run()` arms one the moment it
        // actually enters the load phase, on BOTH the cached and the downloaded
        // path. An arm here would start its clock at t=0 and then fire mid-LOAD:
        // a download finishing at t=170 would leave the (legitimately
        // minutes-long) first-time Core ML specialization just 10 seconds before
        // being declared stuck — deterministically killing healthy first loads on
        // fast connections. Both reviewers caught this independently.
    }

    /// Watchdog for the LOAD phase. A model load that neither finishes nor
    /// throws — a stalled file read once held it in `.preparing` for over a
    /// week — must become a visible failure, never a silent one: the router
    /// keeps serving the fallback engine while the UI claims High Accuracy is
    /// coming, and the user's accuracy quietly degrades with no error anywhere.
    /// Downloading is exempt (a 1.5 GB download may legitimately take longer;
    /// it also reports progress). The stuck load itself cannot be cancelled —
    /// bumping the generation orphans it, so a late completion is discarded by
    /// the existing `isCurrent` guards instead of resurrecting a zombie run.
    ///
    /// MUST be armed only at the moment the load phase actually begins, never
    /// earlier: the guard is `(generation, state)` with no phase token, so a
    /// watchdog armed before the download cannot tell a 10-second-old load from
    /// a 180-second-old one.
    private func watchLoadPhase(generation gen: UInt64, timeout: TimeInterval = 180) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, self.generation == gen, self.state == .preparing else { return }
            self.generation &+= 1
            // `task` is deliberately NOT cleared: the orphaned load is still
            // specializing 1.5 GB of Core ML and cannot be cancelled. Leaving the
            // handle in place makes `ensureReady`'s `task == nil` guard refuse a
            // second concurrent load, so Retry can't double peak memory while the
            // zombie finishes. The zombie clears the handle itself on completion
            // (its `generation == gen` check fails, so it no-ops) — see retry(),
            // which drops the handle explicitly for the deliberate case.
            Log.transcription.error("Whisper load watchdog fired after \(Int(timeout), privacy: .public)s — marking failed")
            self.state = .failed("Model load timed out. Dictation continues on the standard engine — use Retry, or toggle High Accuracy off and on.")
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
                // CRITICAL ordering: HubApi.snapshot RETURNS the partial folder
                // (instead of throwing) when cancelled between files — so a
                // cancellation check must run before anything trusts `folder`,
                // and the folder path is persisted ONLY after the pipeline
                // below loads successfully. Persisting here once wedged the
                // feature permanently on a half-downloaded model.
                try Task.checkCancellation()
                Log.transcription.notice("Whisper model downloaded to \(folder.path, privacy: .public)")
            }
            guard isCurrent(gen) else { return }
            try Task.checkCancellation()
            state = .preparing
            // THE arming point for the load watchdog — reached by both the
            // cached-folder path and the post-download path, and only once the
            // load is genuinely starting, so its full budget measures the load.
            watchLoadPhase(generation: gen)
            // prewarm keeps peak memory down during first-time Core ML
            // specialization; download:false guarantees no surprise network I/O.
            // BOTH bases must point at App Support. The model folder alone is
            // not enough: WhisperKit resolves its TOKENIZER through
            // `tokenizerFolder ?? downloadBase`, and with neither set it falls
            // back to the library default — ~/Documents/huggingface — which is
            // TCC-protected for a background app. That read can stall without
            // throwing, leaving the load stuck in .preparing forever with no
            // error: the user dictates for days on the fallback engine without
            // being told (lived defect, 2026-08-10 → 2026-08-18).
            let config = WhisperKitConfig(
                model: Self.modelVariant,
                downloadBase: Self.downloadBase(),
                modelFolder: folder.path,
                tokenizerFolder: Self.downloadBase(),
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
            // Only a folder that produced a WORKING pipeline is remembered.
            UserDefaults.standard.set(folder.path, forKey: Self.modelFolderDefaultsKey(for: Self.modelVariant))
            state = .ready
            Log.transcription.notice("Whisper ready — high-accuracy engine active")
        } catch {
            // A stale run reports nothing; setEnabled(false) already set .idle.
            guard isCurrent(gen) else { return }
            if Self.isCancellation(error) {
                state = .idle
            } else {
                // Forget a cached folder that failed to load (corrupt/partial):
                // the next attempt re-runs the download, which cheaply resumes/
                // verifies existing files instead of retrying a doomed load.
                UserDefaults.standard.removeObject(forKey: Self.modelFolderDefaultsKey(for: Self.modelVariant))
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

    /// Load a pipeline for `variant` exactly the way the app loads it.
    ///
    /// Exists so `VoiceFlowBench` can decode with the SAME configuration the
    /// app uses — the tokenizer/downloadBase pinning below is not cosmetic, it
    /// is the fix for the defect that silently killed the engine for eight
    /// days, and a benchmark that skipped it would be measuring a different
    /// program than the one Yoni dictates into.
    ///
    /// Downloads if the variant is not present, which is exactly what a model
    /// A/B needs the first time it runs.
    /// Returns the pipeline AND the folder it was actually loaded from, so a
    /// caller can PROVE which weights are running. Nothing in WhisperKit's API
    /// distinguishes turbo from full large-v3 after loading (same dims,
    /// different decoder depth), and this project has already had one A/B that
    /// would have compared turbo with turbo.
    public static func loadPipeline(
        variant: String,
        onDownloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (pipeline: WhisperKit, folder: URL) {
        let folder = try await WhisperKit.download(
            variant: variant,
            downloadBase: downloadBase(),
            progressCallback: { p in onDownloadProgress?(p.fractionCompleted) }
        )
        let config = WhisperKitConfig(
            model: variant,
            downloadBase: downloadBase(),
            modelFolder: folder.path,
            tokenizerFolder: downloadBase(),
            prewarm: true,
            load: true,
            download: false
        )
        // `HubApi.snapshot` returns a PARTIAL folder instead of throwing when a
        // download is interrupted. The app path guards this; this one must too,
        // or a half-downloaded model loads and silently decodes differently.
        guard folder.lastPathComponent == variant else {
            throw VoiceFlowError.audioEngineFailure(
                "resolved folder \(folder.lastPathComponent) does not match variant \(variant)")
        }
        return (try await WhisperKit(config), folder)
    }

    /// ~/Library/Application Support/VoiceFlow/Models — NOT the WhisperKit default
    /// (~/Documents/huggingface), which would dump a gigabyte into Documents.
    private static func downloadBase() -> URL {
        AppPaths.baseDirectory().appendingPathComponent("Models", isDirectory: true)
    }

    /// A previously completed download, verified to still contain compiled
    /// Core ML models (so a half-deleted folder re-downloads instead of failing).
    private static func cachedModelFolder() -> URL? {
        let variant = modelVariant
        guard let path = UserDefaults.standard.string(forKey: modelFolderDefaultsKey(for: variant)),
              let children = try? FileManager.default.contentsOfDirectory(atPath: path),
              children.contains(where: { $0.hasSuffix(".mlmodelc") })
        else { return nil }
        // Belt and braces: the folder WhisperKit downloads is named after the
        // variant, so a path that does not contain it is a cache from another
        // model and must be treated as a miss rather than loaded silently.
        guard URL(fileURLWithPath: path).lastPathComponent == variant else {
            Log.transcription.error("Cached model folder \(path, privacy: .public) does not match variant \(variant, privacy: .public) — re-resolving")
            return nil
        }
        return URL(fileURLWithPath: path)
    }
}
