import Foundation

/// A spoken-form → written-form substitution applied during cleanup.
///
/// Example: spoken `"payload CMS"` → written `"Payload CMS"`, or
/// spoken `"next js"` → written `"Next.js"`.
public struct VocabularyEntry: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    /// The phrase as the transcriber is likely to render it (matched case-insensitively
    /// unless `caseSensitive` is set).
    public var spoken: String
    /// The exact replacement text.
    public var written: String
    /// When true, `spoken` must match case exactly.
    public var caseSensitive: Bool
    /// When false, this entry is ignored by the replacer.
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        spoken: String,
        written: String,
        caseSensitive: Bool = false,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.spoken = spoken
        self.written = written
        self.caseSensitive = caseSensitive
        self.isEnabled = isEnabled
    }
}

public extension VocabularyEntry {
    /// The default technical vocabulary shipped with the app (from the spec).
    static let defaults: [VocabularyEntry] = [
        VocabularyEntry(spoken: "payload CMS", written: "Payload CMS"),
        VocabularyEntry(spoken: "payload cms", written: "Payload CMS"),
        VocabularyEntry(spoken: "next js", written: "Next.js"),
        VocabularyEntry(spoken: "nextjs", written: "Next.js"),
        VocabularyEntry(spoken: "postgres", written: "PostgreSQL"),
        VocabularyEntry(spoken: "postgresql", written: "PostgreSQL"),
        VocabularyEntry(spoken: "claude code", written: "Claude Code"),
        VocabularyEntry(spoken: "codex", written: "Codex"),
        VocabularyEntry(spoken: "type script", written: "TypeScript"),
        VocabularyEntry(spoken: "java script", written: "JavaScript"),
        VocabularyEntry(spoken: "git hub", written: "GitHub"),
        VocabularyEntry(spoken: "vs code", written: "VS Code")
    ]
}
