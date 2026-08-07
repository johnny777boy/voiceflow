import Foundation

/// Captured audio ready to hand to a transcriber.
public struct AudioCapture: Sendable, Equatable {
    /// PCM samples (mono, normalized Float) — empty for engines that stream
    /// directly to the transcriber.
    public let samples: [Float]
    /// Sample rate in Hz.
    public let sampleRate: Double
    /// Total captured duration in seconds.
    public let duration: TimeInterval

    public init(samples: [Float], sampleRate: Double, duration: TimeInterval) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = duration
    }
}

/// Abstraction over microphone capture (AVAudioEngine in production).
public protocol AudioRecording: AnyObject, Sendable {
    /// Whether a recording is currently in progress.
    var isRecording: Bool { get }
    /// Begin capturing from the configured input device.
    func startRecording() throws
    /// Stop capturing and return what was recorded.
    func stopRecording() throws -> AudioCapture
    /// Request microphone authorization; returns whether granted.
    func requestPermission() async -> Bool
    /// Discard any capture buffered by the last `stopRecording()` that will NOT be
    /// transcribed (cancel / short-hold), releasing temp resources. Default: no-op.
    func discardPendingCapture()
}

public extension AudioRecording {
    func discardPendingCapture() {}
}
