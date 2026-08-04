import Foundation
import Speech
import AVFoundation
import VoiceFlowCore

/// Apple on-device speech recognition (SFSpeechRecognizer). Reconstructs a PCM
/// buffer from the captured samples and runs a buffer-based recognition request,
/// preferring on-device recognition for privacy.
final class SpeechTranscriber: Transcribing, @unchecked Sendable {

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

        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                if finished { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: VoiceFlowError.transcriptionFailed(error.localizedDescription))
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    finished = true
                    let best = result.bestTranscription
                    let confidence = best.segments.map { $0.confidence }.reduce(0, +)
                        / Float(max(1, best.segments.count))
                    continuation.resume(returning: TranscriptionResult(text: best.formattedString, confidence: confidence))
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
