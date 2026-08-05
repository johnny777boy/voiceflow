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
    /// NOTE: "you know" and "i mean" are deliberately NOT here — deleting them
    /// unconditionally changes meaning ("Do you know the answer" → "Do the answer").
    public static let fillerWords: Set<String> = [
        "um", "uh", "uhh", "umm", "uhm", "er", "err", "erm", "ah", "hmm", "mhm"
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
        result = result.replacingOccurrences(of: " ,", with: ",")
        // Strip orphaned leading punctuation/space left after removing a leading
        // filler ("um, hello" → ", hello" → "hello").
        result = result.replacingOccurrences(of: "^[,\\s]+", with: "", options: .regularExpression)
        return normalizeWhitespace(result)
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
            } else if c == "\n" {
                capitalizeNext = true
            } else if "!?".contains(c) {
                capitalizeNext = true
            } else if c == "." {
                // Don't treat a period as a sentence end when it's a decimal
                // (digit before: "3.14") or a single-letter initialism
                // ("U.S.", "e.g.") — those would wrongly capitalize the next word.
                let prev = i > 0 ? chars[i - 1] : " "
                let prevPrev = i > 1 ? chars[i - 2] : " "
                let isDecimal = prev.isNumber
                let isInitialism = prev.isLetter && !prevPrev.isLetter
                if !isDecimal && !isInitialism { capitalizeNext = true }
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
        // Longer phrases first so "new paragraph" isn't caught by "new line" etc.
        // Each is matched as a WHOLE WORD/PHRASE so ordinary words are never
        // mangled ("run the command" must NOT become "run the,nd").
        let replacements: [(String, String)] = [
            ("new paragraph", "\n\n"),
            ("new line", "\n"),
            ("question mark", "?"),
            ("exclamation point", "!"),
            ("exclamation mark", "!"),
            ("open paren", "("),
            ("close paren", ")"),
            ("semicolon", ";"),
            ("period", "."),
            ("comma", ","),
            ("colon", ":")
        ]
        var result = text
        for (spoken, symbol) in replacements {
            result = replaceSpoken(spoken, with: symbol, in: result)
        }
        // Tidy spaces that precede punctuation after substitution.
        for p in [".", ",", "?", "!", ":", ";", ")"] {
            result = result.replacingOccurrences(of: " " + p, with: p)
        }
        result = result.replacingOccurrences(of: "( ", with: "(")
        return normalizeWhitespace(result)
    }

    /// Replace a spoken punctuation phrase with its symbol, matching only whole
    /// words (word-boundary anchored) so it never eats part of a real word.
    private static func replaceSpoken(_ phrase: String, with symbol: String, in text: String) -> String {
        let escaped = phrase.split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
        let pattern = "(?<![A-Za-z0-9])" + escaped + "(?![A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let template = NSRegularExpression.escapedTemplate(for: symbol)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
