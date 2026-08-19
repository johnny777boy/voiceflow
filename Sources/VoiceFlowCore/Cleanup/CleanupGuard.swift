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

    /// Closed-class words that carry NO relational meaning: swapping one for
    /// another cannot change who did what to whom. Only these are freely
    /// interchangeable.
    public static let freeFunctionWords: Set<String> = [
        "a", "an", "the", "this", "these", "those",
        "that", "which", "who", "whom", "whose",
        "there", "here", "as", "just", "also", "yet",
    ]

    /// Closed-class words that DO carry meaning, grouped by class.
    ///
    /// The first version of this guard treated every function word as
    /// interchangeable, which was catastrophically wrong: a review demonstrated
    /// "transfer the deposit TO Bob" → "FROM Bob", "call me BEFORE the meeting"
    /// → "AFTER", "budget UNDER 50 thousand" → "OVER", "I might" → "I will",
    /// "I will pay" → "YOU will pay", all accepted. Every one of those changes
    /// what he said — about money, dates, obligation and who owes whom.
    ///
    /// Members of a class may be INSERTED or DELETED (that is grammar), but one
    /// may never be SUBSTITUTED for another in the same class (that is meaning).
    static let semanticFunctionClasses: [String: Set<String>] = {
        let classes: [(String, Set<String>)] = [
            ("preposition", [
                "of", "to", "in", "for", "on", "with", "at", "by", "from", "into",
                "onto", "about", "over", "under", "above", "below", "after",
                "before", "between", "through", "during", "within", "along",
                "across", "behind", "up", "out", "off", "down",
            ]),
            ("modal", ["can", "could", "shall", "should", "may", "might", "must"]),
            ("tense", ["will", "would", "have", "has", "had", "having",
                       "am", "is", "are", "was", "were", "be", "been", "being"]),
            ("pronoun", [
                "i", "me", "my", "mine", "myself",
                "you", "your", "yours", "yourself",
                "he", "him", "his", "she", "her", "hers", "it", "its",
                "we", "us", "our", "ours", "they", "them", "their", "theirs",
            ]),
            ("conjunction", ["and", "but", "or", "nor", "so", "if", "than", "then", "because"]),
        ]
        var map: [String: Set<String>] = [:]
        for (name, words) in classes {
            for word in words { map[word] = Set([name]) }
        }
        return map
    }()

    /// Every closed-class word, free or semantic.
    public static var functionWords: Set<String> {
        freeFunctionWords.union(semanticFunctionClasses.keys)
    }

    /// The ONLY substitutions allowed among meaning-bearing words: pure
    /// agreement, where the swap carries no new information.
    /// "the tests IS passing" → "ARE passing" is a fix; "IS" → "WAS" is a
    /// different time and "IS" → "WILL BE" a different commitment, so those
    /// groups are deliberately kept apart.
    static let interchangeableGroups: [Set<String>] = [
        ["am", "is", "are"],      // present-tense agreement
        ["was", "were"],          // past-tense agreement
        ["have", "has"],          // present perfect agreement
        ["do", "does"],           // present auxiliary agreement
    ]

    /// True when the edit changes the SEQUENCE of meaning-bearing words —
    /// a swap ("to"→"from", "might"→"will") or a reordering.
    ///
    /// This must be order-aware, and the first version wasn't: it compared word
    /// SETS, so "you owe me and I owe you" → "you owe you and I owe me" looked
    /// identical (same words, same counts) while flipping who owes whom. Codex
    /// found that one. Sets cannot see position, and position is exactly where
    /// this class of meaning lives.
    ///
    /// So: extract the ordered sequence of meaning-bearing words, normalise pure
    /// agreement (is/are → one symbol), and align the two sequences by longest
    /// common subsequence. Insertions alone are fine (adding "the", "to").
    /// Deletions alone are fine. But a deletion AND an insertion together is a
    /// substitution or a reordering however it is spelled — and that is how
    /// meaning changes.
    static func substitutesMeaningBearingWord(
        originalWords: [String], cleanedWords: [String]
    ) -> Bool {
        let before = semanticSequence(originalWords)
        let after = semanticSequence(cleanedWords)
        if before == after { return false }
        let common = longestCommonSubsequenceLength(before, after)
        let deleted = before.count - common
        let inserted = after.count - common
        return deleted > 0 && inserted > 0
    }

    /// The meaning-bearing words in order, with agreement variants collapsed so
    /// "the tests is passing" → "are passing" reads as no change at all.
    static func semanticSequence(_ words: [String]) -> [String] {
        words.compactMap { word in
            guard semanticFunctionClasses[word] != nil else { return nil }
            if let group = interchangeableGroups.first(where: { $0.contains(word) }) {
                return group.sorted().joined(separator: "|")
            }
            return word
        }
    }

    static func longestCommonSubsequenceLength(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1] + 1
                    : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Words that fix a clause in TIME. Their multiset must be unchanged before
    /// irregular-verb equivalence may be used, or "I HAVE SENT the report"
    /// becomes "I WILL SEND the report" — a finished job turned into a promise.
    static let tenseMarkers: Set<String> = [
        "will", "would", "shall", "have", "has", "had",
        "am", "is", "are", "was", "were", "be", "been",
    ]

    static func tenseMarkersUnchanged(_ originalWords: [String], _ cleanedWords: [String]) -> Bool {
        // Compare by GROUP, so present-tense agreement (is↔are) reads as
        // unchanged while a genuine time-shift (is→was, have→will) does not.
        func counted(_ words: [String]) -> [String: Int] {
            var counts: [String: Int] = [:]
            for word in words where tenseMarkers.contains(word) {
                let key = interchangeableGroups.first { $0.contains(word) }?.sorted().joined(separator: "|") ?? word
                counts[key, default: 0] += 1
            }
            return counts
        }
        return counted(originalWords) == counted(cleanedWords)
    }

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
        ["see", "sees", "seen", "seeing"],   // "saw" excluded: he says "the saw"
        ["know", "knows", "knew", "known", "knowing"],
        ["get", "gets", "got", "gotten", "getting"],
        ["give", "gives", "gave", "given", "giving"],
        ["find", "finds", "finding"],         // "found" excluded: "found a company"
        ["think", "thinks", "thought", "thinking"],
        ["tell", "tells", "told", "telling"],
        ["become", "becomes", "became", "becoming"],
        ["leave", "leaves", "leaving"],       // "left" excluded: "the left side"
        ["feel", "feels", "feeling"],         // "felt" excluded: the material
        ["bring", "brings", "brought", "bringing"],
        ["begin", "begins", "began", "begun", "beginning"],
        ["keep", "keeps", "kept", "keeping"],
        ["write", "writes", "wrote", "written", "writing"],
        ["hear", "hears", "heard", "hearing"],
        ["mean", "meant", "meaning"],         // "means" excluded: "by means of"
        ["meet", "meets", "met", "meeting"],
        ["run", "runs", "ran", "running"],
        ["pay", "pays", "paid", "paying"],
        ["speak", "speaks", "spoken", "speaking"],  // "spoke" excluded: a wheel spoke
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
        let cleanedAllWords = allWords(cleaned)
        // Two absolutes for grammar repair, checked before any allowance:
        // a meaning-bearing closed-class word may never be swapped for another
        // in its class, and tense markers must be untouched before irregular
        // verb forms are treated as equivalent.
        let tenseIntact = tenseMarkersUnchanged(originalWords, cleanedAllWords)
        // Applies under BOTH policies. The word-level checks below are
        // bag-of-words, so they cannot see "you owe me and I owe you" becoming
        // "you owe you and I owe me" — every word is still present. Verbatim is
        // meant to be the STRICTER mode, so it certainly must not permit a
        // reordering that reverses a debt.
        if substitutesMeaningBearingWord(originalWords: originalWords, cleanedWords: cleanedAllWords) {
            return false
        }
        // Only tokens that literally follow an apostrophe in the cleaned text
        // ("don't" → shard "t") are contraction shards — a blanket 1-char pass
        // would let cleanup invent "I"/"a" (Codex verification finding).
        let shards = contractionShards(cleaned)
        let heads = contractionHeads(cleaned)
        var insertionsUsed = 0
        let budget = policy == .grammarRepair ? insertionBudget(originalWordCount: originalWords.count) : 0
        for word in allWords(cleaned) where !originalSet.contains(word) {
            if shards.contains(word) { continue }              // "don't" → "don","t"
            // The head of an "n't" contraction of a word he actually said:
            // "do not" → "don't" gives the unspoken token "don". Nothing else
            // is forgiven here — the negation count is checked separately.
            if heads.contains(word), word.hasSuffix("n"),
               originalSet.contains(String(word.dropLast())) { continue }
            if word.allSatisfy({ $0.isNumber }) { continue }   // digit sets equal per step 3
            if sharesStem(word, withAnyOf: originalWords) { continue }
            if policy == .grammarRepair {
                // An irregular form of a verb he actually said is the same verb —
                // but only while the clause's tense is untouched.
                if tenseIntact, originalWords.contains(where: { sameIrregularVerb(word, $0) }) { continue }
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
                if tenseIntact, cleanedWords.contains(where: { sameIrregularVerb(word, $0) }) { continue }
                if isRemovableDisfluency(word, originalWords: originalWords) { continue }
                // Dropping a function word is a grammar fix ("interesting FOR
                // discuss" → "interested IN discussing"); dropping a content word
                // is losing what he said, and stays forbidden.
                if functionWords.contains(word) { continue }
            }
            return false
        }
        return true
    }

    /// English inflectional endings. A short stem may only grow by one of these
    /// — that is what separates morphology from a spelling coincidence.
    /// `eStemSuffixes` need a stem already ending in "e" ("use"→"used",
    /// "nice"→"nicer"), which is also what keeps "an"→"and" out.
    private static let inflectionSuffixes: Set<String> = ["s", "es", "ed", "ing", "er", "est", "ly"]
    private static let eStemSuffixes: Set<String> = ["d", "r", "st"]

    /// True when `longer` is `stem` plus an inflectional ending.
    static func isInflection(stem: String, of longer: String) -> Bool {
        // A 1-2 letter stem is not a stem, it is a coincidence: "we"+"ll",
        // "we"+"nt", "it"+"em", "in"+"to", "us"+"ed". Verb forms that short
        // ("go"→"going") are irregular anyway, and `sameIrregularVerb` knows
        // they are the same verb.
        guard stem.count >= 3, longer.count > stem.count, longer.hasPrefix(stem) else { return false }
        var suffix = String(longer.dropFirst(stem.count))
        // Regular verbs double the final consonant: "stop"→"stopped",
        // "ship"→"shipped", "trim"→"trimming". Un-double before matching, but
        // only the consonant that is actually there — "can"+"not" un-doubles to
        // "ot", "mat"+"tress" to "ress", and neither is an ending.
        if let last = stem.last, last.isLetter, !"aeiou".contains(last),
           suffix.count > 1, suffix.first == last {
            suffix.removeFirst()
        }
        if inflectionSuffixes.contains(suffix) { return true }
        return stem.hasSuffix("e") && eStemSuffixes.contains(suffix)
    }

    /// True when `word` looks like a morphological variant of some candidate:
    /// a short stem (≤4 chars) must GROW BY AN INFLECTION ("ask"~"asked",
    /// "use"~"used"); for longer words, a shared prefix of ≥4 chars covering at
    /// least half of the shorter word ("discussing"~"discuss").
    /// Homophones like "peel"~"pill", "czech"~"check", "tank"~"bank" fail both.
    ///
    /// The short case used to accept ANY prefix relation, which forgave dropping
    /// or inventing a whole content word whenever some short unrelated word
    /// happened to prefix it: "we need to dig a new well" → "… a new" passed
    /// because "we" prefixes "well". Same class: "we"/"went", "it"/"item",
    /// "in"/"into", "the"/"there". A prefix is not a stem.
    private static func sharesStem(_ word: String, withAnyOf candidates: [String]) -> Bool {
        for other in candidates where other != word {
            let common = zip(word, other).prefix { $0 == $1 }.count
            let shorter = min(word.count, other.count)
            if shorter <= 4 {
                let stem = word.count <= other.count ? word : other
                let grown = word.count <= other.count ? other : word
                if isInflection(stem: stem, of: grown) { return true }
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

    /// Letter-runs that immediately PRECEDE an apostrophe: the head half of a
    /// contraction ("don't" → "don", "couldn't" → "couldn"). `allWords` splits
    /// these off as words that were never spoken, so 4a needs to recognise them
    /// — but only the "n't" family, and only when the base word really was
    /// spoken ("don" is allowed only because "do" is in the original).
    static func contractionHeads(_ text: String) -> Set<String> {
        var heads = Set<String>()
        let lower = Array(text.lowercased())
        for i in lower.indices where lower[i] == "'" || lower[i] == "\u{2019}" {
            var j = i - 1
            var head = ""
            while j >= lower.startIndex, lower[j].isLetter {
                head.insert(lower[j], at: head.startIndex); j -= 1
            }
            if !head.isEmpty { heads.insert(head) }
        }
        return heads
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

    /// Keep the repairs that are safe instead of discarding all of them.
    ///
    /// `preservesMeaning` is all-or-nothing over the WHOLE text, and on a long
    /// dictation that is the difference between "repaired" and "untouched": the
    /// model fixes five things, one of them oversteps, and every fix — including
    /// the punctuation — is thrown away together. Live logs showed exactly that,
    /// which is why long dictations came back unrepaired while short ones
    /// improved.
    ///
    /// So: align the two texts sentence by sentence and judge each pair on its
    /// own. Safe sentences take the model's version, unsafe ones keep the
    /// original verbatim. Every guarantee still holds per sentence — nothing is
    /// weakened, the blast radius of one bad edit is just reduced from the whole
    /// dictation to the sentence it happened in.
    ///
    /// Alignment is only attempted when both sides have the same sentence count.
    /// If the model merged or split sentences we cannot say which repair belongs
    /// to which, so it falls back to the original all-or-nothing judgement.
    public static func safelyMerged(
        original: String, cleaned: String, policy: Policy = .verbatim
    ) -> String {
        if preservesMeaning(original: original, cleaned: cleaned, policy: policy) {
            return cleaned
        }
        let originalPieces = sentencePieces(original)
        let cleanedPieces = sentencePieces(cleaned)
        guard originalPieces.count == cleanedPieces.count,
              originalPieces.count > 1 else {
            return original
        }
        var kept = 0
        var merged = ""
        for (before, after) in zip(originalPieces, cleanedPieces) {
            let accepted = preservesMeaning(
                original: before.sentence, cleaned: after.sentence, policy: policy)
            merged += accepted ? after.sentence : before.sentence
            // The ORIGINAL's separator always wins, so paragraph breaks the user
            // dictated survive regardless of what the model did with them.
            merged += before.separator
            // Only a sentence with actual words counts as a repair kept — a bare
            // "." pseudo-sentence trivially "passes" and must not make the merge
            // path look successful.
            if accepted, !allWords(before.sentence).isEmpty, before.sentence != after.sentence {
                kept += 1
            }
        }
        return kept == 0 ? original : merged
    }

    /// Split into sentences WITH the whitespace that followed each, so the text
    /// can be rebuilt byte-for-byte.
    ///
    /// Rejoining tokens with a single space corrupted the source: "3.14" became
    /// "3. 14", "e.g." became "e. g.", and blank lines between paragraphs (which
    /// email mode is required to preserve) vanished. A period is only a sentence
    /// end when it is not inside a number, not part of a short abbreviation, and
    /// not one of a run of dots.
    static func sentencePieces(_ text: String) -> [(sentence: String, separator: String)] {
        let chars = Array(text)
        var pieces: [(String, String)] = []
        var current = ""
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            current.append(ch)
            index += 1
            guard ch == "." || ch == "!" || ch == "?" else { continue }
            if ch == "." {
                let next = index < chars.count ? chars[index] : " "
                if next.isNumber || next == "." { continue }          // 3.14, ellipsis
                // "e.g." / "p.m.": a 1-2 letter run preceded by another dot.
                let body = Array(current.dropLast())
                var letterRun = 0
                var scan = body.count - 1
                while scan >= 0, body[scan].isLetter { letterRun += 1; scan -= 1 }
                if letterRun >= 1, letterRun <= 2, scan >= 0, body[scan] == "." { continue }
            }
            var separator = ""
            while index < chars.count, chars[index].isWhitespace {
                separator.append(chars[index]); index += 1
            }
            pieces.append((current, separator))
            current = ""
        }
        if !current.isEmpty { pieces.append((current, "")) }
        return pieces
    }

    /// Sentence text only — for callers that don't need to rebuild the source.
    static func sentences(_ text: String) -> [String] {
        sentencePieces(text).map { $0.sentence.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }


    /// Whether dropping `word` is a disfluency removal rather than a loss of
    /// meaning. Deliberately NARROW — position-gated, never a bare word list.
    ///
    /// A previous attempt used a plain allowlist ("like", "well", "okay",
    /// "right"…) and an audit found 14 out of 14 contractor-realistic meaning
    /// losses: "dig a new WELL" → "dig a new", "the framing is OKAY" → "the
    /// framing is", "he was SERIOUSLY injured" → "he was injured". Membership in
    /// a set says nothing about the job a word is doing in a sentence.
    ///
    /// Research backs the caution: human annotators on the Switchboard corpus
    /// could not agree on discourse "like"/"well"/"so" (κ 0.40–0.43), and
    /// automatic detection peaks near 79% precision — one deletion in five wrong.
    /// So only the position that is unambiguous is allowed here: filler "like"
    /// immediately before a question word ("exactly LIKE why did you…"), which
    /// cannot be the verb "like" or the preposition "like". "I like it",
    /// "looks like rain" and "like this one" are all untouched.
    static func isRemovableDisfluency(_ word: String, originalWords: [String]) -> Bool {
        guard word == "like" else { return false }
        let questionWords: Set<String> = ["why", "what", "when", "where", "who", "how", "which"]
        for (index, token) in originalWords.enumerated() where token == "like" {
            let next = index + 1 < originalWords.count ? originalWords[index + 1] : ""
            if questionWords.contains(next) { return true }
        }
        return false
    }

}
