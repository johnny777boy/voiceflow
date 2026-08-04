import Foundation

/// Abstraction over persisted dictation history (SQLite in production, in-memory
/// in tests).
public protocol HistoryStoring: AnyObject, Sendable {
    /// Insert or update a record.
    func save(_ record: TranscriptRecord) throws
    /// All records, newest first.
    func allRecords() throws -> [TranscriptRecord]
    /// Fetch a single record by id.
    func record(id: UUID) throws -> TranscriptRecord?
    /// Delete a record by id.
    func delete(id: UUID) throws
    /// Remove every record.
    func deleteAll() throws
    /// Trim history to at most `limit` newest records (0 = unlimited).
    func trim(toMostRecent limit: Int) throws
}
