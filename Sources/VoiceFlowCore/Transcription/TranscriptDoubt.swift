import Foundation

/// Where the app suspects it misheard — flagged, never corrected.
///
/// THE PROBLEM THIS EXISTS FOR. A dictation app cannot check its transcription
/// against the truth, because whatever it heard BECOMES the truth. So a
/// mishearing is invisible: "rented" comes out as "wrench" and nothing anywhere
/// knows. The user finds it later, or never.
///
/// But the app is not blind — it throws away what it already knows:
///
///  1. **The recogniser's own confidence.** Whisper reports `avgLogprob` per
///     segment, near -0.1 when sure and below -0.8 when guessing.
///  2. **Two engines disagreeing.** Demonstrated on real audio 2026-08-19: the
///     small model wrote "wrench it out for the year", the large one "rent it
///     out for the year". The disagreement landed exactly on the error. A
///     second opinion localises a mistake even when neither side is trusted.
///  3. **A word that sounds like one of his own terms** but is not it.
///
/// FLAGS, NEVER FIXES. Every signal here is probabilistic, and acting on a
/// probabilistic signal is how an app starts changing words the user really
/// said — the failure this product exists to refuse. Doubt is reported so he
/// can glance at it; the delivered text stays exactly what was heard.
public struct TranscriptDoubt: Sendable, Equatable {

    public enum Kind: String, Sendable, Codable {
        /// A second engine heard something different here.
        case enginesDisagree
        /// The recogniser itself was unsure.
        case lowConfidence
        /// Sounds like a term in his vocabulary, but came out as something else.
        case soundsLikeAKnownTerm
    }

    public struct Span: Sendable, Equatable {
        public let text: String
        public let kind: Kind
        /// What the other engine heard, when that is the reason.
        public let alternative: String?
        public init(text: String, kind: Kind, alternative: String? = nil) {
            self.text = text
            self.kind = kind
            self.alternative = alternative
        }
    }

    public let spans: [Span]
    public var isEmpty: Bool { spans.isEmpty }
    public init(spans: [Span]) { self.spans = spans }

    /// Below this the recogniser is guessing rather than reading.
    public static let confidenceFloor: Double = 0.55

    /// Words the two engines disagree about, aligned by longest common
    /// subsequence so an inserted or dropped word shifts nothing after it.
    ///
    /// Only DIFFERENCES are returned. Agreement carries no information — both
    /// engines can be wrong the same way — but a disagreement is a place at
    /// least one of them is wrong, which is exactly what he should look at.
    public static func disagreements(primary: String, second: String) -> [Span] {
        let a = words(primary), b = words(second)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = a[i - 1] == b[j - 1]
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }
        var i = a.count, j = b.count
        var spans: [Span] = []
        var mine: [String] = [], theirs: [String] = []
        func flush() {
            guard !mine.isEmpty || !theirs.isEmpty else { return }
            spans.append(Span(text: mine.reversed().joined(separator: " "),
                              kind: .enginesDisagree,
                              alternative: theirs.isEmpty ? nil : theirs.reversed().joined(separator: " ")))
            mine.removeAll(); theirs.removeAll()
        }
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1] {
                flush(); i -= 1; j -= 1
            } else if j > 0, i == 0 || table[i][j - 1] >= table[i - 1][j] {
                theirs.append(b[j - 1]); j -= 1
            } else {
                mine.append(a[i - 1]); i -= 1
            }
        }
        flush()
        return spans.reversed()
    }

    /// Everything the app suspects about one dictation.
    public static func assess(
        text: String,
        confidence: Double?,
        secondOpinion: String?,
        vocabulary: [VocabularyEntry] = []
    ) -> TranscriptDoubt {
        var spans: [Span] = []
        if let secondOpinion, !secondOpinion.isEmpty {
            spans += disagreements(primary: text, second: secondOpinion)
        }
        // Whole-utterance doubt is only worth raising when nothing more precise
        // was found — naming specific words beats "something in here is wrong".
        if spans.isEmpty, let confidence, confidence < confidenceFloor {
            spans.append(Span(text: text, kind: .lowConfidence))
        }
        if !vocabulary.isEmpty {
            for miss in PhoneticVocabulary(entries: vocabulary).nearMisses(in: text) {
                spans.append(Span(text: miss.heard, kind: .soundsLikeAKnownTerm,
                                  alternative: miss.written))
            }
        }
        return TranscriptDoubt(spans: spans)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }
}
