import Foundation

/// Trims the dead air before the user starts speaking.
///
/// MEASURED 2026-08-19, on his own recordings. Every clip carried 1.6–2.7
/// seconds of near-silence at the front — he holds the key, then begins. Whisper
/// handles that badly: it is known to hallucinate on silence, and on his first
/// A/B sentence the leading gap cost five words and invented one:
///
///   as recorded : "Codex, verify branch before merging to domain. Thank you."
///   trimmed     : "Ask Codex to verify the branch before we merge it to domain."
///
/// Eight errors became one, and the "Thank you" he never said disappeared — the
/// complaint that started this whole investigation.
///
/// SAFETY. This can only ever remove audio from the FRONT, never from the middle
/// or end, and it keeps a deliberate lead-in so a soft first consonant survives.
/// The threshold is derived from the clip's own noise floor rather than being
/// absolute, because his recordings peak at 0.15–0.22 where healthy speech peaks
/// near 0.5 — a fixed threshold tuned on loud audio would eat his quiet words.
/// If nothing looks like speech, the samples are returned UNCHANGED: deciding a
/// clip is empty is the phantom filter's job, not this one's.
public enum LeadingSilence {

    /// Kept before the detected onset, so a quiet "Ask" is never clipped.
    public static let leadInSeconds: Double = 0.2
    /// Never trim unless there is meaningfully more dead air than the lead-in.
    public static let minimumTrimSeconds: Double = 0.35

    /// Where speech begins, in samples, or nil when the clip never rises above
    /// its own noise floor.
    public static func onset(_ samples: [Float], sampleRate: Double) -> Int? {
        let frame = max(1, Int(sampleRate * 0.01))          // 10 ms
        guard samples.count > frame * 4 else { return nil }
        func rms(_ range: Range<Int>) -> Float {
            var sum: Float = 0
            for i in range { sum += samples[i] * samples[i] }
            return (sum / Float(range.count)).squareRoot()
        }
        // The floor is measured from the quietest tenth of the clip, so a noisy
        // room raises the bar instead of defeating it.
        var frames: [Float] = []
        var i = 0
        while i + frame <= samples.count {
            frames.append(rms(i..<(i + frame)))
            i += frame
        }
        guard !frames.isEmpty else { return nil }
        let sorted = frames.sorted()
        let floor = sorted[max(0, sorted.count / 10)]
        let peak = sorted.last ?? 0
        // Speech has to stand clearly above the floor AND be a real fraction of
        // the clip's own loudest moment; either test alone misfires on a clip
        // that is all noise or all speech.
        let threshold = max(floor * 4, peak * 0.12)
        guard threshold > 0 else { return nil }
        for (index, value) in frames.enumerated() where value > threshold {
            // Require the level to persist, so one click or breath is not an onset.
            let next = index + 1 < frames.count ? frames[index + 1] : value
            if next > threshold * 0.5 { return index * frame }
        }
        return nil
    }

    /// `samples` with the leading dead air removed, or unchanged when there is
    /// nothing worth removing.
    public static func trimmed(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard let onset = onset(samples, sampleRate: sampleRate) else { return samples }
        let leadIn = Int(sampleRate * leadInSeconds)
        let cut = onset - leadIn
        guard cut > Int(sampleRate * minimumTrimSeconds) else { return samples }
        return Array(samples[cut...])
    }
}
