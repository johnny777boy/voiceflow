import Foundation

/// Decides when the LLM cleanup pass can be skipped without changing the text
/// it would have produced.
///
/// ⚠️ ITS ORIGINAL SAFETY ARGUMENT WAS WRONG, and it now ships OFF by default.
/// The claim was: the strict `CleanupGuard` reduces the model to a
/// punctuation-and-capitalization pass, so skipping it changes nothing. But the
/// guard permits morphological grammar repair — "You'll finish everything." →
/// "You finished everything." passes it (pinned by test). So the skip was
/// silently discarding genuine corrections, and doing so precisely on the short
/// bursts that are HARDEST for the recognizer: least context, most errors, and
/// then excluded from the one stage that could have fixed them. That combination
/// produced the 2026-08-18 accuracy complaint.
///
/// It remains available for users who want the ~0.5–1s back on casual replies,
/// but the honest way to buy that latency is two-phase delivery, which keeps the
/// repair instead of discarding it.
///
/// The one thing the rules genuinely cannot do is choose `?` over `.`, so any
/// utterance that opens like a question keeps its LLM pass. Email keeps its pass
/// too: a short email line is far likelier to be a real sentence being composed.
public enum ShortUtteranceFastPath {

    /// Utterances of at most this many words are candidates for the fast path.
    public static let maxWords = 8

    /// Openers where the rule engine's unconditional trailing "." would be wrong.
    static let questionOpeners: Set<String> = [
        "who", "what", "when", "where", "why", "how", "which", "whose", "whom",
        "is", "are", "was", "were", "am", "do", "does", "did", "can", "could",
        "will", "would", "should", "shall", "may", "might", "have", "has", "had",
        "any", "anyone", "anybody", "ready", "sure",
    ]

    /// Whether `text` (the rule-cleaned result) can skip the LLM stage.
    public static func canSkipLLM(_ text: String, mode: DictationMode) -> Bool {
        guard mode == .cleanWriting || mode == .claudeCode else { return false }
        let words = text.split(whereSeparator: { $0 == " " || $0.isNewline })
        guard !words.isEmpty, words.count <= maxWords else { return false }
        // Already-questionable punctuation means the rules got it right anyway.
        if text.contains("?") { return false }
        guard let first = words.first else { return false }
        let opener = String(first).lowercased().filter { $0.isLetter || $0 == "'" }
        return !questionOpeners.contains(opener)
    }
}
