import Foundation

/// A correction the user has made enough times that it's worth offering as a
/// vocabulary entry.
public struct VocabularySuggestion: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(heard.lowercased())→\(corrected.lowercased())" }
    /// What the recognizer keeps producing.
    public var heard: String
    /// What the user keeps changing it to.
    public var corrected: String
    /// How many times this exact fix has been observed.
    public var occurrences: Int
    public var lastSeen: Date

    public init(heard: String, corrected: String, occurrences: Int = 1, lastSeen: Date = Date()) {
        self.heard = heard
        self.corrected = corrected
        self.occurrences = occurrences
        self.lastSeen = lastSeen
    }
}

/// Counts repeated corrections on disk and surfaces the ones worth offering.
///
/// **It never changes what the user says.** The product rule is propose, don't
/// mutate: a suggestion appears in Settings ▸ Vocabulary and does nothing at all
/// until the user accepts it. Silently rewriting a word the recognizer heard
/// correctly is exactly the failure the verbatim guard exists to prevent, and an
/// auto-learned dictionary is the most likely way to reintroduce it.
///
/// Storage is a small JSON file next to the other local data — on-device, like
/// everything else here.
public final class SuggestedVocabularyStore: @unchecked Sendable {
    /// Times a correction must recur before it's offered.
    public static let threshold = 3
    /// Corrections older than this are forgotten, so a one-off run of typos in
    /// one afternoon never becomes a permanent suggestion.
    public static let memoryWindow: TimeInterval = 60 * 60 * 24 * 30

    private let url: URL
    private let lock = NSLock()
    private var entries: [VocabularySuggestion]

    public init(url: URL) {
        self.url = url
        self.entries = Self.load(from: url)
    }

    /// Every pending suggestion at or above the threshold, most-corrected first.
    public func readySuggestions(now: Date = Date()) -> [VocabularySuggestion] {
        lock.lock(); defer { lock.unlock() }
        return entries
            .filter { $0.occurrences >= Self.threshold && now.timeIntervalSince($0.lastSeen) < Self.memoryWindow }
            .sorted { $0.occurrences > $1.occurrences }
    }

    /// All tracked corrections (including below-threshold ones), for diagnostics.
    public func allTracked() -> [VocabularySuggestion] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// Record one observed correction. Returns the suggestion if this observation
    /// pushed it to the threshold — i.e. the moment it becomes worth showing.
    @discardableResult
    public func record(_ correction: WordCorrection, now: Date = Date()) -> VocabularySuggestion? {
        lock.lock(); defer { lock.unlock() }
        prune(now: now)
        let key = VocabularySuggestion(heard: correction.heard, corrected: correction.corrected).id
        if let index = entries.firstIndex(where: { $0.id == key }) {
            entries[index].occurrences += 1
            entries[index].lastSeen = now
            let reached = entries[index].occurrences == Self.threshold ? entries[index] : nil
            persist()
            return reached
        }
        entries.append(VocabularySuggestion(
            heard: correction.heard, corrected: correction.corrected, occurrences: 1, lastSeen: now))
        persist()
        return Self.threshold <= 1 ? entries.last : nil
    }

    /// Forget a suggestion — the user either accepted it (it's vocabulary now) or
    /// dismissed it (they don't want it offered again).
    public func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.id == id }
        persist()
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        persist()
    }

    // MARK: - Persistence (best-effort: a suggestion is never worth an error)

    private func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.lastSeen) >= Self.memoryWindow }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func load(from url: URL) -> [VocabularySuggestion] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([VocabularySuggestion].self, from: data) else { return [] }
        return decoded
    }
}
