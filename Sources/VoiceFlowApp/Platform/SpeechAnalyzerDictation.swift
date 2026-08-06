import Foundation
import AVFoundation
import Speech
import VoiceFlowCore

/// macOS 26 dictation engine built on Apple's **SpeechAnalyzer / SpeechTranscriber**
/// — the modern on-device model that benchmarks more accurately than Whisper on
/// English and ~4× better than the legacy `SFSpeechRecognizer`.
///
/// Flow (matches Wispr): record the whole utterance to a temporary file while the
/// key is held, then on release hand Apple the complete file and transcribe it
/// **with full context** so homophones resolve ("pill", not "peel"). Recording to a
/// file lets the framework do its own high-quality resampling — no lossy per-buffer
/// conversion on our side.
@available(macOS 26.0, *)
final class SpeechAnalyzerDictation: SpeechEngine, @unchecked Sendable {
    var preferredLanguage: String = "en-US"
    var levelHandler: (@Sendable (Float) -> Void)?
    var contextualStrings: [String] = []

    private var engine: AVAudioEngine?           // long-lived, kept warm
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var fileURL: URL?
    private var tapFormat: AVAudioFormat?
    private var recording = false                // whether the tap writes to the file
    private var preroll: [AVAudioPCMBuffer] = []  // ~0.5s ring buffer captured BEFORE keypress
    private var prerollFrameLimit: AVAudioFrameCount = 24_000
    private(set) var isRecording = false

    static func isSupported(language: String) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) != nil
    }

    func requestPermission() async -> Bool {
        let mic = await withCheckedContinuation { c in
            AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
        }
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        return mic && speech
    }

    // MARK: - Capture (AudioRecording)

    private func onMain<T: Sendable>(_ body: @Sendable () throws -> T) throws -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync { Result(catching: body) }.get()
    }

    /// Start the mic engine and keep it WARM with a permanent tap that continuously
    /// fills a short pre-roll ring buffer. Idempotent. Call at app launch so the mic
    /// is already listening when the user presses the key — this is what stops the
    /// first word ("So how come…") from being clipped by mic warm-up.
    func prewarm() { try? onMain { try self.startEngineIfNeeded() } }

    private func startEngineIfNeeded() throws {
        if engine != nil { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hw = input.inputFormat(forBus: 0)
        guard hw.channelCount > 0, hw.sampleRate > 0 else {
            throw VoiceFlowError.audioEngineFailure("Microphone reported no input — check Microphone permission.")
        }
        let fmt = input.outputFormat(forBus: 0)
        self.tapFormat = fmt
        self.prerollFrameLimit = AVAudioFrameCount(max(8_000, fmt.sampleRate * 0.5))  // ~0.5s
        Log.transcription.notice("SA engine warm: rate=\(fmt.sampleRate) ch=\(fmt.channelCount)")
        // Diagnose the "bad transcript" class that's usually environmental: a
        // Bluetooth/headset mic runs at ≤16 kHz and materially hurts accuracy.
        if fmt.sampleRate <= 16_000 {
            Log.transcription.notice("SA WARNING: low input rate \(fmt.sampleRate) Hz — a Bluetooth/headset mic degrades accuracy; prefer the built-in mic.")
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Runs on the audio render thread. While recording, write live to the file.
    /// While idle, keep the most recent ~0.5s in the ring buffer as pre-roll.
    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if recording {
            try? audioFile?.write(from: buffer)
        } else if let copy = Self.copy(buffer) {
            preroll.append(copy)
            var total: AVAudioFrameCount = preroll.reduce(0) { $0 + $1.frameLength }
            while total > prerollFrameLimit, preroll.count > 1 {
                total -= preroll.removeFirst().frameLength
            }
        }
        lock.unlock()
        if let h = levelHandler { h(Self.level(of: buffer)) }
    }

    func startRecording() throws { try onMain { try self.startRecordingImpl() } }

    private func startRecordingImpl() throws {
        try startEngineIfNeeded()   // warm already, unless this is the very first use
        guard let fmt = tapFormat else {
            throw VoiceFlowError.audioEngineFailure("Audio not ready.")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-\(UUID().uuidString).caf")
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        } catch {
            throw VoiceFlowError.audioEngineFailure("Could not open capture file: \(error.localizedDescription)")
        }
        lock.lock()
        self.audioFile = file
        self.fileURL = url
        // Write the pre-roll (the ~0.5s captured just BEFORE the keypress) first, so
        // the opening word is already in the file. Then go live.
        for buf in preroll { try? file.write(from: buf) }
        preroll.removeAll(keepingCapacity: true)
        recording = true
        lock.unlock()
        isRecording = true
    }

    func stopRecording() throws -> AudioCapture { try onMain { try self.stopRecordingImpl() } }

    private func stopRecordingImpl() throws -> AudioCapture {
        guard isRecording else { return AudioCapture(samples: [], sampleRate: 16_000, duration: 0) }
        isRecording = false
        // Drain: keep writing for a beat so the trailing audio (the last word) is
        // captured before we stop writing. The engine stays WARM for next time.
        Thread.sleep(forTimeInterval: 0.18)
        lock.lock()
        recording = false
        let file = audioFile
        audioFile = nil        // releasing the AVAudioFile flushes + closes it
        lock.unlock()
        _ = file
        levelHandler?(0)
        return AudioCapture(samples: [], sampleRate: 16_000, duration: 0)
    }

    // MARK: - Transcription (Transcribing)

    private func takeFileURL() -> URL? {
        lock.lock(); defer { lock.unlock() }
        let u = fileURL; fileURL = nil; return u
    }

    func transcribe(_ audio: AudioCapture, languageCode: String) async throws -> TranscriptionResult {
        guard let url = takeFileURL() else { throw VoiceFlowError.emptyTranscript }
        defer { try? FileManager.default.removeItem(at: url) }

        // Resolve to a locale the recognizer actually supports (region-aware), from
        // the requested language code (falling back to the preferred language).
        let requested = Locale(identifier: languageCode.isEmpty ? preferredLanguage : languageCode)
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) ?? requested
        try await Self.ensureModelInstalled(locale: locale)

        // No volatile/interim results — we only want stable, FINAL segments for a
        // recorded file. Mixing in volatile guesses is what made output garbled and
        // inconsistent ("sometimes works, sometimes doesn't").
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.alternativeTranscriptions],  // populate n-best; still NO volatile
            attributeOptions: [.transcriptionConfidence]     // per-run confidence for re-ranking
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Bias recognition toward the user's names/terms/jargon. This was declared
        // but silently dropped — the single highest-value accuracy fix.
        let terms = contextualStrings
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: terms]
            try? await analyzer.setContext(context)
        }
        let vocab = Self.vocabTokens(from: terms)

        // Start consuming results BEFORE feeding audio so no early segment is lost.
        // Accumulate only final segments, in time order, joined with single spaces.
        // Each segment keeps the model's top-1 UNLESS an alternative contains strictly
        // more of the user's vocabulary (fixes homophones/jargon; never degrades
        // general text, where all candidates tie at 0 vocab hits).
        let resultsTask = Task { () throws -> String in
            var pieces: [String] = []
            for try await result in transcriber.results where result.isFinal {
                let best = Self.bestCandidate(result, vocab: vocab)
                let piece = best.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { pieces.append(piece) }
            }
            return pieces.joined(separator: " ")
        }

        let audioFile = try AVAudioFile(forReading: url)
        if let lastTime = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalize(through: lastTime)
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let text = try await resultsTask.value
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.transcription.notice("SA transcribed \(trimmed.count, privacy: .public) chars")
        guard !trimmed.isEmpty else { throw VoiceFlowError.emptyTranscript }
        return TranscriptionResult(text: trimmed)
    }

    // MARK: - Model asset

    private static func ensureModelInstalled(locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales
        // Region-aware: en-US must not be considered satisfied by an installed en-GB.
        if installed.contains(where: { $0.identifier == locale.identifier }) { return }
        _ = try? await AssetInventory.reserve(locale: locale)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.transcription.notice("SA: downloading speech model for \(locale.identifier, privacy: .public)")
            try await request.downloadAndInstall()
        }
    }

    // MARK: - Level metering

    // MARK: - Vocabulary-aware re-ranking of the n-best list

    private static func vocabTokens(from terms: [String]) -> Set<String> {
        var set = Set<String>()
        for t in terms {
            for w in t.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where w.count > 1 {
                set.insert(String(w))
            }
        }
        return set
    }

    /// Start from the model's top-1 and only switch to an alternative that contains
    /// STRICTLY more of the user's vocabulary (ties broken by higher confidence). When
    /// all candidates tie at 0 vocab hits (the common case) top-1 is kept unchanged.
    private static func bestCandidate(_ result: SpeechTranscriber.Result, vocab: Set<String>) -> String {
        let top = result.text
        guard !vocab.isEmpty, !result.alternatives.isEmpty else { return String(top.characters) }
        func vocabHits(_ s: AttributedString) -> Int {
            var hits = 0
            for w in String(s.characters).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            where vocab.contains(String(w)) { hits += 1 }
            return hits
        }
        func avgConfidence(_ s: AttributedString) -> Double {
            var sum = 0.0, n = 0.0
            for run in s.runs { if let c = run.transcriptionConfidence { sum += Double(c); n += 1 } }
            return n > 0 ? sum / n : 0
        }
        let topHits = vocabHits(top)
        var bestText = top, bestHits = topHits, bestConf = avgConfidence(top)
        for alt in result.alternatives {
            let h = vocabHits(alt)
            if h > bestHits || (h == bestHits && h > topHits && avgConfidence(alt) > bestConf) {
                bestText = alt; bestHits = h; bestConf = avgConfidence(alt)
            }
        }
        return String(bestText.characters)
    }

    /// Deep-copy a tap buffer (the tap reuses its buffer) for the pre-roll ring.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let dst = out.floatChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size) }
            return out
        }
        if let src = buffer.int16ChannelData, let dst = out.int16ChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Int16>.size) }
            return out
        }
        return nil
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength); guard n > 0 else { return 0 }
        let data = ch[0]; var sum: Float = 0
        for i in 0..<n { let s = data[i]; sum += s * s }
        return min(1, (sum / Float(n)).squareRoot() * 14)
    }
}
