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

    /// How much freedom the cleanup model has.
    ///
    /// `verbatim` was the founding rule: not one word added, dropped or swapped.
    /// It protects a native speaker perfectly and fails a non-native one — it
    /// blocks exactly the repairs they need, because "go"→"went" shares no
    /// letters and "in"/"the" look like invented words. Yoni asked for his
    /// English to be corrected (2026-08-18), so `grammarRepair` widens the
    /// allowance in two precise, closed ways and NOT ONE STEP FURTHER:
    ///
    ///  - function words (articles, prepositions, auxiliaries, pronouns) may be
    ///    added, dropped or swapped — they carry no content;
    ///  - irregular verb forms of the same verb are equivalent (go/went/gone).
    ///
    /// Everything that carries meaning stays locked: every CONTENT word must
    /// survive (or as a form of itself), negation and numbers must match exactly,
    /// and insertions are budgeted by length so a one-word utterance can never
    /// grow ("Thank" → "Thank you." remains impossible — the live 2026-08-08
    /// defect). The line is: fix HOW he said it, never change WHAT he said.
    public enum Policy: Sendable, Equatable {
        case verbatim
        case grammarRepair
    }

    /// Closed-class English words: they encode structure, not content. A cleanup
    /// that adds "the" or changes "for"→"in" is fixing grammar; one that adds
    /// "invoice" is inventing. This set is what separates the two.
    public static let functionWords: Set<String> = [
        "a", "an", "the",
        "of", "to", "in", "for", "on", "with", "at", "by", "from", "into", "onto",
        "about", "over", "under", "above", "below", "after", "before", "between",
        "through", "during", "without", "within", "along", "across", "behind",
        "am", "is", "are", "was", "were", "be", "been", "being",
        "do", "does", "did", "done", "have", "has", "had", "having",
        "will", "would", "can", "could", "shall", "should", "may", "might", "must",
        "and", "but", "or", "nor", "so", "yet", "if", "than", "then", "because",
        "that", "which", "who", "whom", "whose", "this", "these", "those",
        "i", "me", "my", "mine", "myself",
        "you", "your", "yours", "yourself",
        "he", "him", "his", "she", "her", "hers", "it", "its",
        "we", "us", "our", "ours", "they", "them", "their", "theirs",
        "there", "here", "as", "up", "out", "off", "down", "just", "also",
    ]

    /// Irregular verbs, grouped so every form of one verb is equivalent to the
    /// others. `sharesStem` cannot see these — "go"/"went" have no letters in
    /// common — yet they are the single most common non-native tense error.
    static let irregularVerbClasses: [Set<String>] = [
        ["be", "am", "is", "are", "was", "were", "been", "being"],
        ["go", "goes", "went", "gone", "going"],
        ["have", "has", "had", "having"],
        ["do", "does", "did", "done", "doing"],
        ["say", "says", "said", "saying"],
        ["make", "makes", "made", "making"],
        ["take", "takes", "took", "taken", "taking"],
        ["come", "comes", "came", "coming"],
        ["see", "sees", "saw", "seen", "seeing"],
        ["know", "knows", "knew", "known", "knowing"],
        ["get", "gets", "got", "gotten", "getting"],
        ["give", "gives", "gave", "given", "giving"],
        ["find", "finds", "found", "finding"],
        ["think", "thinks", "thought", "thinking"],
        ["tell", "tells", "told", "telling"],
        ["become", "becomes", "became", "becoming"],
        ["leave", "leaves", "left", "leaving"],
        ["feel", "feels", "felt", "feeling"],
        ["bring", "brings", "brought", "bringing"],
        ["begin", "begins", "began", "begun", "beginning"],
        ["keep", "keeps", "kept", "keeping"],
        ["write", "writes", "wrote", "written", "writing"],
        ["hear", "hears", "heard", "hearing"],
        ["mean", "means", "meant", "meaning"],
        ["meet", "meets", "met", "meeting"],
        ["run", "runs", "ran", "running"],
        ["pay", "pays", "paid", "paying"],
        ["speak", "speaks", "spoke", "spoken", "speaking"],
        ["lose", "loses", "lost", "losing"],
        ["send", "sends", "sent", "sending"],
        ["build", "builds", "built", "building"],
        ["understand", "understands", "understood", "understanding"],
        ["break", "breaks", "broke", "broken", "breaking"],
        ["spend", "spends", "spent", "spending"],
        ["buy", "buys", "bought", "buying"],
        ["teach", "teaches", "taught", "teaching"],
        ["catch", "catches", "caught", "catching"],
        ["sell", "sells", "sold", "selling"],
        ["choose", "chooses", "chose", "chosen", "choosing"],
        ["show", "shows", "showed", "shown", "showing"],
        ["hold", "holds", "held", "holding"],
        ["read", "reads", "reading"],
        ["put", "puts", "putting"],
        ["let", "lets", "letting"],
        ["set", "sets", "setting"],
    ]

    /// Whether two words are forms of the same irregular verb.
    public static func sameIrregularVerb(_ a: String, _ b: String) -> Bool {
        irregularVerbClasses.contains { $0.contains(a) && $0.contains(b) }
    }

    /// How many function words `grammarRepair` may INSERT, scaled to length.
    ///
    /// Budgeted, not unlimited: "Thank" → "Thank you." adds only a pronoun, so a
    /// naive closed-class rule would wave it through — and that exact edit is the
    /// live defect that made this guard bidirectional in the first place. A very
    /// short utterance therefore gets NO insertion budget at all; longer ones get
    /// roughly one per five words, which covers real repairs ("he went to THE
    /// store") without room to compose new clauses.
    public static func insertionBudget(originalWordCount: Int) -> Int {
        // Real repairs need room: "he go store yesterday" → "he went TO THE
        // store yesterday" is two insertions out of four words. A /5 budget
        // blocked it. Short utterances still get ZERO, which is what keeps
        // "Thank" → "Thank you." impossible.
        originalWordCount <= 3 ? 0 : max(2, originalWordCount / 3)
    }

    /// True if `cleaned` may be delivered; false ⇒ reject and use the rule result.
    public static func preservesMeaning(
        original: String, cleaned: String, policy: Policy = .verbatim
    ) -> Bool {
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
        var insertionsUsed = 0
        let budget = policy == .grammarRepair ? insertionBudget(originalWordCount: originalWords.count) : 0
        for word in allWords(cleaned) where !originalSet.contains(word) {
            if shards.contains(word) { continue }              // "don't" → "don","t"
            if word.allSatisfy({ $0.isNumber }) { continue }   // digit sets equal per step 3
            if sharesStem(word, withAnyOf: originalWords) { continue }
            if policy == .grammarRepair {
                // An irregular form of a verb he actually said is the same verb.
                if originalWords.contains(where: { sameIrregularVerb(word, $0) }) { continue }
                // A function word may be introduced, but only within the budget:
                // structure is free to fix, content is never free to invent.
                if functionWords.contains(word), insertionsUsed < budget {
                    insertionsUsed += 1
                    continue
                }
            }
            return false
        }

        //    4b. No deleted content words. Every significant original word must
        //        survive (or a variant of it). Hesitation fillers are exempt —
        //        removing "um" is the one deletion cleanup is FOR.
        let cleanedWords = allWords(cleaned)
        let cleanedSet = Set(cleanedWords)
        for word in significantWords(original) where !cleanedSet.contains(word) {
            if TextNormalizer.fillerWords.contains(word) { continue }
            if sharesStem(word, withAnyOf: cleanedWords) { continue }
            if policy == .grammarRepair {
                if cleanedWords.contains(where: { sameIrregularVerb(word, $0) }) { continue }
                // Dropping a function word is a grammar fix ("interesting FOR
                // discuss" → "interested IN discussing"); dropping a content word
                // is losing what he said, and stays forbidden.
                if functionWords.contains(word) { continue }
            }
            return false
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
