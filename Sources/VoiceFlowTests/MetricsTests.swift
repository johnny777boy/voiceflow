import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

/// Phase 2 — the numbers have to be honest, or they're worse than no numbers.
/// Cleanup stage whose cost is an injected-clock advance, so stage timing is
/// deterministic in tests.
private final class ClockCostCleanup: CleanupProviding, @unchecked Sendable {
    let clock: MockTimeSource
    let cost: TimeInterval
    init(clock: MockTimeSource, cost: TimeInterval) {
        self.clock = clock
        self.cost = cost
    }
    func clean(_ rawText: String, context: CleanupContext) async throws -> String {
        clock.advance(by: cost)
        return rawText
    }
}

func runMetricsTests(_ suite: TestSuite) {

    func record(
        insertLatency: Double,
        edited: Bool = false,
        strategy: InsertionStrategy? = .clipboardPaste,
        secondsAgo: Double = 0
    ) -> TranscriptRecord {
        TranscriptRecord(
            rawText: "raw", cleanText: "clean", mode: .cleanWriting,
            insertionStrategy: strategy, latencySeconds: insertLatency + 2,
            insertLatencySeconds: insertLatency, editedAfterInsert: edited,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000 - secondsAgo)
        )
    }

    suite.test("stats: median ignores an outlier that a mean would hide behind") { s in
        let stats = DictationStats.summarize([
            record(insertLatency: 1.0), record(insertLatency: 1.2),
            record(insertLatency: 1.1), record(insertLatency: 30.0),
        ])
        s.expectEqual(stats.medianInsertLatency, 1.15)
        s.expectEqual(stats.sampleCount, 4)
    }

    suite.test("stats: zero-edit rate counts only inserted dictations") { s in
        // Copy-only never had a field to edit — counting it would inflate the rate.
        let stats = DictationStats.summarize([
            record(insertLatency: 1, edited: true),
            record(insertLatency: 1, edited: false),
            record(insertLatency: 1, strategy: .copyOnly),
            record(insertLatency: 1, strategy: nil),
        ])
        s.expectEqual(stats.sampleCount, 2)
        s.expectEqual(stats.zeroEditRate, 0.5)
    }

    suite.test("stats: no usable records yields empty, not a fabricated number") { s in
        s.expectEqual(DictationStats.summarize([]), .empty)
        s.expectEqual(DictationStats.summarize([record(insertLatency: 1, strategy: .copyOnly)]), .empty)
    }

    suite.test("stats: records from before the metric existed don't skew the median") { s in
        // insertLatencySeconds == 0 means "not measured", not "instant".
        let stats = DictationStats.summarize([
            record(insertLatency: 0), record(insertLatency: 2.0), record(insertLatency: 0),
        ])
        s.expectEqual(stats.medianInsertLatency, 2.0)
        s.expectEqual(stats.sampleCount, 3)
    }

    suite.test("history: the edit flag round-trips through SQLite") { s in
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-metrics-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        s.expectNoThrow {
            let store = try SQLiteHistoryStore(url: url)
            let saved = record(insertLatency: 1.75)
            try store.save(saved)
            try store.setEditedAfterInsert(true, id: saved.id)
            let reloaded = try store.record(id: saved.id)
            s.expectEqual(reloaded?.insertLatencySeconds, 1.75)
            s.expectEqual(reloaded?.editedAfterInsert, true)
            // Unknown ids are ignored rather than throwing.
            try store.setEditedAfterInsert(true, id: UUID())
        }
    }

    suite.test("stages: the record itemizes transcribe, arbiter, and cleanup time") { s in
        // The clock only moves when a stage runs, so each stage's cost is exactly
        // attributable — the whole point of the instrumentation.
        let clock = MockTimeSource()
        let transcriber = MockTranscriber()
        transcriber.onTranscribe = { clock.advance(by: 2.0) }   // decode costs 2s
        transcriber.resultToReturn = TranscriptionResult(
            text: "the quick brown fox jumps over the lazy dog today friend",
            engineName: "whisper", decodeSeconds: 1.2, arbiterSeconds: 0.8)
        let controller = DictationController(
            audio: MockAudioRecorder(), transcriber: transcriber,
            cleanup: ClockCostCleanup(clock: clock, cost: 0.5),
            inserter: MockTextInserter(), activeApp: MockActiveAppProvider(),
            history: InMemoryHistoryStore(), settings: .default, time: clock
        )
        let result = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            return try? await controller.finishRecording()
        }
        s.expectNotNil(result)
        guard let record = result?.record else { return }
        s.expectEqual(record.transcribeSeconds, 2.0)
        s.expectEqual(record.cleanupSeconds, 0.5)
        s.expectEqual(record.arbiterSeconds, 0.8)   // reported by the engine
        s.expectEqual(record.engineUsed, "whisper")
        s.expect(record.insertLatencySeconds >= 2.5, "stages missing from the total")
    }

    suite.test("stages: a REAL pre-instrumentation database migrates and reads correctly") { s in
        // The other round-trip test writes zeros into a NEW-schema DB, which never
        // exercises the thing the positional-column rule exists to protect. This
        // builds the actual 12-column schema an installed build created, inserts a
        // row through it, then opens it with the current store — the upgrade path
        // a real user takes.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.sqlite")
        let id = UUID()
        let oldSchema = """
        CREATE TABLE transcripts (
            id TEXT PRIMARY KEY, rawText TEXT NOT NULL, cleanText TEXT NOT NULL,
            appBundleIdentifier TEXT, appName TEXT, mode TEXT NOT NULL,
            insertionStrategy TEXT, latencySeconds REAL NOT NULL, errorMessage TEXT,
            createdAt REAL NOT NULL, insertLatencySeconds REAL NOT NULL DEFAULT 0,
            editedAfterInsert INTEGER NOT NULL DEFAULT 0);
        INSERT INTO transcripts VALUES
            ('\(id.uuidString)','heard it','Heard it.',NULL,NULL,'cleanWriting',
             NULL,3.5,NULL,\(Date().timeIntervalSince1970),1.25,0);
        """
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [url.path, oldSchema]
        try? sqlite.run()
        sqlite.waitUntilExit()
        guard sqlite.terminationStatus == 0 else {
            s.expect(false, "could not build the legacy database fixture")
            return
        }
        do {
            let store = try SQLiteHistoryStore(url: url)   // runs migrate()
            let migrated = try store.record(id: id)
            // Pre-existing columns survive the upgrade intact...
            s.expectEqual(migrated?.cleanText, "Heard it.")
            s.expectEqual(migrated?.insertLatencySeconds, 1.25)
            s.expectEqual(migrated?.latencySeconds, 3.5)
            // ...and the appended ones read as defaults, not as garbage from a
            // shifted column position.
            s.expectEqual(migrated?.transcribeSeconds, 0)
            s.expectEqual(migrated?.arbiterSeconds, 0)
            s.expectEqual(migrated?.cleanupSeconds, 0)
            s.expectEqual(migrated?.engineUsed, nil)
            // The atomic field updates must hit the migrated row too.
            try store.setEditedAfterInsert(true, id: id)
            try store.updateCleanText("Heard it, refined.", id: id)
            let updated = try store.record(id: id)
            s.expectEqual(updated?.editedAfterInsert, true)
            s.expectEqual(updated?.cleanText, "Heard it, refined.")
            s.expectEqual(updated?.insertLatencySeconds, 1.25, "a targeted update clobbered another column")
        } catch {
            s.expect(false, "migration failed: \(error)")
        }
    }

    suite.test("stages: survive a SQLite round-trip and old rows read as zero") { s in
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf-stage-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.sqlite")
        var record = TranscriptRecord(
            rawText: "raw", cleanText: "clean", mode: .cleanWriting,
            transcribeSeconds: 1.75, arbiterSeconds: 0.9, cleanupSeconds: 0.4,
            engineUsed: "whisper")
        do {
            let store = try SQLiteHistoryStore(url: url)
            try store.save(record)
            let read = try store.record(id: record.id)
            s.expectEqual(read?.transcribeSeconds, 1.75)
            s.expectEqual(read?.arbiterSeconds, 0.9)
            s.expectEqual(read?.cleanupSeconds, 0.4)
            s.expectEqual(read?.engineUsed, "whisper")
            // A record without measurements stores and reads as zeros/nil.
            record = TranscriptRecord(rawText: "old", cleanText: "old", mode: .cleanWriting)
            try store.save(record)
            let old = try store.record(id: record.id)
            s.expectEqual(old?.transcribeSeconds, 0)
            s.expectEqual(old?.engineUsed, nil)
        } catch {
            s.expect(false, "SQLite round-trip failed: \(error)")
        }
    }

    suite.test("controller: insert latency excludes the hold, total latency includes it") { s in
        let clock = MockTimeSource()
        let controller = DictationController(
            audio: MockAudioRecorder(), transcriber: MockTranscriber(), cleanup: CleanupPipeline(),
            inserter: MockTextInserter(), activeApp: MockActiveAppProvider(),
            history: InMemoryHistoryStore(), settings: .default, time: clock
        )
        let result = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            clock.advance(by: 5)          // the user held the key for 5s
            return try? await controller.finishRecording()
        }
        s.expectNotNil(result)
        guard let result else { return }
        s.expect(result.record.latencySeconds >= 5, "total latency lost the hold time")
        s.expect(result.record.insertLatencySeconds < 1,
                 "hold time leaked into the insert metric: \(result.record.insertLatencySeconds)")
    }
}
