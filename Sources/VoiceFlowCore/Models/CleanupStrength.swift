import Foundation

/// How aggressively the cleanup pipeline rewrites the transcript.
public enum CleanupStrength: String, Codable, CaseIterable, Sendable, Hashable {
    /// No cleanup transformations at all.
    case off
    /// Minimal: whitespace + obvious duplicate spaces only.
    case light
    /// Default: filler removal, capitalization, sentence punctuation.
    case standard
    /// Maximum: standard plus sentence restructuring hints for the LLM stage.
    case aggressive

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .standard: return "Standard"
        case .aggressive: return "Aggressive"
        }
    }
}
