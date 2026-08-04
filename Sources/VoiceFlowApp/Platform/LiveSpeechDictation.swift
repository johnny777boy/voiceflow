import Foundation
import AVFoundation
import Speech
import VoiceFlowCore

/// Live streaming dictation: taps the microphone and feeds audio to
/// `SFSpeechRecognizer` **continuously while you speak**, accumulating partial
/// results. This captures full-length dictation (paragraphs), unlike a one-shot
/// transcribe-at-the-end approach which truncates long speech.
///
/// One object conforms to both `AudioRecording` and `Transcribing` so the
/// `DictationController` flow is unchanged: `startRecording()` begins live
/// recognition, `stopRecording()` ends the audio, and `transcribe(_:)` returns
/// the accumulated final text.
final class LiveSpeechDictation: AudioRecording, Transcribing, @unchecked Sendable {
    /// BCP-47 language for recognition; updated from settings.
    var preferredLanguage: String = "en-US"

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var transcript = ""
    private var finished = false
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

    func startRecording() throws {
        lock.lock(); transcript = ""; finished = false; failure = nil; lock.unlock()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: preferredLanguage)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw VoiceFlowError.transcriptionFailed("Speech recognizer unavailable for \(preferredLanguage).")
        }

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        Log.transcription.notice("live start: rate=\(format.sampleRate) ch=\(format.channelCount)")
        guard format.channelCount > 0, format.sampleRate > 0 else {
            self.engine = nil
            throw VoiceFlowError.audioEngineFailure("Microphone reported no input channels — check Microphone permission and input device.")
        }
        sampleRate = format.sampleRate

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock()
            if let result {
                self.transcript = result.bestTranscription.formattedString
                if result.isFinal { self.finished = true }
            }
            if let error {
                self.failure = error
                self.finished = true
            }
            self.lock.unlock()
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)   // stream audio to the recognizer live
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            task?.cancel(); task = nil; request.endAudio(); self.request = nil; self.engine = nil
            throw VoiceFlowError.audioEngineFailure(error.localizedDescription)
        }
        isRecording = true
    }

    func stopRecording() throws -> AudioCapture {
        guard isRecording else { return AudioCapture(samples: [], sampleRate: sampleRate, duration: 0) }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        request?.endAudio()          // signal end; the final result arrives shortly after
        isRecording = false
        // Transcription is produced live; the capture buffer isn't used here.
        return AudioCapture(samples: [], sampleRate: sampleRate, duration: 0)
    }

    // MARK: - Transcribing

    /// Synchronous locked snapshot, so the async `transcribe` never touches the
    /// lock across a suspension point (which Swift 6 forbids).
    private func snapshot() -> (done: Bool, text: String, err: Error?) {
        lock.lock(); defer { lock.unlock() }
        return (finished, transcript, failure)
    }

    func transcribe(_ audio: AudioCapture, languageCode: String) async throws -> TranscriptionResult {
        // Wait for the recognizer to finalize (it has been processing live), then
        // return the accumulated text. A grace period bounds the wait; whatever
        // text we have is returned rather than hanging.
        let deadline = Date().addingTimeInterval(15)
        while true {
            let (done, text, err) = snapshot()

            if done {
                task = nil; request = nil
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return TranscriptionResult(text: trimmed) }
                if let err { throw VoiceFlowError.transcriptionFailed((err as NSError).localizedDescription) }
                throw VoiceFlowError.emptyTranscript
            }

            if Date() > deadline {
                task?.finish(); task = nil; request = nil
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return TranscriptionResult(text: trimmed) }
                throw VoiceFlowError.emptyTranscript
            }

            try? await Task.sleep(nanoseconds: 80_000_000)   // poll every 80 ms
        }
    }
}
