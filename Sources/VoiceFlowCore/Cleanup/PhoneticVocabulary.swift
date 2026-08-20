import Foundation

/// The safety net behind `VocabularyReplacer`: catches mishearings of the user's
/// own vocabulary that he never predicted.
///
/// WHY THIS EXISTS. The exact-match replacer only fires on a spelling the user
/// entered in advance, so his real vocabulary had grown a hand-written list of
/// every mishearing that had already burned him — `codices`, `codecs`, `codeex`
/// → Codex; `get hub`, `git hop` → GitHub; `clod code`, `closed code` → Claude
/// Code. Requiring a user to enumerate the ways a recogniser can mangle a word
/// IS the defect: he can only ever add the ones that already cost him. One
/// entry should cover anything that SOUNDS like it.
///
/// WHY IT IS CONSERVATIVE. This runs BEFORE `CleanupGuard`, on the raw
/// transcript, so nothing downstream will catch a mistake it makes — the user's
/// own dictionary is trusted by design. It may therefore only replace a token
/// when the evidence is strong, and it can never introduce a word that is not
/// already in his vocabulary. The bar is deliberately set so that ordinary
/// words which merely resemble an entry ("code" vs "Codex") survive untouched:
/// a missed correction costs one wrong word, a false correction destroys a word
/// he actually said, and the second is the failure this whole product refuses.
public struct PhoneticVocabulary: Sendable {

    private struct Target: Sendable {
        let written: String
        let spokenWords: [String]   // normalized, e.g. ["claude", "code"]
        let key: String             // phonetic key of the joined spoken form
        let plain: String           // letters of the joined spoken form
    }

    private let targets: [Target]
    /// How many adjacent words one scan may join. One MORE than the longest
    /// entry, because a recogniser splits a single term into two words at least
    /// as often as it garbles it ("github" → "get hub").
    private let maxPhraseWords: Int

    public init(entries: [VocabularyEntry]) {
        let built: [Target] = entries.compactMap { entry in
            guard entry.isEnabled else { return nil }
            let words = Self.words(entry.spoken)
            guard !words.isEmpty else { return nil }
            let plain = words.joined()
            // A two-or-three letter entry cannot be matched safely by sound —
            // almost every short word resembles every other one.
            guard plain.count >= 4 else { return nil }
            return Target(written: entry.written, spokenWords: words,
                          key: Self.phoneticKey(plain), plain: plain)
        }
        self.targets = built
        self.maxPhraseWords = min(3, (built.map(\.spokenWords.count).max() ?? 1) + 1)
    }

    /// A word the user said that SOUNDS like one of his vocabulary terms but
    /// was not spelled like it — a candidate mishearing.
    public struct NearMiss: Sendable, Equatable, CustomStringConvertible {
        /// Exactly what the transcript contained, e.g. "get hub".
        public let heard: String
        /// The vocabulary term it resembles, e.g. "GitHub".
        public let written: String
        public var description: String { "\(heard) → \(written)" }
    }

    /// Terms in `text` that sound like one of the user's vocabulary entries.
    ///
    /// DETECTION ONLY — this never rewrites the transcript, and that is a
    /// deliberate limit rather than an unfinished feature. "codecs" and
    /// "codices" are ordinary English words; nothing here can distinguish "he
    /// said codecs" from "Codex was misheard as codecs", because only the
    /// acoustic context can, and that context is gone by the time text exists.
    /// Guessing would silently destroy a word he actually said — the failure
    /// Wispr shipped and this product refuses. The place to win this is the
    /// recogniser (context biasing); here we only propose.
    public func nearMisses(in text: String) -> [NearMiss] {
        guard !targets.isEmpty else { return [] }
        let tokens = Self.tokenize(text)
        guard !tokens.isEmpty else { return [] }
        var found: [NearMiss] = []
        var i = 0
        while i < tokens.count {
            // Score every span, take the BEST — not the longest. Greedy
            // longest-first grabbed "codecs to" for Codex when "codecs" alone
            // was the closer sound; the extra word made the match worse and the
            // suggestion unreadable.
            var best: (span: Int, written: String, score: Int)? = nil
            for span in 1...min(maxPhraseWords, tokens.count - i) {
                let slice = Array(tokens[i..<(i + span)])
                guard let hit = bestMatch(for: slice) else { continue }
                if best == nil || hit.score < best!.score {
                    best = (span, hit.written, hit.score)
                }
            }
            if let best {
                let slice = Array(tokens[i..<(i + best.span)])
                found.append(NearMiss(heard: slice.map(\.normalized).joined(separator: " "),
                                      written: best.written))
                i += best.span
            } else {
                i += 1
            }
        }
        return found
    }

    /// The entry this run of words sounds like plus how far off it was (lower
    /// is closer), or nil to leave it alone.
    private func bestMatch(for slice: [Token]) -> (written: String, score: Int)? {
        let heardWords = slice.map(\.normalized)
        let heard = heardWords.joined()
        guard heard.count >= 4 else { return nil }
        let heardKey = Self.phoneticKey(heard)

        // Deliberately NOT keyed on word count: a recogniser splits and joins
        // words as readily as it mangles them — "github" comes back as "get
        // hub", "claude code" as "closed code". Comparing the joined sound is
        // the only way to see across that.
        for target in targets {
            // Already correct in either the spoken or the written form — the
            // deterministic replacer owns that case.
            if heardWords == target.spokenWords { continue }
            if heard == Self.words(target.written).joined() { continue }
            // The consonant skeleton must essentially agree. This is the signal;
            // the spelling check below only rejects the wildest coincidences.
            guard Self.editDistance(heardKey, target.key) <= 1 else { continue }
            // Same opening sound: a mishearing garbles the middle and end of a
            // word far more often than its first phoneme.
            guard heardKey.first == target.key.first else { continue }
            // Length has to be in the same neighbourhood, or "code" resembles
            // "Claude Code".
            let budget = max(2, (max(heard.count, target.plain.count) + 1) / 2)
            let spelling = Self.editDistance(heard, target.plain)
            guard spelling <= budget else { continue }
            return (target.written, Self.editDistance(heardKey, target.key) * 4 + spelling)
        }
        return nil
    }

    // MARK: - Phonetics

    /// A Metaphone-style consonant skeleton: what the word SOUNDS like, with the
    /// spellings that differ but sound identical folded together (ph/f, ck/k,
    /// c-before-e/s). Vowels after the first letter are dropped — they are where
    /// accents and mishearings vary most, which is exactly what we want ignored.
    static func phoneticKey(_ word: String) -> String {
        let chars = Array(word.lowercased().filter { $0.isLetter })
        guard !chars.isEmpty else { return "" }
        var key = ""
        var i = 0
        func next(_ offset: Int = 1) -> Character? {
            i + offset < chars.count ? chars[i + offset] : nil
        }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        while i < chars.count {
            let c = chars[i]
            var emitted: String? = nil
            switch c {
            case "a", "e", "i", "o", "u":
                if i == 0 { emitted = "A" }               // only a leading vowel matters
            case "b": emitted = "P"
            case "c":
                if next() == "h" { emitted = "X"; i += 1 }          // church
                else if let n = next(), "eiy".contains(n) { emitted = "S" }
                else if next() == "k" { emitted = "K"; i += 1 }
                else { emitted = "K" }
            case "d":
                if next() == "g" { emitted = "J"; i += 1 } else { emitted = "T" }
            case "g":
                if next() == "h" { emitted = "K"; i += 1 }          // "hop"/"hub" stay K
                else if let n = next(), "eiy".contains(n) { emitted = "J" }
                else { emitted = "K" }
            case "h":
                // Only audible before a vowel; silent after another consonant.
                if let n = next(), vowels.contains(n), i == 0 || vowels.contains(chars[i - 1]) || i == 0 {
                    emitted = "H"
                } else if i == 0, let n = next(), vowels.contains(n) { emitted = "H" }
            case "k": emitted = "K"
            case "p":
                if next() == "h" { emitted = "F"; i += 1 } else { emitted = "P" }
            case "q": emitted = "K"
            case "s":
                if next() == "h" { emitted = "X"; i += 1 } else { emitted = "S" }
            case "t":
                if next() == "h" { emitted = "0"; i += 1 }
                else if next() == "i", let n2 = next(2), n2 == "o" { emitted = "X" }
                else { emitted = "T" }
            case "v": emitted = "F"
            case "w", "y":
                if let n = next(), vowels.contains(n) { emitted = String(c).uppercased() }
            case "x": emitted = "KS"
            case "z": emitted = "S"
            default: emitted = String(c).uppercased()
            }
            if let emitted, key.last.map({ String($0) }) != emitted || emitted.count > 1 {
                key += emitted
            }
            i += 1
        }
        return key
    }

    // MARK: - Text helpers

    private struct Token {
        let normalized: String
        let range: Range<String.Index>
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index? = nil
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isLetter || text[index].isNumber {
                if start == nil { start = index }
            } else if let s = start {
                tokens.append(Token(normalized: text[s..<index].lowercased(), range: s..<index))
                start = nil
            }
            index = text.index(after: index)
        }
        if let s = start {
            tokens.append(Token(normalized: text[s..<text.endIndex].lowercased(), range: s..<text.endIndex))
        }
        return tokens
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = previous
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1]
                    ? previous[j - 1]
                    : min(previous[j], current[j - 1], previous[j - 1]) + 1
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
