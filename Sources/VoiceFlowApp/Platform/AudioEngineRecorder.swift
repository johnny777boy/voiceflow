import Foundation
import AVFoundation
import VoiceFlowCore

/// AVAudioEngine-backed microphone capture. Accumulates mono Float samples while
/// recording and returns them as an `AudioCapture`.
final class AudioEngineRecorder: AudioRecording, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var captureSampleRate: Double = 16_000
    private(set) var isRecording: Bool = false

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func startRecording() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        captureSampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let ptr = channel[0]
            self.lock.lock()
            self.samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: frames))
            self.lock.unlock()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceFlowError.audioEngineFailure(error.localizedDescription)
        }
        isRecording = true
        Log.audio.info("Recording started at \(self.captureSampleRate, privacy: .public) Hz")
    }

    func stopRecording() throws -> AudioCapture {
        guard isRecording else {
            return AudioCapture(samples: [], sampleRate: captureSampleRate, duration: 0)
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        lock.lock()
        let captured = samples
        lock.unlock()

        let duration = captureSampleRate > 0 ? Double(captured.count) / captureSampleRate : 0
        Log.audio.info("Recording stopped: \(captured.count, privacy: .public) samples")
        return AudioCapture(samples: captured, sampleRate: captureSampleRate, duration: duration)
    }
}
