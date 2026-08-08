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

    /// Lowercase, strip everything but letters/digits/spaces, collapse whitespace.
    public static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == " ") ? ch : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
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
