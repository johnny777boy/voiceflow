import Foundation

/// A thread-safe, non-persistent history store. Used in tests and as a safe
/// fallback if the SQLite store cannot be opened.
public final class InMemoryHistoryStore: HistoryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: TranscriptRecord] = [:]

    public init() {}

    public func save(_ record: TranscriptRecord) throws {
        lock.lock(); defer { lock.unlock() }
        records[record.id] = record
    }

    public func allRecords() throws -> [TranscriptRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func record(id: UUID) throws -> TranscriptRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[id]
    }

    public func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        records[id] = nil
    }

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        records.removeAll()
    }

    public func trim(toMostRecent limit: Int) throws {
        guard limit > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let sorted = records.values.sorted { $0.createdAt > $1.createdAt }
        guard sorted.count > limit else { return }
        for record in sorted[limit...] { records[record.id] = nil }
    }
}
