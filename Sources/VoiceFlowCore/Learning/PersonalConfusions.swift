import Foundation

/// The mistakes this particular speaker's recogniser keeps making, learned from
/// his own corrections — and applied only where the evidence is overwhelming.
///
/// WHY THIS AND NOT A BIGGER MODEL. Measured 2026-08-20: swapping to full
/// large-v3 changed nothing on identical audio, and the remaining errors are not
/// generic — they are HIS. "a new well" heard as "and you walk". "rented" as
/// "wrench". "Claude Code" as "Cloud Code". A general model cannot fix a
/// personal confusion; a record of that person's confusions can.
///
/// THE DANGER, NAMED. This is the machinery that could reintroduce the exact
/// failure the whole product refuses: putting words on screen that he did not
/// say. So it is deliberately the most conservative thing in the codebase:
///
///  - it only ever applies a confusion HE HIMSELF corrected, at least
///    `minimumSightings` separate times;
///  - the misheard phrase must match EXACTLY, whole words, case-insensitively —
///    no fuzzy matching, no phonetic guessing at apply time;
///  - the replacement must be something he actually said, recorded from his own
///    correction, never invented;
///  - and every application is reported, so `Scripts/audit_cleanup.py` can show
///    what was changed and he can revoke any rule.
///
/// A confusion seen once is a coincidence. This is not a learning system that
/// generalises; it is a lookup table he built by being wronged the same way
/// repeatedly.
public struct PersonalConfusions: Sendable, Equatable {

    public struct Rule: Sendable, Equatable, Codable, Hashable {
        /// What the recogniser produces, lowercased.
        public var heard: String
        /// What he actually said, as he corrected it.
        public var said: String
        /// How many separate times he has corrected this exact confusion.
        public var sightings: Int

        public init(heard: String, said: String, sightings: Int = 1) {
            self.heard = heard.lowercased()
            self.said = said
            self.sightings = sightings
        }
    }

    /// Corrections below this are coincidences, not confusions.
    public static let minimumSightings = 2

    public let rules: [Rule]

    public init(rules: [Rule]) {
        // Longest first, so "a new well" wins over a rule for "well" alone.
        self.rules = rules
            .filter { $0.sightings >= Self.minimumSightings && !$0.heard.isEmpty }
            .sorted { $0.heard.count > $1.heard.count }
    }

    public struct Applied: Sendable, Equatable {
        public let text: String
        public let corrections: [Rule]
        public var isEmpty: Bool { corrections.isEmpty }
    }

    /// `text` with his known confusions repaired, plus a record of what changed.
    ///
    /// Whole-word, case-insensitive, exact. A confusion that merely resembles
    /// the text is not applied: the cost of a wrong correction here is a word he
    /// never said, and that is the one thing this product will not do.
    public func apply(to text: String) -> Applied {
        var result = text
        var used: [Rule] = []
        for rule in rules {
            guard let pattern = try? NSRegularExpression(
                pattern: "\\b" + NSRegularExpression.escapedPattern(for: rule.heard) + "\\b",
                options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            guard pattern.firstMatch(in: result, range: range) != nil else { continue }
            result = pattern.stringByReplacingMatches(
                in: result, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.said))
            used.append(rule)
        }
        return Applied(text: result, corrections: used)
    }

    /// Fold a fresh correction into the set, counting a repeat rather than
    /// duplicating it.
    public static func learning(_ rules: [Rule], heard: String, said: String) -> [Rule] {
        let key = heard.lowercased()
        guard !key.isEmpty, key != said.lowercased() else { return rules }
        var out = rules
        if let i = out.firstIndex(where: { $0.heard == key && $0.said == said }) {
            out[i].sightings += 1
        } else {
            out.append(Rule(heard: key, said: said))
        }
        return out
    }

    /// The confusions inside one correction: the spans that actually differ.
    ///
    /// Aligned by longest common subsequence so a single changed phrase is
    /// learned as one rule, rather than the whole sentence being memorised —
    /// memorising sentences would make the table useless on anything he has not
    /// said verbatim before.
    public static func confusions(heard: String, said: String) -> [(heard: String, said: String)] {
        let a = words(heard), b = words(said)
        guard !a.isEmpty, !b.isEmpty, a != b else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = a[i - 1] == b[j - 1]
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }
        var i = a.count, j = b.count
        var out: [(String, String)] = []
        var mine: [String] = [], theirs: [String] = []
        func flush() {
            defer { mine.removeAll(); theirs.removeAll() }
            // A pure insertion or deletion is not a CONFUSION — it is a missing
            // or extra word, which belongs to the recogniser, not to a lookup
            // table. Only a genuine substitution is learnable here.
            guard !mine.isEmpty, !theirs.isEmpty else { return }
            out.append((mine.reversed().joined(separator: " "),
                        theirs.reversed().joined(separator: " ")))
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
        return out.reversed()
    }

    public static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }
}
