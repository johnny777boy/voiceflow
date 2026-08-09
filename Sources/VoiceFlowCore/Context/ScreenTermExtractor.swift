import Foundation

/// Pulls likely proper nouns / technical tokens out of on-screen text so they
/// can bias the recognizer for the next dictation.
///
/// Everything here is on-device string work — no model, no network, no
/// screenshot. The input is text already read via Accessibility.
///
/// Design rules (deliberately conservative — a bad term costs accuracy):
/// - Keep only tokens that LOOK like names: a capital letter in a non-initial
///   position of the sentence, internal capitals (`WhisperKit`), dotted
///   compounds (`Next.js`), or short all-caps initialisms (`API`).
/// - Never keep anything that smells private or useless as a bias term:
///   emails, URLs, file paths, long opaque strings (tokens/hashes), pure
///   numbers.
/// - Rank by frequency (a name repeated on screen is what the user is about to
///   say), tie-broken by first appearance, and cap hard.
public enum ScreenTermExtractor {

    /// Sentence-initial words and UI chrome that are capitalized for reasons
    /// that have nothing to do with being a name. Biasing on these is pure
    /// noise — they're already the most probable words in the language model.
    static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "then", "this", "that", "these", "those",
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them",
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did",
        "have", "has", "had", "will", "would", "can", "could", "should", "may", "might", "must",
        "in", "on", "at", "to", "for", "of", "with", "by", "from", "as", "into", "about",
        "what", "when", "where", "who", "why", "how", "which", "there", "here", "not", "no", "yes",
        "so", "just", "now", "new", "all", "any", "some", "more", "most", "other", "than", "too",
        "ok", "okay", "hi", "hey", "hello", "thanks", "thank", "please", "sorry",
        // Ubiquitous window/menu chrome — present in nearly every app.
        "file", "edit", "view", "window", "help", "menu", "search", "settings", "preferences",
        "cancel", "done", "save", "open", "close", "back", "next", "send", "delete", "add",
        "untitled", "today", "yesterday", "tomorrow", "am", "pm",
    ]

    /// Extract bias terms from a blob of on-screen text.
    ///
    /// - Parameters:
    ///   - text: on-screen text (already read via Accessibility).
    ///   - limit: maximum number of terms returned.
    ///   - excluding: terms already covered elsewhere (e.g. the user's
    ///     vocabulary), compared case-insensitively.
    public static func terms(in text: String, limit: Int = 20, excluding: Set<String> = []) -> [String] {
        guard limit > 0, !text.isEmpty else { return [] }
        let excludedKeys = Set(excluding.map { $0.lowercased() })

        var counts: [String: Int] = [:]        // key → frequency
        var firstIndex: [String: Int] = [:]    // key → first appearance order
        var display: [String: String] = [:]    // key → the spelling we'll emit
        var position = 0
        // `isSentenceStart` suppresses the "capitalized only because it opens a
        // sentence" false positives ("The", "Please") without a parser.
        var isSentenceStart = true

        for rawToken in text.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }) {
            let token = String(rawToken)
            position += 1
            let endsSentence = token.hasSuffix(".") || token.hasSuffix("!") || token.hasSuffix("?")
                || token.hasSuffix(":") || token.hasSuffix("\n")
            let atSentenceStart = isSentenceStart
            isSentenceStart = endsSentence

            guard let candidate = normalizeCandidate(token) else { continue }
            guard isBiasWorthy(candidate, atSentenceStart: atSentenceStart) else { continue }

            let key = candidate.lowercased()
            guard !excludedKeys.contains(key), !stopWords.contains(key) else { continue }
            counts[key, default: 0] += 1
            if firstIndex[key] == nil {
                firstIndex[key] = position
                display[key] = candidate
            }
        }

        let ranked = counts.keys.sorted { lhs, rhs in
            let (lc, rc) = (counts[lhs] ?? 0, counts[rhs] ?? 0)
            if lc != rc { return lc > rc }
            return (firstIndex[lhs] ?? 0) < (firstIndex[rhs] ?? 0)
        }
        return ranked.prefix(limit).compactMap { display[$0] }
    }

    /// Strip surrounding punctuation/quotes/brackets, keeping internal dots and
    /// hyphens (`Next.js`, `push-to-talk`). Returns nil when nothing usable is
    /// left.
    static func normalizeCandidate(_ token: String) -> String? {
        let trimSet = CharacterSet(charactersIn: "\"'“”‘’(){}[]<>,.;:!?…*_`~|/\\")
        var trimmed = token.trimmingCharacters(in: trimSet)
        // A trailing possessive is noise on a bias term ("Sarah's" → "Sarah").
        if trimmed.lowercased().hasSuffix("'s") || trimmed.lowercased().hasSuffix("’s") {
            trimmed = String(trimmed.dropLast(2))
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether a cleaned token is worth biasing on.
    static func isBiasWorthy(_ token: String, atSentenceStart: Bool) -> Bool {
        guard token.count >= 2, token.count <= 32 else { return false }
        // Privacy / junk filters first: none of these help recognition, and some
        // of them are things that must never leave the field they're in.
        if token.contains("@") || token.contains("://") || token.contains("/") || token.contains("\\") {
            return false
        }
        guard token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" || $0 == "#" }) else {
            return false
        }
        guard token.contains(where: { $0.isLetter }) else { return false }        // pure numbers/dates
        // Anything mixing letters and digits is refused outright. That shape is a
        // 2FA code, a licence-key fragment, an order id or a session token far
        // more often than it is a word worth biasing on — and those are exactly
        // the strings that must never be lifted off a screen into a prompt. It
        // costs us "H100"-style product names; that trade is not close.
        if token.contains(where: { $0.isNumber }) { return false }

        let letters = token.filter { $0.isLetter }
        let uppercase = letters.filter { $0.isUppercase }.count
        let hasInternalCapital = token.dropFirst().contains { $0.isUppercase }
        let isAllCaps = uppercase == letters.count

        // CamelCase / dotted compounds are names regardless of position.
        if hasInternalCapital { return true }
        if token.contains(".") , token.dropFirst().contains(where: { $0.isLetter }) { return true }
        // Short all-caps initialisms (API, CMS, SQL) — but not shouted words.
        if isAllCaps { return letters.count <= 6 }
        // Otherwise: a leading capital only counts mid-sentence, where it is
        // actually evidence of a name rather than of a sentence boundary.
        if let first = token.first, first.isUppercase, !atSentenceStart { return true }
        return false
    }
}
