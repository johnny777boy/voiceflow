import Foundation

/// The two numbers that say whether the app is actually good, computed from
/// local history only: how fast text lands after you let go of the key, and how
/// often you had to touch it afterwards.
///
/// Median, not mean: one 12-second Whisper cold start would otherwise dominate
/// the average and hide the typical experience.
public struct DictationStats: Sendable, Equatable {
    /// Median seconds from key release to inserted text.
    public let medianInsertLatency: Double
    /// Fraction of inserted dictations the user did NOT edit afterwards (0…1).
    public let zeroEditRate: Double
    /// How many records the numbers are based on.
    public let sampleCount: Int

    public init(medianInsertLatency: Double, zeroEditRate: Double, sampleCount: Int) {
        self.medianInsertLatency = medianInsertLatency
        self.zeroEditRate = zeroEditRate
        self.sampleCount = sampleCount
    }

    public static let empty = DictationStats(medianInsertLatency: 0, zeroEditRate: 0, sampleCount: 0)

    /// Summarize the most recent records. Only records that were actually
    /// inserted count: a copy-only fallback never had a field to be edited in,
    /// so counting it would inflate the zero-edit rate.
    public static func summarize(_ records: [TranscriptRecord], limit: Int = 50) -> DictationStats {
        let inserted = records
            .filter { $0.insertionStrategy != nil && $0.insertionStrategy != .copyOnly }
            .prefix(limit)
        guard !inserted.isEmpty else { return .empty }
        let latencies = inserted.map(\.insertLatencySeconds).filter { $0 > 0 }.sorted()
        let median: Double
        if latencies.isEmpty {
            median = 0
        } else if latencies.count % 2 == 1 {
            median = latencies[latencies.count / 2]
        } else {
            median = (latencies[latencies.count / 2 - 1] + latencies[latencies.count / 2]) / 2
        }
        let untouched = inserted.filter { !$0.editedAfterInsert }.count
        return DictationStats(
            medianInsertLatency: median,
            zeroEditRate: Double(untouched) / Double(inserted.count),
            sampleCount: inserted.count
        )
    }
}
