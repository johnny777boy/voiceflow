import Foundation

/// Applies spoken → written vocabulary substitutions to a transcript.
///
/// Matching rules:
/// - A single left-to-right pass consumes the source, so a written form is never
///   re-scanned (e.g. after "next js" → "Next.js", the shorter "next" rule does
///   not fire on the output).
/// - At each position the longest matching phrase wins.
/// - Whitespace inside a spoken phrase matches any run of whitespace.
/// - Matches respect word boundaries: the character before a match must be a
///   non-alphanumeric (enforced against the source), and the phrase is followed
///   by a non-alphanumeric boundary.
/// - Case-insensitive by default; the written form's casing is used verbatim.
public struct VocabularyReplacer: Sendable {
    private struct Compiled {
        let regex: NSRegularExpression   // anchored, with trailing boundary lookahead
        let written: String
    }
    private let compiled: [Compiled]

    public init(entries: [VocabularyEntry]) {
        let enabled = entries.filter { $0.isEnabled && !$0.spoken.trimmingCharacters(in: .whitespaces).isEmpty }
        // Longest phrases first (word count, then character count).
        let sorted = enabled.sorted { lhs, rhs in
            let lw = lhs.spoken.split(separator: " ").count
            let rw = rhs.spoken.split(separator: " ").count
            if lw != rw { return lw > rw }
            return lhs.spoken.count > rhs.spoken.count
        }
        self.compiled = sorted.compactMap { entry in
            let tokens = entry.spoken
                .split(whereSeparator: { $0.isWhitespace })
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !tokens.isEmpty else { return nil }
            // No leading lookbehind: the left boundary is enforced manually against
            // the source during the scan. Trailing lookahead enforces the right edge.
            let pattern = tokens.joined(separator: "\\s+") + "(?![A-Za-z0-9])"
            var options: NSRegularExpression.Options = []
            if !entry.caseSensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            return Compiled(regex: regex, written: entry.written)
        }
    }

    /// Return `text` with all vocabulary substitutions applied.
    public func apply(to text: String) -> String {
        guard !compiled.isEmpty else { return text }
        let ns = text as NSString
        let length = ns.length
        var result = ""
        result.reserveCapacity(text.count)
        var i = 0

        while i < length {
            let atLeftBoundary: Bool = {
                if i == 0 { return true }
                let prev = ns.character(at: i - 1)
                return !isAlphanumeric(prev)
            }()

            var matchedLength = 0
            if atLeftBoundary {
                for item in compiled {
                    let searchRange = NSRange(location: i, length: length - i)
                    if let m = item.regex.firstMatch(in: text, options: [.anchored], range: searchRange),
                       m.range.location == i, m.range.length > 0 {
                        result += item.written
                        matchedLength = m.range.length
                        break
                    }
                }
            }

            if matchedLength > 0 {
                i += matchedLength
            } else {
                result += ns.substring(with: NSRange(location: i, length: 1))
                i += 1
            }
        }
        return result
    }

    private func isAlphanumeric(_ c: unichar) -> Bool {
        // ASCII alphanumeric check (matches the [A-Za-z0-9] boundary class).
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    }
}
