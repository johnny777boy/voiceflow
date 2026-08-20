import Foundation

/// The deterministic, offline cleanup engine. It is the always-available default
/// and the base layer beneath the optional LLM stage. Being pure and rule-driven,
/// it is fully unit-testable and never depends on a network or secret.
public struct RuleBasedCleanup: CleanupProviding {
    public init() {}

    public func clean(_ rawText: String, context: CleanupContext) async throws -> String {
        cleanSync(rawText, context: context)
    }

    /// Synchronous entry point (the engine does no async work; exposed for tests
    /// and for callers that want the deterministic result directly).
    public func cleanSync(_ rawText: String, context: CleanupContext) -> String {
        // Raw mode / cleanup-off are a TRUE verbatim path: whitespace tidy only.
        // Vocabulary substitution must NOT run here — it rewrites words the user
        // actually spoke ("postgres" → "PostgreSQL"), which corrupts both the
        // verbatim promise and any WER benchmark run in Raw mode.
        if context.strength == .off || context.mode == .raw {
            return TextNormalizer.normalizeWhitespace(rawText)
        }

        // Stutters are deterministic and unit-tested, but they DELETE a word, so
        // they run only once the verbatim path above has returned. They used to
        // run before it, which meant Raw mode — the mode a WER benchmark uses,
        // and the mode that promises not one word changed — silently dropped
        // repeats.
        let rawText = TextNormalizer.collapseStutters(rawText)

        // 1. Vocabulary substitution (user's spoken→written mappings).
        let replacer = VocabularyReplacer(entries: context.vocabulary)
        var text = replacer.apply(to: rawText)

        // 2. Whitespace normalization always runs.
        text = TextNormalizer.normalizeWhitespace(text)

        switch context.mode {
        case .raw:
            return text // unreachable (handled above)
        case .claudeCode:
            text = cleanForCode(text, strength: context.strength)
        case .cleanWriting:
            text = cleanForProse(text, strength: context.strength, preserveLineBreaks: false,
                                 spokenPunctuation: context.spokenPunctuationEnabled)
        case .email:
            text = cleanForProse(text, strength: context.strength, preserveLineBreaks: true,
                                 spokenPunctuation: context.spokenPunctuationEnabled)
        }
        return text
    }

    // MARK: - Mode-specific rules

    /// Code / terminal mode: keep tokens literal. No spoken-punctuation symbols,
    /// no forced capitalization, no trailing period (would break commands).
    private func cleanForCode(_ input: String, strength: CleanupStrength) -> String {
        var text = input
        if strength == .standard || strength == .aggressive {
            text = TextNormalizer.removeFillers(text)
        }
        return TextNormalizer.normalizeWhitespace(text)
    }

    /// Prose / email mode: spoken punctuation, filler removal, capitalization,
    /// terminal punctuation.
    private func cleanForProse(_ input: String, strength: CleanupStrength, preserveLineBreaks: Bool,
                               spokenPunctuation: Bool) -> String {
        var text = input

        if strength == .standard || strength == .aggressive {
            // Spoken-punctuation conversion is OPT-IN: unconditional word→symbol
            // mapping destroys ordinary nouns ("during that period we met" →
            // "during that. we met"), which reads exactly like an ASR error.
            if spokenPunctuation {
                text = TextNormalizer.applySpokenPunctuation(text)
            }
            text = TextNormalizer.removeFillers(text)
        }

        // Capitalization applies at light and above.
        text = TextNormalizer.capitalizeSentences(text)

        if strength == .standard || strength == .aggressive {
            text = TextNormalizer.ensureTerminalPunctuation(text)
        }

        if preserveLineBreaks {
            return text
        }
        // Non-email prose collapses stray newlines into spaces.
        let joined = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return TextNormalizer.normalizeWhitespace(joined)
    }
}
