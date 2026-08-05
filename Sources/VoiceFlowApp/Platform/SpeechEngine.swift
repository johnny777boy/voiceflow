import Foundation
import VoiceFlowCore

/// A dictation engine that both captures audio and turns it into text. Two
/// implementations exist: `SpeechAnalyzerDictation` (macOS 26 — Apple's modern,
/// high-accuracy batch engine) and `LiveSpeechDictation` (legacy streaming
/// fallback). The coordinator picks the best available at launch.
protocol SpeechEngine: AudioRecording, Transcribing, AnyObject {
    var preferredLanguage: String { get set }
    var levelHandler: (@Sendable (Float) -> Void)? { get set }
    var contextualStrings: [String] { get set }
}
