import Foundation

/// Per-dictation recognition context: the words this particular dictation is
/// LIKELY to contain, handed to the engine so it can bias its decoding toward
/// them. Two sources, in priority order:
///
///  1. `vocabularyTerms` — the user's own saved vocabulary (their spelling of
///     names, products, jargon). Highest value, lowest noise, so it goes first
///     and is never truncated away by screen terms.
///  2. `screenTerms` — proper nouns harvested from the frontmost window's TEXT
///     via Accessibility (never a screenshot, never uploaded). This is the
///     "the recognizer knows what you're looking at" trick: reply to a message
///     mentioning "Kubernetes" and Whisper stops hearing "cuber netties".
///
/// The struct itself is pure and testable; harvesting lives behind
/// `ScreenContextProviding` in the app layer.
public struct TranscriptionContext: Sendable, Equatable {
    public var vocabularyTerms: [String]
    public var screenTerms: [String]

    public static let empty = TranscriptionContext()

    public init(vocabularyTerms: [String] = [], screenTerms: [String] = []) {
        self.vocabularyTerms = vocabularyTerms
        self.screenTerms = screenTerms
    }

    public var isEmpty: Bool { vocabularyTerms.isEmpty && screenTerms.isEmpty }

    /// Vocabulary first, then screen terms, de-duplicated case-insensitively,
    /// order preserved.
    public var orderedTerms: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for term in vocabularyTerms + screenTerms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted { out.append(trimmed) }
        }
        return out
    }

    /// The initial-prompt text for a Whisper-style decoder, capped so it can
    /// never crowd out the audio in the decoder's context window.
    ///
    /// Whisper consumes this as "text that came just before this audio", so a
    /// plain comma-separated glossary is the shape that biases without inviting
    /// the model to continue a sentence. Terms are added whole — a truncated
    /// term would bias toward a word fragment.
    /// Lead-in that makes the prompt read as prose. Whisper conditions on the
    /// prompt's FORM as much as its vocabulary: measured 2026-08-19 with
    /// VoiceFlowBench, a bare list of Capitalised Terms made it emit "The
    /// Whisper Flow Parity Work Needs Aware Benchmark on My Voice" — the list's
    /// own style copied into the transcript. A sentence gets the vocabulary
    /// benefit without the style contamination.
    public static let promptLeadIn = "The following transcript mentions "
    /// Closing clause in plain sentence case. The terms alone leave the model
    /// imitating a list of Capitalised Names; a normal sentence after them
    /// re-anchors ordinary prose style.
    public static let promptTrailer = ". It is written in ordinary sentence case."

    /// The bias prompt: a compact natural sentence ending in the terms.
    ///
    /// Terms sit at the END deliberately — later tokens exert more influence on
    /// Whisper's decoding, and only the last 224 tokens of a prompt are
    /// consumed at all.
    public func promptText(maxCharacters: Int = 380) -> String {
        guard maxCharacters > 0 else { return "" }
        // The lead-in and the closing "." are part of the budget: a cap that
        // only counted the terms would silently overrun it.
        let overhead = Self.promptLeadIn.count + Self.promptTrailer.count
        guard maxCharacters > overhead else { return "" }
        let budget = maxCharacters - overhead
        var parts: [String] = []
        var length = 0
        for term in orderedTerms {
            let addition = parts.isEmpty ? term.count : term.count + 2   // ", "
            if length + addition > budget { continue }
            parts.append(term)
            length += addition
        }
        guard !parts.isEmpty else { return "" }
        return Self.promptLeadIn + parts.joined(separator: ", ") + Self.promptTrailer
    }
}
