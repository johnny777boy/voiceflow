import Foundation

/// A word the user replaced right after a dictation was inserted.
public struct WordCorrection: Sendable, Equatable, Hashable {
    /// What the recognizer produced.
    public let heard: String
    /// What the user changed it to.
    public let corrected: String

    public init(heard: String, corrected: String) {
        self.heard = heard
        self.corrected = corrected
    }
}

/// Finds single-word substitutions between the text we inserted and the text
/// sitting in the field a moment later — the signal that the recognizer got a
/// name wrong and the user fixed it by hand.
///
/// Deliberately narrow. It reports a correction ONLY when the two texts have the
/// same word count and differ in exactly one position, which is the shape of
/// "fix the misheard name" and almost nothing else. Any real editing — adding a
/// sentence, deleting a clause, rewriting — produces different word counts or
/// several differences, and yields nothing. False negatives cost a suggestion;
/// false positives would poison the user's vocabulary, so the asymmetry is
/// intentional.
public enum CorrectionDetector {

    /// Longest word we'll ever propose. Beyond this it isn't a name being fixed.
    static let maxWordLength = 40

    /// The single-word correction between `inserted` and `final`, if there is
    /// exactly one and it looks like a genuine word fix.
    public static func detect(inserted: String, final: String) -> WordCorrection? {
        let before = words(inserted)
        let after = words(final)
        guard !before.isEmpty, before.count == after.count else { return nil }

        var difference: (String, String)?
        for (lhs, rhs) in zip(before, after) where lhs != rhs {
            if difference != nil { return nil }        // more than one edit: not a word fix
            difference = (lhs, rhs)
        }
        guard let (heard, corrected) = difference else { return nil }
        guard isPlausibleFix(heard: heard, corrected: corrected) else { return nil }
        return WordCorrection(heard: heard, corrected: corrected)
    }

    /// Whether the field's text still looks like our dictation at all. Used to
    /// decide whether the user edited it (zero-edit metric) versus replaced it.
    public static func textWasEdited(inserted: String, final: String) -> Bool {
        let a = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = final.trimmingCharacters(in: .whitespacesAndNewlines)
        return !a.isEmpty && a != b
    }

    /// Whether `word` appears in `text` as a whole word, ignoring case and
    /// surrounding punctuation. Used to confirm a corrected word was one we
    /// inserted rather than something the user typed themselves.
    public static func containsWord(_ word: String, in text: String) -> Bool {
        let needle = core(word).lowercased()
        guard !needle.isEmpty else { return false }
        return words(text).contains { core($0).lowercased() == needle }
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }).map(String.init)
    }

    /// Guards against learning noise: punctuation-only or case-only changes,
    /// deletions, numbers, and anything that isn't a word.
    static func isPlausibleFix(heard: String, corrected: String) -> Bool {
        let heardCore = core(heard)
        let correctedCore = core(corrected)
        guard !heardCore.isEmpty, !correctedCore.isEmpty else { return false }
        guard heardCore.count <= maxWordLength, correctedCore.count <= maxWordLength else { return false }
        // Case or punctuation only — the cleanup rules own that, not vocabulary.
        guard heardCore.lowercased() != correctedCore.lowercased() else { return false }
        // Both sides must be word-like; a number swap is a fact change, not a
        // recognizer error we should encode.
        guard heardCore.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }),
              correctedCore.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" || $0 == "." }) else { return false }
        // The correction must look like a NAME or jargon, not an ordinary word.
        //
        // This is the load-bearing guard. Accepting a suggestion installs an
        // unconditional case-insensitive whole-word rewrite on every future
        // transcript, so learning an everyday pair ("form"→"from") would go on to
        // rewrite the word every time the user legitimately says it — the exact
        // word-replacement the verbatim policy forbids, just laundered through a
        // button. A capital or a dotted compound is the cheap, reliable signal
        // that we're looking at a name ("sara"→"Sarah", "next js"→"Next.js").
        // Lowercase jargon is a deliberate false negative: it costs a suggestion,
        // never the user's words.
        guard correctedCore.contains(where: { $0.isUppercase }) || correctedCore.contains(".") else {
            return false
        }
        return true
    }

    /// Whether the text we delivered is still present, verbatim, in the field.
    ///
    /// This is the zero-edit signal. Comparing the WHOLE field before and after
    /// would count "the user kept typing after the dictation" as an edit, which
    /// is the single most common thing anyone does and says nothing about our
    /// accuracy. What matters is whether our sentence survived untouched.
    public static func insertedTextSurvived(_ insertedText: String, in final: String) -> Bool {
        let needle = collapseWhitespace(insertedText)
        guard !needle.isEmpty else { return true }
        return collapseWhitespace(final).contains(needle)
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }).joined(separator: " ")
    }

    /// Strip surrounding punctuation so "Sarah," and "Sarah" are the same word.
    static func core(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]{}…"))
    }
}
