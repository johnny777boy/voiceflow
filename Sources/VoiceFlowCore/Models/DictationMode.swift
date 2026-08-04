import Foundation

/// The transformation profile applied to a raw transcript before insertion.
///
/// Modes are ordered from least to most transformation. `raw` performs no
/// AI cleanup at all (only literal vocabulary substitution), while the others
/// apply progressively more formatting appropriate to the destination.
public enum DictationMode: String, Codable, CaseIterable, Sendable, Hashable {
    /// Insert the transcript essentially verbatim (vocabulary substitution only).
    case raw

    /// General prose cleanup: punctuation, capitalization, filler removal.
    case cleanWriting

    /// Formatting tuned for coding assistants / terminals (Claude Code, Codex).
    /// Preserves technical tokens, avoids "smart" punctuation, keeps commands literal.
    case claudeCode

    /// Email-appropriate cleanup: greetings/sign-offs left intact, polished prose.
    case email

    public var displayName: String {
        switch self {
        case .raw: return "Raw"
        case .cleanWriting: return "Clean Writing"
        case .claudeCode: return "Claude Code"
        case .email: return "Email"
        }
    }
}
