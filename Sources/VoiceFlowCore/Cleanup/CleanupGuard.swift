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

        // 3. Every number in the input must survive (no "$3.14" → "$4.15", no dropped
        //    quantities/dates).
        if !numbers(original).isSubset(of: numbers(cleaned)) { return false }

        // 4. No invented content words. A homophone swap ("pill" → "peel",
        //    "check" → "czech") or added content ("…first thing tomorrow") passes
        //    every check above but fabricates words the user never spoke — the
        //    exact failure the verbatim goal forbids. A cleaned content word is
        //    allowed only if it appeared in the original OR shares a stem with an
        //    original word (so legitimate grammar fixes like "interesting for
        //    discuss" → "interested in discussing" still pass).
        let originalSignificant = significantWords(original)
        let inSet = Set(originalSignificant)
        for word in significantWords(cleaned) where !inSet.contains(word) {
            if word.allSatisfy({ $0.isNumber }) { continue }   // digits guarded in step 3
            if !sharesStem(word, withAnyOf: originalSignificant) { return false }
        }

        // 5. Loose topical overlap — only to catch a total rewrite about something
        //    else. Deliberately low so real grammar rewrites are NOT rejected.
        let significant = originalSignificant
        if significant.count >= 5 {
            let kept = Set(significantWords(cleaned))
            let survived = significant.filter { kept.contains($0) }.count
            if Double(survived) / Double(significant.count) < 0.3 { return false }
        }
        return true
    }

    /// True when `word` looks like a morphological variant of some original word:
    /// a shared prefix of ≥4 chars covering at least half of the shorter word.
    /// "discussing"~"discuss" and "interested"~"interesting" pass; homophones
    /// like "peel"~"pill", "czech"~"check", "tank"~"bank" do not.
    private static func sharesStem(_ word: String, withAnyOf candidates: [String]) -> Bool {
        for other in candidates {
            let common = zip(word, other).prefix { $0 == $1 }.count
            let shorter = min(word.count, other.count)
            if common >= 4, common * 2 >= shorter { return true }
        }
        return false
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
