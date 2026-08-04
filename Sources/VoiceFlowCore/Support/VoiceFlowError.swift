import Foundation

/// Errors surfaced by the dictation pipeline. Most are recoverable and cause a
/// graceful degradation (e.g. copy-only insertion) rather than a hard failure.
public enum VoiceFlowError: Error, Equatable, Sendable {
    case microphonePermissionDenied
    case speechPermissionDenied
    case accessibilityPermissionDenied
    case audioEngineFailure(String)
    case transcriptionFailed(String)
    case emptyTranscript
    case destinationChanged
    case secureFieldBlocked
    case insertionFailed(String)
    case historyUnavailable(String)
    case keychainFailure(String)
    case cleanupProviderUnavailable

    public var isRecoverable: Bool {
        switch self {
        case .destinationChanged, .secureFieldBlocked, .insertionFailed, .cleanupProviderUnavailable:
            return true
        default:
            return false
        }
    }
}

extension VoiceFlowError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: return "Microphone permission was denied."
        case .speechPermissionDenied: return "Speech recognition permission was denied."
        case .accessibilityPermissionDenied: return "Accessibility permission is required to insert text."
        case .audioEngineFailure(let m): return "Audio engine error: \(m)"
        case .transcriptionFailed(let m): return "Transcription failed: \(m)"
        case .emptyTranscript: return "No speech was detected."
        case .destinationChanged: return "The destination changed; text was copied to the clipboard instead."
        case .secureFieldBlocked: return "Refused to insert into a secure (password) field."
        case .insertionFailed(let m): return "Insertion failed: \(m)"
        case .historyUnavailable(let m): return "History unavailable: \(m)"
        case .keychainFailure(let m): return "Keychain error: \(m)"
        case .cleanupProviderUnavailable: return "AI cleanup is unavailable; used built-in cleanup."
        }
    }
}
