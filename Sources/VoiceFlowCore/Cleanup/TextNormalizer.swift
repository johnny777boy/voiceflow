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
    /// NOTE: "er", "err", and "ah" are deliberately NOT here — matching is
    /// case-insensitive, so they destroyed the real words "ER" (emergency room),
    /// "err" ("to err is human"), and the interjection "ah" ("ah, I see").
    /// Filled pauses — the ONLY class of disfluency that is unconditionally safe
    /// to delete, because it has no semantic content by definition. This matches
    /// NIST SCTK's `%HESITATION` class and the filler list shipped by VoiceInk,
    /// the leading open-source Mac competitor.
    ///
    /// Words like "like", "well", "okay", "right", "so", "actually" are NOT here
    /// and must not be added. Research on the Switchboard corpus found human
    /// annotators could not agree on them (κ 0.40–0.43), the stylebook abandoned
    /// "actually" as unmarkable mid-project, and automatic detection of
    /// discourse-"like" tops out near 79% precision — one deletion in five wrong.
    /// In this user's work they are load-bearing: "dig a new WELL", "the framing
    /// is OKAY", "he was SERIOUSLY injured", "turn RIGHT at the corner".
    public static let fillerWords: Set<String> = [
        "um", "uh", "uhh", "umm", "uhm", "erm", "hmm", "mhm", "mmm"
    ]
    // NOT added, and the existing suite proved why: "er" would eat the ER in
    // "the ER doctor", and "mm" would eat the unit in "50 mm trim". Even the
    // supposedly-safe class needs checking against what this user actually says.

    /// Collapse a stutter: an immediately repeated CLOSED-CLASS word, "the the"
    /// → "the". Restricted to function words on purpose — repeated open-class
    /// words are usually deliberate ("very very careful", "no no no"), and this
    /// runs before the model sees the text so it must never guess.
    public static func collapseStutters(_ text: String) -> String {
        let closedClass: Set<String> = [
            "the", "a", "an", "and", "or", "but", "of", "to", "in", "for", "on",
            "with", "at", "by", "from", "is", "are", "was", "were", "i", "you",
            "he", "she", "it", "we", "they", "that", "this", "so", "my", "your",
        ]
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false)
        var out: [Substring] = []
        for token in tokens {
            let bare = token.lowercased().filter { $0.isLetter }
            if let previous = out.last {
                let previousBare = previous.lowercased().filter { $0.isLetter }
                if !bare.isEmpty, bare == previousBare, closedClass.contains(bare) {
                    continue   // drop the repeat, keep the first
                }
            }
            out.append(token)
        }
        return out.joined(separator: " ")
    }

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

    /// Strip a meta preamble a small LLM sometimes prepends despite instructions
    /// ("Here is the cleaned text:", "Sure, here's the corrected version:", "Cleaned
    /// text:"). Only matches when a cleaning keyword (cleaned/corrected/…) is present,
    /// so genuine content like "Here is the plan:" is left untouched.
    public static func stripLLMPreamble(_ text: String) -> String {
        var text = text
        let pattern = "^\\s*(sure[,.]?\\s+)?(here'?s?\\s+(is\\s+)?)?(the\\s+)?(cleaned|corrected|polished|revised|edited)([ -]?up)?\\s+(text|version|transcript|sentence)\\s*:\\s*"
        if let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            text = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip a wrapping code fence. Apple's on-device model is documented to
        // leak markdown — MacWhisper shipped a release specifically for
        // "accidental markdown or ticks" from Foundation Models. Left in, it
        // reaches the guard as an invented word and the whole repair is rejected,
        // so it costs quality silently rather than showing up as visible junk.
        let fence = "^\\s*```[a-zA-Z]*\\s*\\n?([\\s\\S]*?)\\n?\\s*```\\s*$"
        if let r = text.range(of: fence, options: [.regularExpression]) {
            let inner = text[r]
            if let open = inner.range(of: "```[a-zA-Z]*\\s*\\n?", options: .regularExpression),
               let close = inner.range(of: "\\n?\\s*```\\s*$", options: .regularExpression) {
                text = String(inner[open.upperBound..<close.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    /// Final prose tidy: collapse doubled sentence punctuation ("it.. our" → "it. our"),
    /// repeated commas, and stray spaces before punctuation — artifacts that appear
    /// when speech segments are stitched together or the LLM leaves a seam. Then
    /// re-capitalize sentence starts. NOT for code mode (would break "0..2", paths).
    public static func tidyProse(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "\\.{2,}", with: ".", options: .regularExpression)   // ".."/"..." → "."
        t = t.replacingOccurrences(of: "\\?{2,}", with: "?", options: .regularExpression)
        t = t.replacingOccurrences(of: "!{2,}", with: "!", options: .regularExpression)
        t = t.replacingOccurrences(of: ",\\s*,", with: ",", options: .regularExpression)     // ", ," → ","
        t = t.replacingOccurrences(of: "\\.\\s+\\.", with: ".", options: .regularExpression) // ". ." → "."
        for p in [".", ",", "?", "!", ":", ";"] {
            t = t.replacingOccurrences(of: " " + p, with: p)
        }
        // Insert a MISSING space AFTER punctuation that's glued to the next word
        // ("word,next" → "word, next"). Safe for , ; : ? ! (never inside numbers).
        t = t.replacingOccurrences(of: "([,;:?!])(?=[A-Za-z])", with: "$1 ", options: .regularExpression)
        // A glued sentence break: lowercase + period + Uppercase ("it.Our" → "it. Our").
        // The case constraints skip initialisms ("U.S.") and decimals ("3.14").
        t = t.replacingOccurrences(of: "(?<=[a-z])\\.(?=[A-Z])", with: ". ", options: .regularExpression)
        t = normalizeWhitespace(t)
        return capitalizeSentences(t)
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
