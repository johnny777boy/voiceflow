import Foundation
import AVFoundation
import Speech
import VoiceFlowCore

/// Live streaming dictation: taps the microphone and feeds audio to
/// `SFSpeechRecognizer` **continuously while you speak**.
///
/// Apple's recognizer finalizes a segment after a natural pause (`isFinal`) and
/// then stops. If we did nothing, one hold that contains a pause would come back
/// as only the first sentence. So when a segment finalizes *while you're still
/// holding*, we fold it into an accumulated transcript and immediately start a
/// fresh segment — the whole hold becomes **one continuous script**.
///
/// One object conforms to both `AudioRecording` and `Transcribing` so the
/// `DictationController` flow is unchanged.
final class LiveSpeechDictation: AudioRecording, Transcribing, @unchecked Sendable {
    /// BCP-47 language for recognition; updated from settings.
    var preferredLanguage: String = "en-US"

    /// Live microphone level (0…1), called on the audio thread for the waveform UI.
    var levelHandler: (@Sendable (Float) -> Void)?

    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var accumulated = ""     // finalized segments, joined
    private var partial = ""         // current in-flight segment
    private var finished = false
    private var stopping = false
    private var failure: Error?
    private var sampleRate: Double = 48_000
    private(set) var isRecording = false

    // MARK: - Permissions (satisfies both protocols' requestPermission)

    func requestPermission() async -> Bool {
        let mic = await withCheckedContinuation { c in
            AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
        }
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        return mic && speech
    }

    // MARK: - AudioRecording

    /// Run AVAudioEngine lifecycle work on the main thread. `startRecording()` /
    /// `stopRecording()` are called from the `DictationController` actor (off-main);
    /// keeping engine setup/teardown on the main thread avoids driving AVFoundation
    /// state from an arbitrary cooperative-pool thread.
    private func onMain<T: Sendable>(_ body: @Sendable () throws -> T) throws -> T {
        if Thread.isMainThread { return try body() }
        let result = DispatchQueue.main.sync { Result(catching: body) }
        return try result.get()
    }

    func startRecording() throws { try onMain { try self.startRecordingImpl() } }

    private func startRecordingImpl() throws {
        lock.lock(); accumulated = ""; partial = ""; finished = false; stopping = false; failure = nil; lock.unlock()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: preferredLanguage)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw VoiceFlowError.transcriptionFailed("Speech recognizer unavailable for \(preferredLanguage).")
        }
        self.recognizer = recognizer

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        // Check hardware availability via the input format; tap with the output-bus format.
        let hardware = input.inputFormat(forBus: 0)
        Log.transcription.notice("live start: hw rate=\(hardware.sampleRate) ch=\(hardware.channelCount)")
        guard hardware.channelCount > 0, hardware.sampleRate > 0 else {
            self.engine = nil
            throw VoiceFlowError.audioEngineFailure("Microphone reported no input channels — check Microphone permission and input device.")
        }
        let tapFormat = input.outputFormat(forBus: 0)
        sampleRate = tapFormat.sampleRate

        startSegment()   // installs the first recognition task

        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)               // stream audio to the recognizer live
            if let h = self.levelHandler { h(Self.level(of: buffer)) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            task?.cancel(); task = nil; request?.endAudio(); self.request = nil; self.engine = nil
            throw VoiceFlowError.audioEngineFailure(error.localizedDescription)
        }
        isRecording = true
    }

    func stopRecording() throws -> AudioCapture { try onMain { try self.stopRecordingImpl() } }

    private func stopRecordingImpl() throws -> AudioCapture {
        guard isRecording else { return AudioCapture(samples: [], sampleRate: sampleRate, duration: 0) }
        lock.lock(); stopping = true; lock.unlock()   // mark terminal BEFORE endAudio
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        request?.endAudio()          // signal end; the final result arrives shortly after
        isRecording = false
        levelHandler?(0)
        // Transcription is produced live; the capture buffer isn't used here.
        return AudioCapture(samples: [], sampleRate: sampleRate, duration: 0)
    }

    // MARK: - Segment management

    /// When true, force Apple's on-device recognizer (private, offline, but less
    /// accurate). When false (default), allow Apple's server model when online —
    /// materially better word accuracy, closer to Wispr.
    var forceOnDevice = false

    private func newRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.taskHint = .dictation
        r.addsPunctuation = true   // periods, commas, question marks from the recognizer
        // Only force on-device if explicitly requested; otherwise let the system
        // use the more accurate server model when a network is available.
        if forceOnDevice, recognizer?.supportsOnDeviceRecognition == true {
            r.requiresOnDeviceRecognition = true
        }
        if !contextualStrings.isEmpty { r.contextualStrings = contextualStrings }
        return r
    }

    /// Names / jargon to bias recognition toward (from the user's vocabulary).
    var contextualStrings: [String] = []

    private func startSegment() {
        guard let recognizer else { return }
        let request = newRequest()
        self.request = request
        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognition(result, error)
        }
    }

    private func handleRecognition(_ result: SFSpeechRecognitionResult?, _ error: Error?) {
        var restart = false
        lock.lock()
        if let result {
            partial = result.bestTranscription.formattedString
            if result.isFinal {
                let seg = partial.trimmingCharacters(in: .whitespacesAndNewlines)
                if !seg.isEmpty { accumulated = accumulated.isEmpty ? seg : accumulated + " " + seg }
                partial = ""
                if stopping {
                    finished = true         // this was the last segment
                } else {
                    restart = true          // a pause mid-hold — keep the dictation going
                }
            }
        }
        if let error {
            // Return whatever we already have; only surface an error if nothing was heard.
            if accumulated.isEmpty && partial.isEmpty { failure = error }
            finished = true
        }
        lock.unlock()

        if restart {
            if Thread.isMainThread { startSegment() }
            else { DispatchQueue.main.async { [weak self] in self?.startSegment() } }
        }
    }

    /// RMS level of a PCM buffer mapped to roughly 0…1 for the waveform.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        let data = ch[0]
        var sum: Float = 0
        for i in 0..<n { let s = data[i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        return min(1, rms * 14)   // gain so normal speech fills the bars
    }

    // MARK: - Transcribing

    /// Synchronous locked snapshot, so the async `transcribe` never touches the
    /// lock across a suspension point (which Swift 6 forbids).
    private func snapshot() -> (done: Bool, text: String, err: Error?) {
        lock.lock(); defer { lock.unlock() }
        let combined = [accumulated, partial]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return (finished, combined, failure)
    }

    func transcribe(_ audio: AudioCapture, languageCode: String) async throws -> TranscriptionResult {
        // Wait for the recognizer to finalize the last segment, then return the
        // accumulated text. A grace period bounds the wait.
        let deadline = Date().addingTimeInterval(15)
        while true {
            let (done, text, err) = snapshot()

            if done {
                task = nil; request = nil
                if !text.isEmpty { return TranscriptionResult(text: text) }
                if let err { throw VoiceFlowError.transcriptionFailed((err as NSError).localizedDescription) }
                throw VoiceFlowError.emptyTranscript
            }

            if Date() > deadline {
                task?.finish(); task = nil; request = nil
                if !text.isEmpty { return TranscriptionResult(text: text) }
                throw VoiceFlowError.emptyTranscript
            }

            try? await Task.sleep(nanoseconds: 80_000_000)   // poll every 80 ms
        }
    }
}
