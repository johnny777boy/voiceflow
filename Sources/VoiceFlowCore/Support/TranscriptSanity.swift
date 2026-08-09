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
        let words = normalized(text).split(separator: " ").map(String.init)
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
    public static func isFullyCorroborated(_ text: String, by other: String) -> Bool {
        let words = Set(normalized(text).split(separator: " ").map(String.init))
        let corroborating = Set(normalized(other).split(separator: " ").map(String.init))
        guard !words.isEmpty, !corroborating.isEmpty else { return false }
        return words.isSubset(of: corroborating)
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
