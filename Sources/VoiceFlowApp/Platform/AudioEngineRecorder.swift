import Foundation
import AVFoundation
import VoiceFlowCore

/// AVAudioEngine-backed microphone capture. Accumulates mono Float samples while
/// recording and returns them as an `AudioCapture`.
///
/// A fresh `AVAudioEngine` is created per recording to avoid stale HAL state
/// across start/stop cycles, and the tap tolerates both Float and Int16 buffers.
final class AudioEngineRecorder: AudioRecording, @unchecked Sendable {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var captureSampleRate: Double = 48_000
    private(set) var isRecording: Bool = false

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
    }

    func startRecording() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        Log.audio.notice("input format rate=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public)")

        guard format.channelCount > 0, format.sampleRate > 0 else {
            self.engine = nil
            throw VoiceFlowError.audioEngineFailure(
                "Microphone reported no input channels — check Microphone permission and your input device.")
        }
        captureSampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            self.lock.lock()
            if let ch = buffer.floatChannelData {
                self.samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: frames))
            } else if let ch16 = buffer.int16ChannelData {
                for i in 0..<frames { self.samples.append(Float(ch16[0][i]) / 32_768.0) }
            }
            self.lock.unlock()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            throw VoiceFlowError.audioEngineFailure(error.localizedDescription)
        }
        isRecording = true
        Log.audio.notice("recording started @ \(self.captureSampleRate, privacy: .public) Hz")
    }

    func stopRecording() throws -> AudioCapture {
        guard isRecording, let engine else {
            return AudioCapture(samples: [], sampleRate: captureSampleRate, duration: 0)
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isRecording = false

        lock.lock()
        let captured = samples
        lock.unlock()

        let duration = captureSampleRate > 0 ? Double(captured.count) / captureSampleRate : 0
        Log.audio.notice("recording stopped: \(captured.count, privacy: .public) samples, \(duration, privacy: .public)s")
        return AudioCapture(samples: captured, sampleRate: captureSampleRate, duration: duration)
    }
}
