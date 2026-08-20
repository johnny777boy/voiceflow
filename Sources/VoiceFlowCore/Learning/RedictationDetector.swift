import Foundation

/// Recognises the owner's natural error report: saying it again.
///
/// He was right that reporting errors by hand is absurd — and he already
/// reports them without knowing it. When a dictation comes out wrong he does
/// not open a bug tracker, he re-dictates the sentence. Observed live
/// (2026-08-19): "We need to dig and you walk…" followed seconds later by the
/// same sentence said again. The pair IS the error report: the difference
/// between the two attempts is exactly what the recogniser got wrong.
///
/// This detector only OBSERVES. It never changes text, never blocks a
/// dictation; it mines (heard → said) confusion pairs and hands them to
/// `PersonalConfusions.learning`, where nothing is applied until a confusion
/// recurs and the strict application guards pass.
public enum RedictationDetector {

    /// Re-dictations happen within moments. Beyond this, a similar sentence is
    /// a person repeating themselves in conversation, not correcting the app.
    public static let windowSeconds: TimeInterval = 120

    /// Below this word-overlap ratio the two dictations are different thoughts.
    /// Learning "confusions" from unrelated sentences would poison the table
    /// with garbage pairs, so the bar errs high.
    public static let minimumOverlap = 0.6

    /// A learnable confusion is a SHORT swapped span. A long differing span
    /// means he rephrased, and rephrasings are not recognition errors.
    public static let maximumConfusionSpanWords = 4

    public struct Verdict: Sendable, Equatable {
        /// The substitution pairs the retry exposes (may be empty for a pure
        /// fragment retry, where the signal is truncation, not substitution).
        public let confusions: [(heard: String, said: String)]

        public static func == (a: Verdict, b: Verdict) -> Bool {
            a.confusions.count == b.confusions.count
                && zip(a.confusions, b.confusions).allSatisfy { $0.heard == $1.heard && $0.said == $1.said }
        }
    }

    /// Whether `current` is the owner correcting `previous`, and what the
    /// correction teaches. nil ⇒ just two ordinary consecutive dictations.
    public static func judge(
        previous: String, current: String, secondsApart: TimeInterval
    ) -> Verdict? {
        guard secondsApart >= 0, secondsApart <= windowSeconds else { return nil }
        let a = PersonalConfusions.words(previous)
        let b = PersonalConfusions.words(current)
        guard !a.isEmpty, !b.isEmpty else { return nil }
        // Identical repeats carry no correction signal — the text was fine and
        // something else went wrong (wrong field, no field).
        guard a != b else { return nil }

        // A cut-off fragment followed by the full sentence: "We need." → the
        // whole thing. The retry itself is the signal; there is nothing at the
        // word level to learn, because the fragment's words were all correct.
        if a.count < 6, b.count > a.count * 2, Array(b.prefix(min(2, a.count))) == Array(a.prefix(2)) {
            return Verdict(confusions: [])
        }

        // Same thought, said twice: most words shared, in order.
        let overlap = Double(lcsLength(a, b)) / Double(max(a.count, b.count))
        guard overlap >= minimumOverlap else { return nil }

        // The differing spans are the error — but only SHORT substitutions are
        // recognition errors. A long span is him rephrasing his own sentence.
        let mined = PersonalConfusions.confusions(heard: previous, said: current).filter {
            $0.heard.split(separator: " ").count <= maximumConfusionSpanWords
                && $0.said.split(separator: " ").count <= maximumConfusionSpanWords
        }
        guard !mined.isEmpty else { return nil }
        return Verdict(confusions: mined)
    }

    static func lcsLength(_ a: [String], _ b: [String]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
