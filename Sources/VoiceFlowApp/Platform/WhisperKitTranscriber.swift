import Foundation
@preconcurrency import WhisperKit
import VoiceFlowCore

/// Optional high-accuracy transcriber: on-device **Whisper** via WhisperKit,
/// running on the Apple Neural Engine (Core ML — no Metal compiler needed).
/// Whisper is trained on hugely diverse, accented, real-world speech, so it
/// handles non-native English better than Apple's model — at the cost of ~1–2s
/// latency and a one-time model download. Audio stays on-device.
///
/// It only transcribes; `SpeechAnalyzerDictation` still records the audio to a
/// file and passes its URL through `AudioCapture.fileURL`.
///
/// This class NEVER downloads or loads the model itself — `WhisperModelManager`
/// does that in the background and hands the ready pipeline to `adopt(_:)`.
/// Until then `isReady` is false and the `FallbackTranscriber` routes dictations
/// to the Apple engine, so nothing ever fails or blocks on the ~1 GB download.
@available(macOS 14.0, *)
final class WhisperKitTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private var pipeline: WhisperKit?
    private var suppressTokens: [Int] = []

    /// Second-opinion engine for phantom suppression (the Apple engine). Whisper
    /// invents phrases on near-silence ("Thank you.", "Thank God."); Apple's
    /// recognizer provably emits NOTHING on the same silence. When Whisper's
    /// whole output is a known phantom phrase, the same recording is re-checked
    /// here: arbiter hears words ⇒ genuine speech, deliver; arbiter hears
    /// nothing ⇒ silence, discard. Real speech can never be eaten by this veto.
    var silenceArbiter: Transcribing?

    /// Thread-safe readiness check for the per-dictation route.
    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return pipeline != nil
    }

    /// Called by `WhisperModelManager` once the model is downloaded and loaded.
    func adopt(_ loaded: WhisperKit) {
        // Resolve the non-speech suppression token set once per loaded model
        // (token ids differ across vocab versions, so never hardcode them).
        let tokens = loaded.tokenizer.map(Self.nonSpeechTokens) ?? []
        lock.lock(); defer { lock.unlock() }
        pipeline = loaded
        suppressTokens = tokens
    }

    /// Drop the pipeline (user turned the toggle off) so memory is reclaimed.
    func unload() {
        lock.lock(); defer { lock.unlock() }
        pipeline = nil
    }

    private func currentPipeline() -> (WhisperKit, [Int])? {
        lock.lock(); defer { lock.unlock() }
        guard let pipeline else { return nil }
        return (pipeline, suppressTokens)
    }

    /// Port of OpenAI whisper `tokenizer.non_speech_tokens`: symbol tokens
    /// (brackets, quotes, music notes, …) whose emission on quiet/noisy audio is
    /// artifact, not dictation. WhisperKit v0.18 leaves this set empty by default
    /// (`// TODO` in Configurations.swift), so we build it ourselves. Logit
    /// suppression cannot delete spoken words — it only bans symbol tokens.
    private static func nonSpeechTokens(_ tokenizer: any WhisperTokenizer) -> [Int] {
        let specialBegin = tokenizer.specialTokens.specialTokenBegin
        func enc(_ s: String) -> [Int] { tokenizer.encode(text: s).filter { $0 < specialBegin } }
        var result = Set<Int>()
        if let t = enc(" -").first { result.insert(t) }
        if let t = enc(" '").first { result.insert(t) }
        let symbols = "\"#()*+/:;<=>@[]^_`{|}~「」『』".map(String.init)
            + ["<<", ">>", "<<<", ">>>", "--", "---", "-(", "-[", "('", "((", "))", "(((", ")))", "[[", "]]", "{{", "}}", "♪♪", "♪♪♪"]
        let miscellaneous: Set<String> = ["♩", "♪", "♫", "♬", "♭", "♮", "♯"]
        for s in symbols + Array(miscellaneous) {
            for ids in [enc(s), enc(" " + s)] {
                if ids.count == 1 {
                    result.insert(ids[0])
                } else if miscellaneous.contains(s) {
                    ids.forEach { result.insert($0) }
                }
            }
        }
        return result.sorted()
    }

    /// Encode the per-dictation context into Whisper `promptTokens`.
    ///
    /// WhisperKit prefixes these with `<|startofprev|>`, i.e. Whisper treats them
    /// as "text that preceded this audio" — the documented way to bias decoding
    /// toward names and jargon. Two hard rules, both enforced here as well as by
    /// WhisperKit: only non-special tokens may be fed (a special token would
    /// hijack the decoder's task/language prefill), and the prompt must stay far
    /// below half the 448-token context so it can never crowd out the audio.
    ///
    /// Biasing changes *probabilities*, but it is NOT free of risk: because the
    /// prompt is presented as preceding text, a decoder with little to work with
    /// can continue it and emit the glossary as the transcript. That is real and
    /// documented, so the output is checked for prompt echo after decode
    /// (`TranscriptSanity.looksLikePromptEcho`) — never trusted blind.
    private static func promptTokens(
        for context: VoiceFlowCore.TranscriptionContext,
        tokenizer: any WhisperTokenizer,
        maxTokens: Int = 180
    ) -> [Int]? {
        let text = context.promptText()
        guard !text.isEmpty else { return nil }
        let specialBegin = tokenizer.specialTokens.specialTokenBegin
        let tokens = tokenizer.encode(text: text).filter { $0 < specialBegin }
        guard !tokens.isEmpty else { return nil }
        return Array(tokens.prefix(maxTokens))
    }

    func requestPermission() async -> Bool { true }   // mic handled by the recorder

    func transcribe(_ audio: AudioCapture, languageCode: String) async throws -> VoiceFlowCore.TranscriptionResult {
        try await transcribe(audio, languageCode: languageCode, context: .empty)
    }

    func transcribe(
        _ audio: AudioCapture, languageCode: String, context: VoiceFlowCore.TranscriptionContext
    ) async throws -> VoiceFlowCore.TranscriptionResult {
        guard let (wk, suppress) = currentPipeline() else {
            throw VoiceFlowError.audioEngineFailure("Whisper model not ready.")
        }
        guard let url = audio.fileURL else { throw VoiceFlowError.emptyTranscript }

        // Load once (resampled to 16kHz mono by WhisperKit) and measure energy in
        // 100ms chunks. Whisper hallucinates full sentences on silence, so a
        // truly-silent clip (accidental key-press) must never reach the decoder.
        // Thresholds are DELIBERATELY far below WhisperKit's speech default
        // (0.02 RMS): a quiet accented speaker must never be gated. Both RMS and
        // peak must agree before we discard. Energies are logged on every clip so
        // the thresholds can be tuned from real data.
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        let chunkSize = 1600   // 100ms @ 16kHz
        var maxChunkRMS: Float = 0
        var index = 0
        while index < samples.count {
            let chunk = Array(samples[index..<min(index + chunkSize, samples.count)])
            maxChunkRMS = max(maxChunkRMS, AudioProcessor.calculateAverageEnergy(of: chunk))
            index += chunkSize
        }
        let peak = AudioProcessor.calculateEnergy(of: samples).max
        Log.transcription.notice("Whisper clip energy: maxRMS=\(maxChunkRMS, privacy: .public) peak=\(peak, privacy: .public)")
        if maxChunkRMS < 0.005, peak < 0.015 {
            Log.transcription.notice("Whisper energy gate: silent clip — skipping decode")
            throw VoiceFlowError.emptyTranscript
        }

        // Decoding options per the parity research: force English with the prefill
        // prompt (language mis-detect is a catastrophic failure mode on accented
        // speech), greedy decode with the temperature-fallback schedule ON, no
        // timestamps (shorter/faster decode for dictation), and NO VAD chunking —
        // dictations are single ≤30s windows and chunking risks splitting words.
        var options = DecodingOptions()
        options.task = .transcribe
        let lang = String(languageCode.prefix(2))
        options.language = lang.isEmpty ? "en" : lang
        options.usePrefillPrompt = true
        options.detectLanguage = false
        options.temperature = 0
        // One retry step (temps 0, 0.2): keeps the only escape hatch for greedy
        // repetition loops while capping added latency and randomness. Do NOT
        // tighten logProbThreshold below the -1.0 default — that converts marginal
        // accented clips into random high-temperature resampling.
        options.temperatureFallbackCount = 1
        options.skipSpecialTokens = true
        options.suppressBlank = true      // keep [BLANK_AUDIO]-style tokens out on quiet clips
        // NOTE: options.noSpeechThreshold is DEAD CONFIG in WhisperKit v0.18.0 —
        // noSpeechProb is hardcoded 0 (TextDecoder.swift "TODO: implement no
        // speech prob"), so the decoder-side silence gate can never fire. All
        // silence defense lives in the energy gate above + post-filter below.
        // Re-audit this (and prefill interaction, WhisperKit issue #27) on any
        // WhisperKit version bump.
        options.supressTokens = suppress   // (sic — WhisperKit API spelling)
        options.withoutTimestamps = true
        options.wordTimestamps = false
        options.chunkingStrategy = ChunkingStrategy.none

        // Context biasing: the user's vocabulary + proper nouns read off the
        // frontmost window. Verified against the pinned WhisperKit 0.18.0
        // (TextDecoder.prefillDecoderInputs): prompt tokens are prefixed with
        // startOfPreviousToken, filtered below specialTokenBegin, and the prefill
        // KV-cache is bypassed whenever promptTokens is set — the PR #514
        // behavior this feature depends on.
        // DISABLED (2026-08-18, lived defect): feeding promptTokens silenced the
        // decoder COMPLETELY — every dictation decoded to zero characters and
        // fell back to the Apple engine, for over a week, with no visible error.
        // Proven live by A/B: prompt off ⇒ Whisper transcribes normally; prompt
        // on ⇒ 0 chars, every time. Root cause in WhisperKit 0.18's prompt
        // handling is still to be isolated (see BACKLOG); until it is fixed and
        // WER-verified, no prompt is fed. Whisper without biasing beats Apple
        // with it — the accuracy floor comes first.
        // Dev switch (`defaults write com.voiceflow.dictation whisperPromptBiasingEnabled -bool YES`)
        // so the eventual fix can be A/B-tested live without a rebuild. Ships false.
        var promptWasFed = false
        if UserDefaults.standard.bool(forKey: "whisperPromptBiasingEnabled"),
           let tokenizer = wk.tokenizer,
           let prompt = Self.promptTokens(for: context, tokenizer: tokenizer) {
            options.promptTokens = prompt
            options.usePrefillPrompt = true
            promptWasFed = true
            // Terms come from the user's screen: count in the clear, contents private.
            Log.transcription.notice("Whisper context bias: \(context.orderedTerms.count, privacy: .public) terms, \(prompt.count, privacy: .public) tokens — \(context.promptText(), privacy: .private)")
        }

        let decodeStarted = Date()
        let results = try await wk.transcribe(audioArray: samples, decodeOptions: options)
        let decodeSeconds = Date().timeIntervalSince(decodeStarted)
        let text = results.map { $0.text }.joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Log.transcription.notice("WhisperKit transcribed \(text.count, privacy: .public) chars")
        guard !text.isEmpty else { throw VoiceFlowError.emptyTranscript }

        // Phantom-phrase suppression. Whisper's signature failure: short/quiet
        // clips decode to YouTube-outro phrases ("Thank you.", "Thank God.").
        // Confidence/energy thresholds proved too weak in live testing (2026-08-08:
        // both phrases shipped despite the corroboration filter), so the primary
        // defense is now a SECOND OPINION: when the whole output is a phantom-
        // family phrase, re-run the same recording through the Apple engine.
        // Apple emits nothing on silence (proven live on this machine), so:
        // words ⇒ user really spoke ⇒ deliver; nothing ⇒ discard the phantom.
        // This cannot eat real speech — a real "Thank you" passes the re-check.
        let clipSeconds = Double(samples.count) / 16_000.0
        let minLogProb = results.flatMap { $0.segments }.map { $0.avgLogprob }.min()
        // Suspicious = YouTube-outro boilerplate at ANY length (never deliberate
        // dictation), OR any tiny output from a short clip (live evidence
        // 2026-08-08: a 2s silent hold decoded to just "Thank" — not on any
        // list — which cleanup then completed to "Thank you."). Deliberate long
        // dictations of everyday phrases ("Thank you so much.") are NOT
        // arbitrated — a wrongful veto there would silently eat real speech.
        // Short real utterances ("yes", "okay send it") are safe: the arbiter
        // hears them and approves (proven live same day).
        let wordCount = text.split(whereSeparator: { $0 == " " }).count

        // Prompt echo: the decoder read our bias glossary back instead of the
        // audio. Handled BEFORE the phantom check because it has a different
        // remedy — the text isn't a stock hallucination to veto, it's our own
        // context leaking into the transcript, and it can be any length, so the
        // "short clip, few words" test below would never catch it. Delivering it
        // would both insert words the user never said and paste what was on their
        // screen into whatever they're typing.
        // The echo defense guards against the decoder reading the PROMPT back;
        // with no prompt fed there is nothing to echo, and running the check
        // anyway would spend an arbiter run on every vocabulary-dense sentence
        // for no protection. Re-enable together with the prompt.
        if promptWasFed, TranscriptSanity.looksLikePromptEcho(text: text, promptTerms: context.orderedTerms) {
            Log.transcription.error("Whisper echoed the context prompt — discarding the decode")
            let (echoVerdict, echoArbiterSeconds) = try await consultArbiterTimed(
                audio, languageCode: languageCode, context: context)
            switch echoVerdict {
            case .heard(let second):
                try? FileManager.default.removeItem(at: url)
                // The other engine had no prompt to echo, so it is the tiebreak.
                // Whisper's text stands ONLY if every word in it was independently
                // produced by that engine too — then nothing came from the
                // glossary and the echo test was a false alarm on a genuinely
                // vocabulary-dense sentence. Anything less is a partial echo: the
                // user says three of their terms and the decoder completes the
                // list, which is how "Payload CMS" gets inserted into a sentence
                // that never contained it.
                if TranscriptSanity.isFullyCorroborated(text, by: second) {
                    Log.transcription.notice("Echo suspicion cleared — every word was corroborated by the second engine")
                    return VoiceFlowCore.TranscriptionResult(
                        text: text, engineName: "whisper",
                        decodeSeconds: decodeSeconds, arbiterSeconds: echoArbiterSeconds)
                }
                Log.transcription.notice("Arbiter transcript used in place of the echoed decode")
                return VoiceFlowCore.TranscriptionResult(
                    text: second, engineName: "apple",
                    decodeSeconds: decodeSeconds, arbiterSeconds: echoArbiterSeconds)
            case .silence, .unavailable:
                // Silence ⇒ there was nothing to hear anyway. Unavailable ⇒ we
                // cannot verify, and a contaminated transcript must not be
                // delivered on faith; the capture file is left intact so the
                // Apple fallback re-runs it cleanly.
                throw VoiceFlowError.emptyTranscript
            }
        }

        let suspicious = TranscriptSanity.isOutroPhrase(text)
            || (clipSeconds <= 3.0 && wordCount <= 4)
        if suspicious {
            Log.transcription.notice("Whisper phantom candidate \"\(text, privacy: .public)\" (dur=\(clipSeconds, privacy: .public)s logProb=\(minLogProb ?? 0, privacy: .public) maxRMS=\(maxChunkRMS, privacy: .public)) — asking arbiter")
            var arbiterUnavailable = silenceArbiter == nil
            if silenceArbiter != nil {
                let (phantomVerdict, phantomArbiterSeconds) = try await consultArbiterTimed(
                    audio, languageCode: languageCode, context: context)
                switch phantomVerdict {
                case .heard(let second):
                    Log.transcription.notice("Arbiter heard speech — delivering Whisper text")
                    // The second opinion is already paid for; let it fix a name.
                    let merged = vote(primary: text, secondary: second, context: context)
                    // We still own the original capture (the arbiter only ever saw
                    // a copy), and this is the success path, so consume it here.
                    try? FileManager.default.removeItem(at: url)
                    return VoiceFlowCore.TranscriptionResult(
                        text: merged, engineName: "whisper",
                        decodeSeconds: decodeSeconds, arbiterSeconds: phantomArbiterSeconds)
                case .silence:
                    // The one verdict that means "silence": discard the phantom.
                    Log.transcription.notice("Arbiter heard nothing — phantom discarded")
                    throw VoiceFlowError.emptyTranscript
                case .unavailable:
                    // Infrastructure failure (model asset, file read, analyzer) is
                    // NOT a silence verdict — a real "Yes." must not be eaten
                    // because Apple's model was mid-download. Fall through to the
                    // signal-based filter instead.
                    arbiterUnavailable = true
                }
            }
            // No (working) arbiter: drop only with corroborating doubt signals.
            if arbiterUnavailable, TranscriptSanity.isLikelyHallucination(
                text: text, minAvgLogProb: minLogProb, nearSilence: maxChunkRMS < 0.01
            ) {
                throw VoiceFlowError.emptyTranscript
            }
        } else if silenceArbiter != nil,
                  DualEngineVoting.containsNearMiss(
                      text: text,
                      // The user's OWN vocabulary only — deliberately not the
                      // screen terms. Window chrome ("Report", "Meeting",
                      // "Monday") sits one edit from ordinary words, so including
                      // it fired the second engine on a large fraction of normal
                      // sentences (spending the second Phase 3 saved) and let a
                      // UI label overrule a correctly-heard word: "see you Sunday"
                      // → "see you Monday". Screen terms bias the decoder; they do
                      // not get a vote on the result.
                      vocabulary: context.vocabularyTerms,
                      // A decoder that was unsure gets the wider net.
                      maxEdits: (minLogProb ?? 0) < -0.55 ? 2 : 1
                  ) {
            // Phase 5 — word-level voting. Whisper produced something that is one
            // or two characters away from a term the user cares about, which is
            // what a misheard name looks like. Ask the other engine about the SAME
            // audio and take its word only where it matches the vocabulary and
            // Whisper's doesn't. Bounded on purpose: no near-miss, no second run,
            // so the ordinary dictation pays nothing.
            Log.transcription.notice("Vocabulary near-miss in Whisper output — asking the second engine")
            let (voteVerdict, voteArbiterSeconds) = try await consultArbiterTimed(
                audio, languageCode: languageCode, context: context)
            if case .heard(let second) = voteVerdict {
                let merged = vote(primary: text, secondary: second, context: context)
                try? FileManager.default.removeItem(at: url)
                return VoiceFlowCore.TranscriptionResult(
                    text: merged, engineName: "whisper",
                    decodeSeconds: decodeSeconds, arbiterSeconds: voteArbiterSeconds)
            }
            // Silence or unavailable: a near-miss is not a phantom signal, so the
            // Whisper text stands exactly as decoded.
        }
        // Success: the capture file is consumed here. On ANY failure above we leave
        // the file alone — the FallbackTranscriber re-runs the Apple engine, which
        // reads the same file via its internal URL.
        try? FileManager.default.removeItem(at: url)
        return VoiceFlowCore.TranscriptionResult(
            text: text, engineName: "whisper", decodeSeconds: decodeSeconds)
    }

    /// `consultArbiter` plus a stopwatch, so every call site reports how much the
    /// second opinion actually cost — the variable expense the latency data needs.
    private func consultArbiterTimed(
        _ audio: AudioCapture, languageCode: String, context: VoiceFlowCore.TranscriptionContext
    ) async throws -> (ArbiterVerdict, Double) {
        let started = Date()
        let verdict = try await consultArbiter(audio, languageCode: languageCode, context: context)
        return (verdict, Date().timeIntervalSince(started))
    }

    /// What the second engine made of the same recording.
    private enum ArbiterVerdict {
        case heard(String)
        case silence
        case unavailable
    }

    /// Run the Apple engine over a PRIVATE COPY of the same capture.
    ///
    /// The copy is the whole point. The Apple engine takes ownership of whatever
    /// capture it is given and deletes it — including when it throws afterwards
    /// (a failed model install). Handing it the original meant a second opinion
    /// that failed took the only recording with it, leaving the fallback engine
    /// nothing to read and swallowing real speech. The original now survives
    /// every arbiter outcome, and this method's caller decides when to delete it.
    private func consultArbiter(
        _ audio: AudioCapture, languageCode: String, context: VoiceFlowCore.TranscriptionContext
    ) async throws -> ArbiterVerdict {
        guard let arbiter = silenceArbiter else { return .unavailable }
        guard let source = audio.fileURL else { return .unavailable }
        let copyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-arbiter-\(UUID().uuidString).caf")
        do {
            try FileManager.default.copyItem(at: source, to: copyURL)
        } catch {
            Log.transcription.error("Could not copy capture for the arbiter (\(String(describing: error), privacy: .public))")
            return .unavailable
        }
        // Belt and braces: the arbiter deletes the copy itself, but a throw before
        // it gets that far must not leave a stray file behind.
        defer { try? FileManager.default.removeItem(at: copyURL) }
        let capture = AudioCapture(
            samples: audio.samples, sampleRate: audio.sampleRate,
            duration: audio.duration, fileURL: copyURL
        )
        do {
            let result = try await arbiter.transcribe(capture, languageCode: languageCode, context: context)
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .silence : .heard(trimmed)
        } catch VoiceFlowError.emptyTranscript {
            return .silence
        } catch is CancellationError {
            throw CancellationError()   // a cancelled dictation stays cancelled
        } catch {
            Log.transcription.error("Arbiter unavailable (\(String(describing: error), privacy: .public))")
            return .unavailable
        }
    }

    /// Apply word-level voting, logging any word that changed hands.
    private func vote(
        primary: String, secondary: String, context: VoiceFlowCore.TranscriptionContext
    ) -> String {
        // Vocabulary only, never screen terms — see the near-miss call site.
        let result = DualEngineVoting.reconcile(
            primary: primary, secondary: secondary, vocabulary: context.vocabularyTerms)
        guard result.changedAnything else { return primary }
        Log.transcription.notice("Dual-engine vote replaced \(result.substitutions.count, privacy: .public) word(s) with vocabulary-consistent alternatives")
        return result.text
    }
}
