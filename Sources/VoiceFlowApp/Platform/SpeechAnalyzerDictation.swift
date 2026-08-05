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

    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var fileURL: URL?
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

    func startRecording() throws { try onMain { try self.startRecordingImpl() } }

    private func startRecordingImpl() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let hw = input.inputFormat(forBus: 0)
        Log.transcription.notice("SA capture start: hw rate=\(hw.sampleRate) ch=\(hw.channelCount)")
        guard hw.channelCount > 0, hw.sampleRate > 0 else {
            self.engine = nil
            throw VoiceFlowError.audioEngineFailure("Microphone reported no input — check Microphone permission.")
        }
        let tapFormat = input.outputFormat(forBus: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-\(UUID().uuidString).caf")
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: tapFormat.settings)
        } catch {
            self.engine = nil
            throw VoiceFlowError.audioEngineFailure("Could not open capture file: \(error.localizedDescription)")
        }
        lock.lock(); self.audioFile = file; self.fileURL = url; lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock(); try? self.audioFile?.write(from: buffer); self.lock.unlock()
            if let h = self.levelHandler { h(Self.level(of: buffer)) }
        }

        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0); self.engine = nil
            throw VoiceFlowError.audioEngineFailure(error.localizedDescription)
        }
        isRecording = true
    }

    func stopRecording() throws -> AudioCapture { try onMain { try self.stopRecordingImpl() } }

    private func stopRecordingImpl() throws -> AudioCapture {
        guard isRecording else { return AudioCapture(samples: [], sampleRate: 16_000, duration: 0) }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        lock.lock(); self.audioFile = nil; lock.unlock()   // closes/flushes the file
        isRecording = false
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
            reportingOptions: [],
            attributeOptions: []
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

        // Start consuming results BEFORE feeding audio so no early segment is lost.
        // Accumulate only final segments, in time order, joined with single spaces.
        let resultsTask = Task { () throws -> String in
            var pieces: [String] = []
            for try await result in transcriber.results where result.isFinal {
                let piece = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength); guard n > 0 else { return 0 }
        let data = ch[0]; var sum: Float = 0
        for i in 0..<n { let s = data[i]; sum += s * s }
        return min(1, (sum / Float(n)).squareRoot() * 14)
    }
}
