import Foundation

/// Detects Whisper's canonical silence-hallucinations ("Thank you.", "Thanks for
/// watching!", subtitle credits) so they are never inserted as dictation.
///
/// Design constraints from adversarial review — this filter must be provably
/// unable to eat real speech:
/// - WHOLE-output match only: a phrase inside a longer utterance never matches,
///   so a dictated email ending in "thank you" survives untouched.
/// - Corroboration required: even a whole-output match is dropped ONLY with an
///   independent doubt signal (low decoder confidence, or near-silent audio).
///   A confidently transcribed, audible "Thank you." is delivered.
/// - Fail-open: with no signals available, nothing is ever dropped.
public enum TranscriptSanity {

    /// Frequency-ranked phantom phrases from the Whisper hallucination literature
    /// ("thank you" alone is ~25% of all non-speech hallucinations) plus the
    /// classic YouTube-outro/subtitle-credit strings. Compared against the
    /// NORMALIZED full transcript.
    public static let phantomPhrases: Set<String> = [
        "thank you",
        "thank you thank you",
        "thank you very much",
        "thank you so much",
        "thank god",
        "oh thank god",
        "thanks for watching",
        "thank you for watching",
        "thank you so much for watching",
        "thank you for listening",
        "thanks a lot",
        "thanks",
        "bye",
        "bye bye",
        "see you",
        "see you later",
        "see you next time",
        "okay",
        "so",
        "you",
        "the end",
        "oh my god",
        "please subscribe",
        "please like and subscribe",
        "subtitles by the amara org community",
        "subtitles by the amaraorg community",
    ]

    /// Whole-output membership in the phantom family. Used to trigger the
    /// second-opinion arbiter — safe to be generous here, because a match alone
    /// never drops anything; it only prompts an independent listen.
    public static func isPhantomPhrase(_ text: String) -> Bool {
        phantomPhrases.contains(normalized(text))
    }

    /// The subset that is essentially NEVER deliberate dictation — YouTube-outro
    /// and subtitle-credit boilerplate. Only these justify arbitration at ANY
    /// clip length; everyday phrases ("okay", "thank you", "bye") are legitimate
    /// dictations when spoken deliberately over a longer clip, and are checked
    /// only under the short-clip suspicion arm (adversarial-review finding F1:
    /// an any-length check risked eating a real long "Thank you so much.").
    public static let outroPhrases: Set<String> = [
        "thanks for watching",
        "thank you for watching",
        "thank you so much for watching",
        "thank you for listening",
        "please subscribe",
        "please like and subscribe",
        "subtitles by the amara org community",
        "subtitles by the amaraorg community",
        "the end",
    ]

    public static func isOutroPhrase(_ text: String) -> Bool {
        outroPhrases.contains(normalized(text))
    }

    /// Lowercase, strip everything but letters/digits/spaces, collapse whitespace.
    public static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == " ") ? ch : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// True when the transcript looks like the decoder read back its own context
    /// prompt instead of transcribing the audio.
    ///
    /// Whisper consumes bias terms as "text that came just before this audio"
    /// (`<|startofprev|>`). On low-information audio the decoder can simply
    /// CONTINUE that text — emitting the glossary as the transcript. That would
    /// insert words the user never said, and, since some of those terms are read
    /// off the screen, leak window contents into whatever they're typing in.
    ///
    /// Detection is deliberately hard to trip: at least four words, at least
    /// three DISTINCT prompt terms, and a majority of the content words matching
    /// the prompt. A genuine sentence that happens to use one or two vocabulary
    /// names never qualifies ("tell Sarah about Kubernetes" is 2 of 4).
    public static func looksLikePromptEcho(text: String, promptTerms: [String]) -> Bool {
        guard !promptTerms.isEmpty else { return false }
        let normalizedText = normalized(text)
        // THE FRAMING IS PART OF THE PROMPT. The bias prompt is a whole sentence
        // — "The following transcript mentions X, Y, Z. It is written in ordinary
        // sentence case." — and this check used to know only about the terms, so
        // a model that parroted the framing back had it delivered as the user's
        // dictation. That is the invented-words failure in its purest form, and
        // it is why biasing could not be switched on. Nobody says these
        // sentences out loud, so an exact-phrase test carries no risk to real
        // speech.
        for framing in [TranscriptionContext.promptLeadIn, TranscriptionContext.promptTrailer] {
            let phrase = normalized(framing)
            guard phrase.split(separator: " ").count >= 3 else { continue }
            if normalizedText.contains(phrase) { return true }
        }
        let words = normalizedText.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return false }
        // Multi-word terms contribute each of their words.
        var termWords = Set<String>()
        for term in promptTerms {
            for word in normalized(term).split(separator: " ") { termWords.insert(String(word)) }
        }
        guard !termWords.isEmpty else { return false }
        let matches = words.filter { termWords.contains($0) }
        guard Set(matches).count >= 3 else { return false }
        return Double(matches.count) / Double(words.count) >= 0.6
    }

    /// Whether EVERY word in `text` also appears in `other`.
    ///
    /// Used to decide whether a transcript suspected of being a prompt echo can be
    /// delivered as-is, given a second engine's transcript of the same audio that
    /// had no prompt to echo. If every word we would deliver was independently
    /// produced by that engine, none of them came from the glossary, and the text
    /// is safe. If even one word is uncorroborated, it is not.
    ///
    /// This is deliberately an EXACT property rather than a similarity score.
    /// Three separate scoring thresholds were tried here and all three shipped a
    /// hole, because "mostly agrees" is not the question — a transcript that
    /// agrees on four words out of five still inserts the fifth, and the fifth is
    /// exactly the word the user never said. Partial agreement is precisely the
    /// shape of a partial echo: the user says three of their vocabulary terms, the
    /// decoder completes the glossary with the other two.
    ///
    /// The cost is real and accepted: when the engines differ on any word the
    /// caller falls back to the other engine's transcript, which can mean losing a
    /// better spelling this one had. Inserting words the user never said is the
    /// failure this codebase treats as unacceptable; losing one is not.
    /// Counts OCCURRENCES, not distinct words. A set comparison called
    /// "Sarah Kubernetes Grafana Sarah" fully corroborated by "Sarah Kubernetes
    /// Grafana" — identical word sets — and delivered the repeated name the other
    /// engine never said. Every token must be spent against a matching token in
    /// the corroborating transcript, so a word appearing twice needs to have been
    /// heard twice.
    public static func isFullyCorroborated(_ text: String, by other: String) -> Bool {
        let words = corroborationTokens(text)
        let corroborating = corroborationTokens(other)
        guard !words.isEmpty, !corroborating.isEmpty else { return false }
        var available: [String: Int] = [:]
        for word in corroborating { available[word, default: 0] += 1 }
        for word in words {
            guard let remaining = available[word], remaining > 0 else { return false }
            available[word] = remaining - 1
        }
        return true
    }

    /// Tokenizer for corroboration — deliberately NOT `normalized`.
    ///
    /// `normalized` throws away every non-alphanumeric character, which is right
    /// for matching stock phantom phrases and wrong here: it maps "C++" and "C"
    /// onto the same token, so an echoed "C++" counted as corroborated by an
    /// arbiter that only ever said "C", and the symbols were delivered. Same for
    /// "Next.js" against "next", or "C#" against "C".
    ///
    /// So: case-fold, strip only the punctuation that SURROUNDS a word (sentence
    /// periods, commas, quotes, brackets), and keep everything inside it. Two
    /// tokens corroborate only if they are the same token, symbols included.
    ///
    /// The trim is asymmetric on purpose. A leading `.` followed by a letter or
    /// digit is part of the word (".NET", ".env") — blanket-trimming both ends
    /// collapsed ".NET" into "net", so an echoed ".NET" was corroborated by an
    /// arbiter that only said "NET" and the symbol was delivered. A TRAILING dot
    /// is still stripped: in prose it is overwhelmingly the sentence period, and
    /// keeping it would break corroboration of the identical spoken word at a
    /// sentence boundary.
    static func corroborationTokens(_ text: String) -> [String] {
        let edges = CharacterSet(charactersIn: ".,;:!?\"'“”‘’()[]{}…«»")
        let isEdge: (Character) -> Bool = { $0.unicodeScalars.allSatisfy(edges.contains) }
        return text
            .split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" })
            .map { raw -> String in
                var token = Substring(raw).lowercased()[...]
                while let last = token.last, isEdge(last) {
                    token = token.dropLast()
                }
                while let first = token.first, isEdge(first) {
                    if first == ".", let next = token.dropFirst().first,
                       next.isLetter || next.isNumber { break }
                    token = token.dropFirst()
                }
                return String(token)
            }
            .filter { !$0.isEmpty }
    }

    /// True when the ENTIRE transcript is a known phantom phrase AND at least one
    /// doubt signal corroborates (decoder avg log-prob below -1.0, or the clip
    /// was near-silent). Both-nil signals ⇒ always false (fail-open).
    public static func isLikelyHallucination(
        text: String,
        minAvgLogProb: Float?,
        nearSilence: Bool
    ) -> Bool {
        guard phantomPhrases.contains(normalized(text)) else { return false }
        let lowConfidence = (minAvgLogProb ?? 0) < -1.0
        return lowConfidence || nearSilence
    }
}
