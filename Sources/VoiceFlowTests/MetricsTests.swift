import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

/// Phase 2 — the numbers have to be honest, or they're worse than no numbers.
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
