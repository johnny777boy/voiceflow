import Foundation
import SQLite3

/// SQLite-backed persistent history. Uses the system libsqlite3 directly (no
/// external dependency). All access is serialized on an internal lock so the
/// store is safe to share across threads.
public final class SQLiteHistoryStore: HistoryStoring, @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    // SQLITE_TRANSIENT tells SQLite to copy bound text/blobs.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Open (creating if necessary) a history database at `url`.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = lastErrorMessage()
            sqlite3_close(db)
            throw VoiceFlowError.historyUnavailable("open failed: \(message)")
        }
        try execute("""
        CREATE TABLE IF NOT EXISTS transcripts (
            id TEXT PRIMARY KEY,
            rawText TEXT NOT NULL,
            cleanText TEXT NOT NULL,
            appBundleIdentifier TEXT,
            appName TEXT,
            mode TEXT NOT NULL,
            insertionStrategy TEXT,
            latencySeconds REAL NOT NULL,
            errorMessage TEXT,
            createdAt REAL NOT NULL,
            insertLatencySeconds REAL NOT NULL DEFAULT 0,
            editedAfterInsert INTEGER NOT NULL DEFAULT 0,
            transcribeSeconds REAL NOT NULL DEFAULT 0,
            arbiterSeconds REAL NOT NULL DEFAULT 0,
            cleanupSeconds REAL NOT NULL DEFAULT 0,
            engineUsed TEXT
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_transcripts_createdAt ON transcripts(createdAt DESC);")
        migrate()
    }

    /// Additive migrations for databases created by older builds. Columns are
    /// only ever APPENDED, because `readRow` addresses columns positionally —
    /// inserting one in the middle would silently mis-read every old row.
    /// `ALTER TABLE ADD COLUMN` fails harmlessly when the column already exists,
    /// which is exactly the "already migrated" case.
    private func migrate() {
        for column in [
            "insertLatencySeconds REAL NOT NULL DEFAULT 0",
            "editedAfterInsert INTEGER NOT NULL DEFAULT 0",
            "transcribeSeconds REAL NOT NULL DEFAULT 0",
            "arbiterSeconds REAL NOT NULL DEFAULT 0",
            "cleanupSeconds REAL NOT NULL DEFAULT 0",
            "engineUsed TEXT",
        ] {
            try? execute("ALTER TABLE transcripts ADD COLUMN \(column);")
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: - HistoryStoring

    public func save(_ record: TranscriptRecord) throws {
        lock.lock(); defer { lock.unlock() }
        let sql = """
        INSERT OR REPLACE INTO transcripts
        (id, rawText, cleanText, appBundleIdentifier, appName, mode, insertionStrategy, latencySeconds,
         errorMessage, createdAt, insertLatencySeconds, editedAfterInsert,
         transcribeSeconds, arbiterSeconds, cleanupSeconds, engineUsed)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, record.id.uuidString)
        bindText(stmt, 2, record.rawText)
        bindText(stmt, 3, record.cleanText)
        bindText(stmt, 4, record.appBundleIdentifier)
        bindText(stmt, 5, record.appName)
        bindText(stmt, 6, record.mode.rawValue)
        bindText(stmt, 7, record.insertionStrategy?.rawValue)
        sqlite3_bind_double(stmt, 8, record.latencySeconds)
        bindText(stmt, 9, record.errorMessage)
        sqlite3_bind_double(stmt, 10, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 11, record.insertLatencySeconds)
        sqlite3_bind_int(stmt, 12, record.editedAfterInsert ? 1 : 0)
        sqlite3_bind_double(stmt, 13, record.transcribeSeconds)
        sqlite3_bind_double(stmt, 14, record.arbiterSeconds)
        sqlite3_bind_double(stmt, 15, record.cleanupSeconds)
        bindText(stmt, 16, record.engineUsed)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VoiceFlowError.historyUnavailable("save failed: \(lastErrorMessage())")
        }
    }

    public func allRecords() throws -> [TranscriptRecord] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT * FROM transcripts ORDER BY createdAt DESC;")
        defer { sqlite3_finalize(stmt) }
        var out: [TranscriptRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let r = readRow(stmt) { out.append(r) }
        }
        return out
    }

    public func record(id: UUID) throws -> TranscriptRecord? {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT * FROM transcripts WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        if sqlite3_step(stmt) == SQLITE_ROW { return readRow(stmt) }
        return nil
    }

    public func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("DELETE FROM transcripts WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VoiceFlowError.historyUnavailable("delete failed: \(lastErrorMessage())")
        }
    }

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        try execute("DELETE FROM transcripts;")
    }

    public func trim(toMostRecent limit: Int) throws {
        guard limit > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("""
        DELETE FROM transcripts WHERE id NOT IN
        (SELECT id FROM transcripts ORDER BY createdAt DESC LIMIT ?);
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VoiceFlowError.historyUnavailable("trim failed: \(lastErrorMessage())")
        }
    }

    // MARK: - Row mapping

    /// Column order matches the CREATE TABLE definition.
    private func readRow(_ stmt: OpaquePointer?) -> TranscriptRecord? {
        guard let idText = columnText(stmt, 0), let id = UUID(uuidString: idText) else { return nil }
        let raw = columnText(stmt, 1) ?? ""
        let clean = columnText(stmt, 2) ?? ""
        let bundle = columnText(stmt, 3)
        let appName = columnText(stmt, 4)
        let mode = DictationMode(rawValue: columnText(stmt, 5) ?? "") ?? .cleanWriting
        let strategy = (columnText(stmt, 6)).flatMap { InsertionStrategy(rawValue: $0) }
        let latency = sqlite3_column_double(stmt, 7)
        let error = columnText(stmt, 8)
        let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        // Columns 10/11 exist only after the additive migration; a row read from
        // a database opened by an older build simply reports the defaults.
        let columns = sqlite3_column_count(stmt)
        let insertLatency = columns > 10 ? sqlite3_column_double(stmt, 10) : 0
        let edited = columns > 11 ? sqlite3_column_int(stmt, 11) != 0 : false
        let transcribe = columns > 12 ? sqlite3_column_double(stmt, 12) : 0
        let arbiter = columns > 13 ? sqlite3_column_double(stmt, 13) : 0
        let cleanup = columns > 14 ? sqlite3_column_double(stmt, 14) : 0
        let engine = columns > 15 ? columnText(stmt, 15) : nil
        return TranscriptRecord(
            id: id, rawText: raw, cleanText: clean, appBundleIdentifier: bundle, appName: appName,
            mode: mode, insertionStrategy: strategy, latencySeconds: latency,
            insertLatencySeconds: insertLatency, editedAfterInsert: edited,
            transcribeSeconds: transcribe, arbiterSeconds: arbiter,
            cleanupSeconds: cleanup, engineUsed: engine,
            errorMessage: error, createdAt: created)
    }

    // MARK: - Low-level helpers

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VoiceFlowError.historyUnavailable("prepare failed: \(lastErrorMessage())")
        }
        return stmt
    }

    private func execute(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let message = errMsg.map { String(cString: $0) } ?? lastErrorMessage()
            sqlite3_free(errMsg)
            throw VoiceFlowError.historyUnavailable("exec failed: \(message)")
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private func lastErrorMessage() -> String {
        if let cString = sqlite3_errmsg(db) { return String(cString: cString) }
        return "unknown error"
    }
}
