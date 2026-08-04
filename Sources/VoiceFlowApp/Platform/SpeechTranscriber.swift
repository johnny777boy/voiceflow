import Foundation
import Speech
import AVFoundation
import VoiceFlowCore

/// Apple on-device speech recognition (SFSpeechRecognizer). Reconstructs a PCM
/// buffer from the captured samples and runs a buffer-based recognition request,
/// preferring on-device recognition for privacy.
final class SpeechTranscriber: Transcribing, @unchecked Sendable {
    /// Max time to wait for a final result after `endAudio()` before giving up.
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 20) { self.timeout = timeout }

    /// Ensures a continuation is resumed exactly once, even though the recognizer
    /// callback and the timeout fire on different queues.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func fire(_ body: () -> Void) {
            lock.lock(); let first = !done; done = true; lock.unlock()
            if first { body() }
        }
    }

    /// Sendable holder so the timeout closure can cancel the (non-Sendable)
    /// recognition task without capturing it directly.
    private final class TaskHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var task: SFSpeechRecognitionTask?
        func set(_ t: SFSpeechRecognitionTask) { lock.lock(); task = t; lock.unlock() }
        func cancel() { lock.lock(); let t = task; lock.unlock(); t?.cancel() }
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func transcribe(_ audio: AudioCapture, languageCode: String) async throws -> TranscriptionResult {
        guard !audio.samples.isEmpty else { throw VoiceFlowError.emptyTranscript }

        let locale = Locale(identifier: languageCode)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw VoiceFlowError.transcriptionFailed("speech recognizer unavailable for \(languageCode)")
        }

        guard let buffer = Self.makeBuffer(from: audio) else {
            throw VoiceFlowError.transcriptionFailed("could not build PCM buffer")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.append(buffer)
        request.endAudio()

        let once = ResumeOnce()
        let holder = TaskHolder()
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TranscriptionResult, Error>) in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    once.fire { continuation.resume(throwing: VoiceFlowError.transcriptionFailed(error.localizedDescription)) }
                    return
                }
                guard let result, result.isFinal else { return }
                let best = result.bestTranscription
                let confidence = best.segments.map { $0.confidence }.reduce(0, +)
                    / Float(max(1, best.segments.count))
                once.fire { continuation.resume(returning: TranscriptionResult(text: best.formattedString, confidence: confidence)) }
            }
            holder.set(task)
            // Watchdog: if the recognizer stalls after endAudio() and never
            // delivers a final result or an error, cancel it and fail cleanly.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.fire {
                    holder.cancel()
                    continuation.resume(throwing: VoiceFlowError.transcriptionFailed("recognition timed out after \(Int(timeout))s"))
                }
            }
        }
    }

    /// Build a 32-bit float mono PCM buffer from the captured samples.
    private static func makeBuffer(from audio: AudioCapture) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: audio.sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)),
              let channel = buffer.floatChannelData else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channel[0].update(from: base, count: src.count)
            }
        }
        return buffer
    }
}
