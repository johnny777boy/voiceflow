import Foundation

/// Deterministic, dependency-free text transforms shared by the rule-based
/// cleanup stage. Each function is pure and independently testable.
public enum TextNormalizer {

    /// Common spoken filler words removed during standard/aggressive cleanup.
    ///
    /// Deliberately limited to hesitation sounds and unambiguous multi-word
    /// hedges. Words like "like", "actually", "literally", "basically",
    /// "sort of", and "kind of" are intentionally NOT here — they are frequently
    /// meaningful ("I like it", "kind of blue"), and removing them would silently
    /// change the speaker's meaning.
    public static let fillerWords: Set<String> = [
        "um", "uh", "uhh", "umm", "uhm", "er", "err", "erm", "ah", "hmm", "mhm",
        "you know", "i mean"
    ]

    /// Collapse runs of whitespace to single spaces and trim ends. Newlines are
    /// preserved (collapsed to single `\n`).
    public static func normalizeWhitespace(_ text: String) -> String {
        // Normalize spaces/tabs but keep newlines meaningful.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let collapsed = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            return collapsed
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove standalone filler words (word-boundary aware, case-insensitive).
    public static func removeFillers(_ text: String) -> String {
        var result = text
        // Multi-word fillers first.
        let phrases = fillerWords.filter { $0.contains(" ") }
        let singles = fillerWords.filter { !$0.contains(" ") }
        for phrase in phrases.sorted(by: { $0.count > $1.count }) {
            result = replaceWord(phrase, in: result)
        }
        for word in singles {
            result = replaceWord(word, in: result)
        }
        return normalizeWhitespace(result.replacingOccurrences(of: " ,", with: ","))
    }

    private static func replaceWord(_ word: String, in text: String) -> String {
        let escaped = word.split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
        let pattern = "(?<![A-Za-z0-9])" + escaped + "(?![A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    /// Capitalize the first alphabetic character of each sentence.
    public static func capitalizeSentences(_ text: String) -> String {
        var chars = Array(text)
        var capitalizeNext = true
        for i in 0..<chars.count {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                chars[i] = Character(String(c).uppercased())
                capitalizeNext = false
            } else if ".!?".contains(c) {
                capitalizeNext = true
            } else if c == "\n" {
                capitalizeNext = true
            }
        }
        return String(chars)
    }

    /// Ensure the text ends with terminal punctuation (adds a period if missing
    /// and the text ends in a letter/digit).
    public static func ensureTerminalPunctuation(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        if last.isLetter || last.isNumber {
            return trimmed + "."
        }
        return trimmed
    }

    /// Convert common spoken punctuation words to symbols. Used for prose modes,
    /// NOT for code mode (where "period" may be literal).
    public static func applySpokenPunctuation(_ text: String) -> String {
        let replacements: [(String, String)] = [
            (" period", "."),
            (" comma", ","),
            (" question mark", "?"),
            (" exclamation point", "!"),
            (" exclamation mark", "!"),
            (" new line", "\n"),
            (" new paragraph", "\n\n"),
            (" colon", ":"),
            (" semicolon", ";"),
            (" open paren", " ("),
            (" close paren", ")")
        ]
        var result = text
        for (spoken, symbol) in replacements {
            result = result.replacingOccurrences(of: spoken, with: symbol, options: [.caseInsensitive])
        }
        // Tidy spaces that precede punctuation after substitution.
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " ?", with: "?")
        result = result.replacingOccurrences(of: " !", with: "!")
        return result
    }
}
