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
    /// Flag a record as edited by the user after insertion (drives the zero-edit
    /// rate). Missing records are ignored — the record may have been trimmed.
    func setEditedAfterInsert(_ edited: Bool, id: UUID) throws
    /// Update the delivered text after two-phase delivery upgraded it in place,
    /// so history shows what is actually in the user's field. Missing records are
    /// ignored — the record may have been trimmed.
    func updateCleanText(_ text: String, id: UUID) throws
    /// Mark a record as flagged wrong by the user (the one-key error report).
    func setFlaggedWrong(id: UUID) throws
}

public extension HistoryStoring {
    func setFlaggedWrong(id: UUID) throws {
        guard var record = try record(id: id), !record.flaggedWrong else { return }
        record.flaggedWrong = true
        try save(record)
    }

    func setEditedAfterInsert(_ edited: Bool, id: UUID) throws {
        guard var record = try record(id: id), record.editedAfterInsert != edited else { return }
        record.editedAfterInsert = edited
        try save(record)
    }

    func updateCleanText(_ text: String, id: UUID) throws {
        guard var record = try record(id: id), record.cleanText != text else { return }
        record.cleanText = text
        try save(record)
    }
}
