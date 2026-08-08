import Foundation

/// Decides whether an LLM cleanup result is a *safe edit* of the original, or a
/// meaning-changing rewrite that must be rejected (so the caller falls back to the
/// deterministic result). Pure and unit-tested.
///
/// A plain word-overlap ratio can't do this job: a legitimate grammar fix for
/// non-native English swaps many words ("interesting for discuss" → "interested in
/// discussing"), while a dangerous edit can flip meaning by dropping ONE short word
/// ("do not delete" → "do delete"). So we check the things that carry meaning
/// directly — negation and numbers — and use overlap only as a loose anti-hallucination
/// floor.
public enum CleanupGuard {

    /// True if `cleaned` may be delivered; false ⇒ reject and use the rule result.
    public static func preservesMeaning(original: String, cleaned: String) -> Bool {
        let inWords = wordCount(original)
        let outWords = wordCount(cleaned)

        // 1. Length: reject a ballooned (hallucinated) or gutted output.
        if inWords >= 3, outWords > inWords * 2 || outWords * 3 < inWords { return false }

        // 2. Negation must be preserved. Dropping/adding a negation flips meaning
        //    ("do not delete" → "do delete"), which overlap checks miss because the
        //    words are short. This is the critical safety check.
        if negationCount(original) != negationCount(cleaned) { return false }

        // 3. Numbers must match EXACTLY in both directions: none dropped
        //    ("$3.14" → "$4.15") and none invented (cleanup may not add digits
        //    the user never spoke).
        if numbers(original) != numbers(cleaned) { return false }

        // 4. BIDIRECTIONAL verbatim check (tightened 2026-08-08 after live-use
        //    evidence: cleanup invented "you" in 'Thank'→'Thank you.' through the
        //    short-word exemption, and DELETED 'It keeps saying' entirely —
        //    deletions were previously unguarded).
        //
        //    4a. No invented words, of ANY length. A cleaned word is allowed only
        //        if it appeared in the original or is a morphological variant of
        //        an original word ("go"→"going", "discuss"→"discussing").
        let originalWords = allWords(original)
        let originalSet = Set(originalWords)
        // Only tokens that literally follow an apostrophe in the cleaned text
        // ("don't" → shard "t") are contraction shards — a blanket 1-char pass
        // would let cleanup invent "I"/"a" (Codex verification finding).
        let shards = contractionShards(cleaned)
        for word in allWords(cleaned) where !originalSet.contains(word) {
            if shards.contains(word) { continue }              // "don't" → "don","t"
            if word.allSatisfy({ $0.isNumber }) { continue }   // digit sets equal per step 3
            if !sharesStem(word, withAnyOf: originalWords) { return false }
        }

        //    4b. No deleted content words. Every significant original word must
        //        survive (or a variant of it). Hesitation fillers are exempt —
        //        removing "um" is the one deletion cleanup is FOR.
        let cleanedWords = allWords(cleaned)
        let cleanedSet = Set(cleanedWords)
        for word in significantWords(original) where !cleanedSet.contains(word) {
            if TextNormalizer.fillerWords.contains(word) { continue }
            if !sharesStem(word, withAnyOf: cleanedWords) { return false }
        }
        return true
    }

    /// True when `word` looks like a morphological variant of some candidate:
    /// for short words (≤4 chars) one must be a prefix of the other ("go"~
    /// "going", "you"~"your"); for longer words, a shared prefix of ≥4 chars
    /// covering at least half of the shorter word ("discussing"~"discuss").
    /// Homophones like "peel"~"pill", "czech"~"check", "tank"~"bank" fail both.
    private static func sharesStem(_ word: String, withAnyOf candidates: [String]) -> Bool {
        for other in candidates where other != word {
            let common = zip(word, other).prefix { $0 == $1 }.count
            let shorter = min(word.count, other.count)
            if shorter <= 4 {
                if common == shorter, common >= 2 { return true }   // prefix relation
            } else if common >= 4, common * 2 >= shorter {
                return true
            }
        }
        return false
    }

    /// Every alphanumeric word, lowercased (no length filter).
    static func allWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    /// Letter-runs that immediately follow an apostrophe (' or ’) after a letter
    /// — the fragments produced when `allWords` splits a contraction: "don't" →
    /// "t", "we'll" → "ll", "it's" → "s". Only these may appear as "new" words.
    static func contractionShards(_ text: String) -> Set<String> {
        var shards = Set<String>()
        let lower = Array(text.lowercased())
        for i in lower.indices where lower[i] == "'" || lower[i] == "\u{2019}" {
            guard i > lower.startIndex, lower[i - 1].isLetter else { continue }
            var j = i + 1
            var shard = ""
            while j < lower.endIndex, lower[j].isLetter {
                shard.append(lower[j]); j += 1
            }
            if !shard.isEmpty { shards.insert(shard) }
        }
        return shards
    }

    // MARK: - Helpers

    static func wordCount(_ text: String) -> Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }

    private static let negationWords: Set<String> = [
        "not", "never", "no", "none", "cannot", "without",
        "neither", "nor", "nobody", "nothing", "nowhere"
    ]

    /// Count negation markers: whole negation words plus contractions ("n't").
    static func negationCount(_ text: String) -> Int {
        let lower = text.lowercased()
        let words = lower.split { !$0.isLetter }.map(String.init)
        var count = words.filter { negationWords.contains($0) }.count
        // Contractions: don't, can't, isn't, won't, shouldn't, …
        count += lower.components(separatedBy: "n't").count - 1
        return count
    }

    /// Distinct digit groups (e.g. "version 3.14, page 7" → {"3", "14", "7"}).
    static func numbers(_ text: String) -> Set<String> {
        Set(text.split { !$0.isNumber }.map(String.init).filter { !$0.isEmpty })
    }

    /// Content words (>3 chars), lowercased — ignores articles/fillers cleanup may drop.
    static func significantWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { $0.count > 3 }
    }
}
