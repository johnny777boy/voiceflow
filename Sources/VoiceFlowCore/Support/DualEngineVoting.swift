import Foundation

/// Reconciles two engines' transcripts of the SAME audio, word by word.
///
/// The single inviolable rule: **the result may only ever contain words one of
/// the two engines actually produced at that position.** No synthesis, no
/// merging of word fragments, no "best guess" — this exists to fix a misheard
/// name, and putting a third word in the user's mouth would be the exact failure
/// the whole verbatim design is built to prevent.
///
/// Voting is also deliberately narrow: it only overrides the primary engine when
/// the secondary's word matches a vocabulary term and the primary's does not.
/// Two engines disagreeing on an ordinary word is a coin flip, and a coin flip is
/// not worth overriding the better engine for.
public enum DualEngineVoting {

    /// The outcome of a reconciliation, so callers can log what happened.
    public struct Result: Sendable, Equatable {
        public let text: String
        /// Positions where the secondary engine's word replaced the primary's.
        public let substitutions: [Substitution]
        public var changedAnything: Bool { !substitutions.isEmpty }
    }

    public struct Substitution: Sendable, Equatable {
        public let from: String
        public let to: String
    }

    /// Merge `secondary` into `primary` where the secondary is vocabulary-correct.
    ///
    /// - Parameters:
    ///   - primary: the preferred engine's transcript (kept unless overruled).
    ///   - secondary: the second opinion on the same audio.
    ///   - vocabulary: terms the user cares about, matched case-insensitively.
    public static func reconcile(
        primary: String, secondary: String, vocabulary: [String]
    ) -> Result {
        let primaryWords = primary.split(separator: " ").map(String.init)
        let secondaryWords = secondary.split(separator: " ").map(String.init)
        // Only same-length transcripts are aligned. Different word counts mean
        // the engines heard different structure, and a positional merge would be
        // guessing — exactly what must never happen here.
        guard !primaryWords.isEmpty, primaryWords.count == secondaryWords.count else {
            return Result(text: primary, substitutions: [])
        }
        let terms = Set(vocabulary.map { normalize($0) }.filter { !$0.isEmpty })
        guard !terms.isEmpty else { return Result(text: primary, substitutions: []) }

        var merged: [String] = []
        var substitutions: [Substitution] = []
        for (mine, theirs) in zip(primaryWords, secondaryWords) {
            guard mine != theirs,
                  terms.contains(normalize(theirs)),
                  !terms.contains(normalize(mine)) else {
                merged.append(mine)
                continue
            }
            // Take the secondary's word, but keep the primary's punctuation so a
            // sentence doesn't lose its comma or period to the swap.
            let replacement = transferAffixes(from: mine, to: theirs)
            merged.append(replacement)
            substitutions.append(Substitution(from: mine, to: replacement))
        }
        return Result(text: merged.joined(separator: " "), substitutions: substitutions)
    }

    /// Whether the primary transcript contains a near-miss of a vocabulary term —
    /// the cheap signal that a second opinion is worth its latency.
    ///
    /// "Near" is normally a single character ("Sara"/"Sarah"), the shape of a
    /// misheard name rather than a different word. When the decoder itself was
    /// unsure (`maxEdits: 2`) the net widens, because low confidence plus a
    /// nearly-right name is the case this whole mechanism exists for.
    ///
    /// Note what this does NOT do: low confidence *alone* never triggers a second
    /// engine. Reconciliation can only ever change a vocabulary word, so paying
    /// 1–2s for a second opinion that provably cannot alter the text would be
    /// latency spent for nothing.
    public static func containsNearMiss(text: String, vocabulary: [String], maxEdits: Int = 1) -> Bool {
        let words = text.split(separator: " ").map { normalize(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty, maxEdits > 0 else { return false }
        let terms = vocabulary.map { normalize($0) }.filter { $0.count >= 4 }
        guard !terms.isEmpty else { return false }
        for term in terms {
            for word in words where word != term && editDistance(word, term, limit: maxEdits) <= maxEdits {
                return true
            }
        }
        return false
    }

    /// Lowercase and strip punctuation, so "Sarah," compares as "sarah".
    static func normalize(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Move the primary word's leading/trailing punctuation onto the replacement.
    static func transferAffixes(from original: String, to replacement: String) -> String {
        let isCore: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        // A word with no letters or digits at all (a stray dash) has no affixes to
        // transfer — treating it as both prefix AND suffix would wrap the
        // replacement in punctuation and produce a token neither engine emitted.
        guard original.contains(where: isCore) else { return replacement }
        let prefix = String(original.prefix(while: { !isCore($0) }))
        let suffix = String(original.reversed().prefix(while: { !isCore($0) }).reversed())
        let core = replacement.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return prefix + (core.isEmpty ? replacement : core) + suffix
    }

    /// Levenshtein distance, abandoned as soon as it exceeds `limit` (returns
    /// `limit + 1`). Two rolling rows — the words here are short, and this runs
    /// per word per vocabulary term on the dictation path.
    static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowBest = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowBest = min(rowBest, current[j])
            }
            if rowBest > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
