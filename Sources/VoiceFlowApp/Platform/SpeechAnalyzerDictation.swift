import Foundation
import AVFoundation
import Speech
import VoiceFlowCore

/// macOS 26 dictation engine built on Apple's **SpeechAnalyzer / SpeechTranscriber**
/// — the modern on-device model that benchmarks more accurately than Whisper on
/// English and ~4× better than the legacy `SFSpeechRecognizer`.
///
/// Flow (matches Wispr): capture the whole utterance while the key is held, then on
/// release analyze the complete audio **with full context** so homophones resolve
/// ("pill", not "peel"). Nothing is transcribed live, so there's no boundary
/// guessing and no pause-stitching audio loss.
@available(macOS 26.0, *)
final class SpeechAnalyzerDictation: SpeechEngine, @unchecked Sendable {
    var preferredLanguage: String = "en-US"
    var levelHandler: (@Sendable (Float) -> Void)?
    var contextualStrings: [String] = []

    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var captured: [AVAudioPCMBuffer] = []
    private var captureFormat: AVAudioFormat?
    private(set) var isRecording = false

    /// Whether this engine can run for the given language on this Mac.
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
        lock.lock(); captured.removeAll(keepingCapacity: true); lock.unlock()

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
        captureFormat = tapFormat

        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if let copy = Self.copy(buffer) {
                self.lock.lock(); self.captured.append(copy); self.lock.unlock()
            }
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
        isRecording = false
        levelHandler?(0)
        // Audio is held internally as buffers; transcribe() consumes them.
        return AudioCapture(samples: [], sampleRate: captureFormat?.sampleRate ?? 16_000, duration: 0)
    }

    // MARK: - Transcription (Transcribing)

    /// Synchronously take (and clear) the captured buffers — avoids holding an
    /// NSLock across an await in `transcribe`.
    private func takeCapturedBuffers() -> [AVAudioPCMBuffer] {
        lock.lock(); defer { lock.unlock() }
        let b = captured; captured.removeAll(keepingCapacity: true); return b
    }

    func transcribe(_ audio: AudioCapture, languageCode: String) async throws -> TranscriptionResult {
        let buffers = takeCapturedBuffers()
        guard !buffers.isEmpty else { throw VoiceFlowError.emptyTranscript }

        let locale = Locale(identifier: preferredLanguage)
        try await Self.ensureModelInstalled(locale: locale)

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceFlowError.transcriptionFailed("No compatible audio format for the transcriber.")
        }

        // Collect results concurrently while we feed audio.
        let resultsTask = Task { () throws -> String in
            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
            }
            return text
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)

        let converter = (buffers.first?.format).flatMap { AVAudioConverter(from: $0, to: analyzerFormat) }
        for buffer in buffers {
            let toFeed: AVAudioPCMBuffer
            if buffer.format == analyzerFormat {
                toFeed = buffer
            } else if let converter, let converted = Self.convert(buffer, using: converter, to: analyzerFormat) {
                toFeed = converted
            } else {
                continue
            }
            continuation.yield(AnalyzerInput(buffer: toFeed))
        }
        continuation.finish()

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await resultsTask.value
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceFlowError.emptyTranscript }
        return TranscriptionResult(text: trimmed)
    }

    // MARK: - Model asset

    /// Ensure the on-device model for `locale` is installed (one-time download).
    private static func ensureModelInstalled(locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let want = locale.language.languageCode
        if installed.contains(where: { $0.language.languageCode == want }) { return }
        _ = try? await AssetInventory.reserve(locale: locale)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.transcription.notice("SA: downloading speech model for \(locale.identifier, privacy: .public)")
            try await request.downloadAndInstall()
        }
    }

    // MARK: - Audio helpers

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

    /// Hands a single input buffer to the converter, then reports "no more data".
    /// A Sendable class avoids capturing a non-Sendable buffer / mutable var in the
    /// converter's @Sendable input block.
    private final class OneShotInput: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ b: AVAudioPCMBuffer) { buffer = b }
        func take() -> AVAudioPCMBuffer? { let b = buffer; buffer = nil; return b }
    }

    private static func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let source = OneShotInput(input)
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if let b = source.take() { status.pointee = .haveData; return b }
            status.pointee = .noDataNow; return nil
        }
        return error == nil ? out : nil
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength); guard n > 0 else { return 0 }
        let data = ch[0]; var sum: Float = 0
        for i in 0..<n { let s = data[i]; sum += s * s }
        return min(1, (sum / Float(n)).squareRoot() * 14)
    }
}
