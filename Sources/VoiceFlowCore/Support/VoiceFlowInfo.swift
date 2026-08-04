import Foundation

/// Static app metadata.
public enum VoiceFlowInfo {
    public static let version = "1.0.0"
    public static let bundleIdentifier = "com.voiceflow.dictation"
    public static let displayName = "VoiceFlow"

    /// Default model for the optional LLM cleanup stage. A fast model is chosen
    /// because dictation cleanup is latency-sensitive; configurable per install.
    public static let defaultCleanupModel = "claude-haiku-4-5"
}
